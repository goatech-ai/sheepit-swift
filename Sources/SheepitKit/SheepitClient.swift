import Foundation

/// Sheepit iOS SDK — feature flags, experiments, and event tracking.
///
/// Usage:
/// ```swift
/// // Initialize
/// let sheepit = SheepitClient.create(config: .init(apiKey: "lp_pub_xxx_..."))
///
/// // Track events
/// sheepit.track("button_tapped", properties: ["screen": "checkout"])
///
/// // Feature flags
/// if sheepit.flag("show_banner", default: .bool(false)).boolValue == true {
///     showBanner()
/// }
///
/// // Experiments
/// let result = sheepit.experiment("checkout_v2")
/// switch result.variant {
/// case "variant_a": showNewCheckout()
/// default: showOriginalCheckout()
/// }
///
/// // Identity
/// sheepit.identify(userId: "user_123", traits: ["plan": "pro"])
/// ```
public final class SheepitClient: @unchecked Sendable {
    // MARK: - Singleton

    /// Guards `instance` against two concurrent `initialize()` calls both observing it as
    /// nil and each constructing (and starting) a live client — an unsynchronized
    /// check-then-act that orphaned one of the two. Also guards `destroy()`'s clear of
    /// `instance`, so a concurrent initialize/destroy pair can't interleave either.
    private static let instanceLock = NSLock()
    private static var instance: SheepitClient?

    /// Create and return a singleton instance. Warns if already initialized.
    ///
    /// 🔴 2026-09 security follow-up (round 2, deadlock fix): this used to hold
    /// `instanceLock` across the WHOLE of `create(config:)`. Construction runs host code
    /// synchronously on the calling thread — the inert path's `diagnosticBus.emit(...)` fans
    /// out to every subscriber, and the live path's `start() -> emitSessionStartIfOwed() ->
    /// track() -> config.onEvent?` does too — so a host `onDiagnostic`/`onEvent` callback that
    /// read `SheepitClient.shared` or called `destroy()` on that SAME thread deadlocked
    /// forever against this non-recursive `NSLock`. On the main thread that is an
    /// unrecoverable watchdog kill with no readable crash report. Reproduced: both
    /// `initialize()` calls never returned (XCTWaiter timeout). See `LifecycleSafetyTests`
    /// for the two regression tests this guards against.
    ///
    /// 🔴 2026-09 security follow-up (round 3, findings MF-2/MF-3 — what the round-2 fix
    /// introduced): moving construction outside the lock meant EVERY concurrent caller built
    /// a FULL, RUNNING client before the publish race was decided, because the private
    /// initializer called `start()` at the end of its own work. `start()` registers a device,
    /// opens the config-sync loop, installs process-global crash signal handlers, and emits
    /// `$session_start`. Only one caller's client is ever published; the rest are
    /// `destroy()`ed — but a STARTED client's `destroy()` still flushes, so a loser's
    /// `$session_start` (and any crash report it found pending from a previous launch) was
    /// posted to the server anyway before being torn down (measured: 50 concurrent
    /// `initialize()` → 1 published instance but 6 `$session_start` events, against the
    /// previous head's 1). Worse, the crash handler is a PROCESS-GLOBAL C singleton
    /// (`Sources/SheepitCrashHandler/sheepit_crash_handler.c`, guarded by a file-static
    /// `bool`) while `CrashReporter.isInstalled` is per-INSTANCE — so if a LOSER's `install()`
    /// happened to win the C-level race, the WINNING client's own `isInstalled` stayed
    /// `false`, and the loser's `destroy()` → `uninstall()` then ripped the signal handler out
    /// of the process for good, leaving the surviving singleton unprotected for its entire
    /// lifetime (measured: previous head "handlers still installed" 3/3, current head "no
    /// handler was installed" 3/3).
    ///
    /// Fixed by separating CONSTRUCTION from STARTING WORK. `constructOnly(config:)` builds a
    /// fully-formed client — including the inert-path teardown when the key/apiUrl/environment
    /// is rejected — but a non-inert result stops there: no device registration, no config
    /// sync, no flush loop, no crash-handler install, no `$session_start`. `beginWork()` is
    /// what starts all of that, and here it runs only AFTER the lock has decided who wins:
    ///
    ///   - the WINNER calls `beginWork()` itself, outside the lock (same reasoning as the
    ///     round-2 fix — `start()` runs host callbacks synchronously and must never run while
    ///     this thread holds `instanceLock`);
    ///   - a LOSER never calls `beginWork()` at all, so it never emitted anything, never
    ///     touched the network, and never installed a crash handler — `destroy()`ing it is a
    ///     pure teardown of components that were never started, exactly like an inert client.
    ///
    /// `create(config:)`'s direct (non-racing) callers are unaffected: it still calls
    /// `beginWork()` immediately after `constructOnly(config:)`, so it returns exactly the
    /// live, running client it always did.
    ///
    /// Construction still happens OUTSIDE the lock (round-2's fix), so host callbacks can
    /// freely read `shared` or call `destroy()` without touching a lock this thread already
    /// holds. The lock is taken only for the short check-and-assign.
    /// `testConcurrentInitializeNeverProducesTwoDistinctLiveInstances` still holds: exactly
    /// one caller's check-and-assign observes `instance == nil` and publishes its client,
    /// because that step — not construction — is what the lock serializes.
    public static func initialize(config: SheepitConfig) -> SheepitClient {
        let inst = constructOnly(config: config)

        instanceLock.lock()
        let existing = instance
        // Never cache a rejected-key client. destroy() cannot clear the singleton on an
        // inert client (its latch is already set, so destroy() early-returns), so caching
        // one would make `shared` — and every later initialize(), including one with a
        // corrected key — return the dead client for the whole process lifetime.
        if existing == nil, inst.inertReason == nil {
            instance = inst
        }
        instanceLock.unlock()

        if let existing {
            existing.log.warn("initialize() called after already initialized. Returning existing instance.")
            // `inst` never called `beginWork()` — it has nothing to flush, nothing running
            // to stop, and no crash handler to uninstall. See the doc above (MF-2/MF-3).
            inst.destroy()
            return existing
        }
        inst.beginWork()
        return inst
    }

    /// Get the singleton instance. Returns nil if not initialized.
    public static var shared: SheepitClient? {
        instanceLock.lock()
        defer { instanceLock.unlock() }
        return instance
    }

    // MARK: - API key admission

    /// Key types the SDK understands. Matched by POSITION within the key's `_`-delimited
    /// segments — `{vendor}_{type}_{slug}_{secret}` — never against a literal prefix.
    ///
    /// Segment 0, the vendor prefix, is deliberately never compared to anything: a published
    /// SPM version is immutable forever, so a literal prefix compiled in here would have to
    /// keep being minted for as long as anyone has that version pinned. Everything else is
    /// checked, because the alternative — admitting anything containing the substring `pub`
    /// — turns a developer's typo into a client that looks alive and silently 401s.
    ///
    /// 🔴 LOAD-BEARING CONSTRAINT (2026-09 security follow-up to #972, finding E-002): the
    /// key MUST have EXACTLY four segments, and **neither the vendor prefix nor the secret
    /// may itself contain `_`.** Positional matching only works for a fixed segment count —
    /// the previous "at least 4, sweep everything past index 2" version let a two-token
    /// vendor prefix (e.g. `my_pub_sec_abc_<secret>`) slide a real `sec` type token into the
    /// exempted slug slot, admitting a secret key. `{vendor}` and `{secret}` are minted by
    /// one function (`generateApiKey`) that never puts a `_` in either, so this narrows the
    /// format rather than breaking it — but it IS a narrowing, and the next person minting a
    /// vendor prefix or secret alphabet must keep it `_`-free.
    private enum APIKeyType: String {
        case publishable = "pub"
        case secret = "sec"
        case dev = "dev"
    }

    /// The shape a key must have to be considered at all. Deliberately a LOWER bound on the
    /// secret's length and no upper bound or character-set constraint beyond printable ASCII,
    /// so the secret can grow or change encoding without stranding versions already published.
    private static let minimumSecretLength = 32
    private static let expectedSegmentCount = 4
    private static let typeSegmentIndex = 1
    private static let secretSegmentIndex = 3

    /// Why this key may not drive a client-side SDK, or `nil` if it may.
    private static func rejectionReason(
        for apiKey: String,
        allowSecretKeyInClient: Bool
    ) -> String? {
        // Trim first: a key copied out of a terminal, `.env` file, or plist with a trailing
        // newline or space must not be silently admitted and then have its Authorization
        // header dropped by Foundation on every request (2026-09 follow-up, finding E-004).
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        // omittingEmptySubsequences: false so a double/leading/trailing underscore
        // (`lp__pub_...`, `_lp_pub_...`, `lp_pub_abc_<secret>_`) surfaces as an EMPTY
        // segment rather than silently collapsing into a well-formed-looking segment
        // count — those three shapes were admitted before this fix (finding E-005).
        let segments = trimmed.split(separator: "_", omittingEmptySubsequences: false)
        let malformed = "Invalid API key format. Expected a publishable key, shaped "
            + "{prefix}_pub_{env}_{secret} — EXACTLY four `_`-delimited segments, none of "
            + "them empty. The vendor prefix and the secret must not themselves contain `_`."

        // 🔴 2026-09 security follow-up (round 2), finding M3: this used to constrain ONLY
        // `segments[secretSegmentIndex]` to printable ASCII, leaving segment 0 (vendor) and
        // segment 2 (slug) unchecked. A CR/LF smuggled into either was admitted here and then
        // made Foundation silently drop the whole `Authorization` header on every request —
        // the exact E-004 silent-401 class this guard exists to close. Checking the WHOLE
        // trimmed key subsumes the narrower secret-only check.
        guard segments.count == expectedSegmentCount,
              segments.allSatisfy({ !$0.isEmpty }),
              segments[typeSegmentIndex].count == 3,
              let type = APIKeyType(rawValue: String(segments[typeSegmentIndex])),
              segments[secretSegmentIndex].count >= minimumSecretLength,
              trimmed.unicodeScalars.allSatisfy(isPrintableASCII)
        else {
            return malformed
        }

        // Defense in depth, not reachable today: `minimumSecretLength` (32) already rejects
        // a secret segment short enough to equal "sec" or "dev" outright via the guard
        // above, and the exactly-four-segment split above means the secret can never itself
        // contain an embedded type token without also containing `_` (which would already
        // have failed that guard). Kept so a future relaxation of either constant does not
        // silently reopen E-002. Case-insensitive: `SEC`/`Dev` must not evade it either.
        let secretLower = segments[secretSegmentIndex].lowercased()
        if secretLower == APIKeyType.secret.rawValue && !allowSecretKeyInClient {
            return secretKeyRejection
        }
        if secretLower == APIKeyType.dev.rawValue {
            return devKeyRejection
        }

        switch type {
        case .publishable:
            return nil
        case .secret:
            return allowSecretKeyInClient ? nil : secretKeyRejection
        case .dev:
            return devKeyRejection
        }
    }

    /// 🔴 2026-09 security follow-up (round 3), finding SF-3, deliberately NOT fixed: `0x20`
    /// (space) is printable ASCII, so `lp_pub_a c_<secret>` is admitted with a space in the
    /// slug. Left as-is: an admitted key with a space 401s loudly against the real API — this
    /// gate's job is stopping a typo from becoming a client that looks alive and silently
    /// fails, and a space-containing key still fails loudly. Narrowing further risks
    /// rejecting a legitimately space-containing value some future slug alphabet might use,
    /// for a case that already fails safely.
    private static func isPrintableASCII(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x20 && scalar.value < 0x7F
    }

    /// Why `config.apiUrl` may not drive a client, or `nil` if it may. A malformed or empty
    /// value (an unset env var is the common BYOC case) used to reach
    /// `URL(string:)!` in `HTTPClient.init` and trap in release builds — this routes it
    /// through the same inert-client path as a rejected key instead (2026-09 follow-up,
    /// finding E-003).
    ///
    /// 🔴 2026-09 security follow-up (round 3), finding MF-5: `url.scheme != nil` and
    /// `url.host != nil` are the wrong checks — Foundation's `URL` returns EMPTY STRINGS for
    /// a missing scheme/host, not `nil`. `"https://user:sup3rs3cret@"` parses with
    /// `host == ""` (non-nil, so ADMITTED); `"://user:pass@host"` parses with
    /// `scheme == ""` (also admitted). Both require a NON-EMPTY scheme and host, and the
    /// scheme is further restricted to `http`/`https` — this is a REST API gateway URL, not
    /// an arbitrary URI, so `foo://host` has no legitimate use here either.
    private static let allowedAPIURLSchemes: Set<String> = ["http", "https"]

    private static func apiURLRejectionReason(for apiUrl: String) -> String? {
        let trimmed = apiUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(), allowedAPIURLSchemes.contains(scheme),
              let host = url.host, !host.isEmpty
        else {
            return "Invalid SheepitConfig.apiUrl \"\(redactingUserinfo(from: apiUrl))\". Expected "
                + "an absolute http(s) URL including a non-empty scheme and host, e.g. "
                + "\"https://api.sheepit.ai\" or your self-hosted gateway's URL."
        }
        return nil
    }

    /// Why `config.environment` may not drive a client, or `nil` if it may. Sent verbatim as
    /// the `X-Environment` header on every request (`HTTPClient.applyHeaders`).
    ///
    /// 🔴 2026-09 security follow-up (round 3), finding SF-2: a control character (most
    /// concretely CR/LF, e.g. `"staging\nX-Injected: 1"`) is not a header-injection vector —
    /// `URLRequest`/Foundation refuses to add ANY header whose value contains one — but that
    /// means Foundation silently DROPS the whole `X-Environment` header rather than refusing
    /// the request, so a client with a dirty `environment` looks alive and tags every event
    /// with no environment attribution at all. Rejected (routed through the same inert path
    /// as a bad key/apiUrl) rather than sanitized, matching this gate's existing shape.
    private static func environmentRejectionReason(for environment: String) -> String? {
        guard !environment.isEmpty, environment.unicodeScalars.allSatisfy(isPrintableASCII) else {
            return "Invalid SheepitConfig.environment \(environment.debugDescription). Must be "
                + "non-empty printable ASCII with no control characters — it is sent verbatim "
                + "as the X-Environment header on every request."
        }
        return nil
    }

    /// Strips any userinfo (`user[:password]@`) component before a malformed `apiUrl` is
    /// echoed back into a rejection reason. Every rejection path here publishes the message
    /// three places — `log.error`, the `lifecycle.api_key_rejected` diagnostic, and the
    /// PUBLIC `status().rejectionReason` — so a copy-pasted gateway URL with embedded basic-
    /// auth credentials (`https://user:sup3rs3cret@host`) was echoed verbatim into all three.
    /// `URL`'s own `.user`/`.password` accessors only work on a URL that parses successfully,
    /// but the strings that reach here are exactly the ones that DIDN'T (or parsed with no
    /// host) — hence a string-level strip rather than `URLComponents`.
    ///
    /// 🔴 2026-09 security follow-up (round 3), finding SF-1: the colon was REQUIRED
    /// (`[^/@\s]*:[^/@\s]*@`), so a bare token with no `user:pass` shape
    /// (`"sup3rs3cret@api.example.com"`) skipped the match and leaked verbatim. And because
    /// the character class excluded `@` itself, a password that CONTAINS an `@`
    /// (`"https://user:p@ss@host"`) matched only up to the FIRST `@`, under-redacting to
    /// `"ss@host"`. The colon is now optional, and `@` is allowed inside the match — greedy
    /// matching then backtracks to the LAST `@` in the run, which is always the one that
    /// actually separates userinfo from host.
    private static func redactingUserinfo(from apiUrl: String) -> String {
        apiUrl.replacingOccurrences(
            of: "(^|//)[^/\\s]*@",
            with: "$1",
            options: .regularExpression
        )
    }

    private static let devKeyRejection =
        "Developer keys (*_dev_*) cannot be used with SheepitKit. They are read-only for "
        + "schemas and definitions and cannot post events. Use a publishable key (*_pub_*) "
        + "for client-side code."

    private static let secretKeyRejection =
        "Secret keys (*_sec_*) must not ship in iOS apps. They grant full project write "
        + "access and would leak from the IPA. Use a publishable key (*_pub_*) for "
        + "client-side code. Audit finding E-002."

    // MARK: - Factory

    /// Create a new independent instance. Preferred for SwiftUI apps (inject via environment).
    ///
    /// Reject secret keys (`*_sec_*`). They grant full project write access and must NEVER
    /// ship in an iOS bundle (anyone can extract them via `strings` on the IPA). The matching
    /// guard in the JS SDK lives at packages/sdk-js/src/client.ts:172. Audit E-002 (2026-04-25)
    /// flagged the missing guard here as a P0 secret-leak vector.
    ///
    /// A rejected key, a malformed/empty `config.apiUrl`, or a dirty `config.environment`
    /// (round 3, finding SF-2) returns an **inert** client
    /// instead of aborting the host app: it logs an error, emits a
    /// `lifecycle.api_key_rejected` diagnostic, reports `status().initialized == false`, and
    /// every method is a no-op that never touches the network OR persistent storage — an
    /// inert client makes ZERO writes to disk (2026-09 follow-up, finding E-001, plus round-2
    /// finding S1 closing the last gap in `clearOverrides()`/`clearOverride(_:)`), since it is
    /// judged before `StorageMigration.run` or `ContextManager`'s identity-persist step ever
    /// run. This mirrors the JS SDK, where the equivalent guard throws — recoverable —
    /// rather than killing the process. `precondition` used to crash the app on launch here,
    /// which also meant a `*_dev_*` key (a documented key type) took the app down with a
    /// message that named only `pub` and `sec`.
    ///
    /// Apps doing internal SDK testing in XCTest can opt out of the secret-key guard by
    /// setting `SheepitConfig.allowSecretKeyInClient = true`. Production callers never should.
    public static func create(config: SheepitConfig) -> SheepitClient {
        let inst = constructOnly(config: config)
        inst.beginWork()
        return inst
    }

    /// Constructs a client WITHOUT starting any of its background work — no device
    /// registration, no config sync, no periodic flush loop, no crash-handler install, no
    /// `$session_start`. Shared by both public factories:
    ///
    ///   - `create(config:)` calls `beginWork()` immediately after, because its (non-racing)
    ///     callers always want a live, running client back;
    ///   - `initialize(config:)` defers `beginWork()` until AFTER the singleton-publish race
    ///     is decided, so a concurrent LOSER — `destroy()`ed unpublished — never started
    ///     anything to begin with (2026-09 security follow-up round 3, findings MF-2/MF-3;
    ///     see `initialize(config:)`'s doc).
    ///
    /// An inert result (rejected key, apiUrl, or environment) is fully torn down by the
    /// private initializer itself and needs no further action from either caller —
    /// `beginWork()` is a no-op on it.
    private static func constructOnly(config: SheepitConfig) -> SheepitClient {
        let reason = rejectionReason(
            for: config.apiKey,
            allowSecretKeyInClient: config.allowSecretKeyInClient
        ) ?? apiURLRejectionReason(for: config.apiUrl)
            ?? environmentRejectionReason(for: config.environment)
        return SheepitClient(config: config, inertReason: reason)
    }

    /// Test-only mirror of `constructOnly(config:)` — lets a test construct a candidate the
    /// SAME way a concurrent `initialize()` LOSER is constructed (built, but never started),
    /// without needing an actual race. `@testable`-internal, so it cannot be reached by an
    /// app linking the released package. See `ConcurrentInitializeSideEffectTests` (MF-2/MF-3).
    internal static func constructOnlyForTesting(config: SheepitConfig) -> SheepitClient {
        constructOnly(config: config)
    }

    /// Test-only factory that injects the clock. `@testable`-internal, so it
    /// cannot be reached by an app linking the released package. Calls `beginWork()`
    /// immediately, like `create(config:)` — every existing caller expects a live, running
    /// client back synchronously.
    /// - Parameter urlProtocolClasses: test-only seam, mirroring `HTTPClient`'s own — lets a
    ///   test stub the network `SheepitClient`'s internally-constructed `HTTPClient` talks
    ///   over. Always nil (production `HTTPClient` behavior) unless a test passes one.
    internal static func createForTesting(
        config: SheepitConfig,
        now: @escaping @Sendable () -> Date,
        urlProtocolClasses: [AnyClass]? = nil
    ) -> SheepitClient {
        let reason = rejectionReason(
            for: config.apiKey,
            allowSecretKeyInClient: config.allowSecretKeyInClient
        )
        let inst = SheepitClient(
            config: config,
            inertReason: reason,
            now: now,
            urlProtocolClasses: urlProtocolClasses
        )
        inst.beginWork()
        return inst
    }

    /// Test-only mirror of `beginWork()` — lets a test invoke exactly what `initialize()`'s
    /// winner calls next, on a candidate built with `constructOnlyForTesting`, WITHOUT needing
    /// an actual race to land in the window `initialize()` itself can't be paused inside of.
    /// `@testable`-internal, so it cannot be reached by an app linking the released package.
    /// See `LifecycleSafetyTests`/`ConcurrentInitializeSideEffectTests` (MF3-2).
    internal func beginWorkForTesting() {
        beginWork()
    }

    // MARK: - Internal Components

    /// Non-nil when `create(config:)` refused this client's API key OR apiUrl. Such a client
    /// is inert: see `create(config:)`. Read by `initialize(config:)`, which must not cache
    /// one.
    let inertReason: String?
    private let config: SheepitConfig
    private let log: Logger
    private let storage: StorageProvider
    /// `internal` rather than `private` so tests can read the live session id.
    /// Not part of the public API — `@testable import` only.
    internal let context: ContextManager
    private let queue: EventQueue
    private let offlineQueue: OfflineQueue
    private let http: HTTPClient
    private let transport: Transport
    /// Internal, not private, so a test can prove an inert client released its
    /// NWPathMonitor. Not part of the public surface.
    let connectivity: ConnectivityMonitor
    private let deviceManager: DeviceManager
    /// Internal, not private, so a test can read `overridesAllowedForTests` directly —
    /// see that property's doc for why. Not part of the public surface.
    let flagManager: FlagManager
    private let experimentManager: ExperimentManager
    private let configSync: ConfigSync
    private let performanceMonitor: PerformanceMonitor?
    private let crashReporter: CrashReporter?
    private let diagnosticBus: DiagnosticBus
    private let lifecycleObserver: AppLifecycleObserver
    private let lastFlushClock = LastFlushClock()

    private var flushTask: Task<Void, Never>?
    private let destroyedFlag = AtomicFlag()
    /// How many times `releaseSelfStartingComponents()` has actually run. Internal, not
    /// private, purely so a test can prove it runs — replacing a prior assertion
    /// (`connectivity.isMonitoring == false`) that stayed true whether or not the release
    /// code ran, because nothing in this class currently starts work in its own
    /// initializer post-#972. Mutated only from `init` (single-threaded, runs once) and
    /// `destroy()` (serialized by `destroyedFlag.testAndSet()`), so it never races. Not part
    /// of the public surface.
    private(set) var releaseSelfStartingComponentsCallCount = 0
    /// Whether `beginWork()` actually ran `start()` for this instance. Internal, not
    /// private, so a test can PROVE a concurrent `initialize()` LOSER never began work —
    /// mechanically, rather than by observing a side effect (a network call, an installed
    /// crash handler) that is unsafe to trigger for real inside the test process (2026-09
    /// security follow-up round 3, findings MF-2/MF-3). A loser's value stays `false` for its
    /// entire lifetime: `beginWork()` is called at most once per instance, and never for a
    /// client that `initialize()` decided not to publish. Not part of the public surface.
    private(set) var didBeginWork = false
    /// Resolves when the initial device registration round-trip completes
    /// (success OR failure). identify() and other server calls that reference
    /// deviceId await this so they don't 404 against a locally-generated UUID
    /// the server hasn't seen.
    private var registrationTask: Task<Void, Never>?
    /// Mirrors `registrationTask` for callers that need to await it BEFORE `self` is fully
    /// initialized (see the type's own doc — that's the constraint it exists to route
    /// around). `start()` writes to both; every other reader can use whichever it already
    /// has access to.
    private let registrationGate = RegistrationGate()
    /// The SDK's clock — same injected value `ContextManager` gets, kept here too so
    /// `deviceRegistrationBackoffActive()` can compare against it without threading a
    /// second clock through. Tests age a terminal-registration-failure backoff window with
    /// this instead of a real 24h `Task.sleep`.
    private let now: @Sendable () -> Date

    /// `now` is the SDK's clock, injected only so tests can age a session out
    /// while the client is alive. Production always uses `Date.init`; there is
    /// no public way to supply anything else.
    private init(
        config: SheepitConfig,
        inertReason: String? = nil,
        now: @escaping @Sendable () -> Date = { Date() },
        urlProtocolClasses: [AnyClass]? = nil
    ) {
        self.inertReason = inertReason
        self.config = config
        self.now = now
        self.log = Logger(debug: config.debug)
        let bus = DiagnosticBus(bufferSize: config.diagnosticBufferSize)
        if let onDiagnostic = config.onDiagnostic {
            bus.subscribe(onDiagnostic)
        }
        self.diagnosticBus = bus
        self.storage = UserDefaultsStorage(suiteName: "ai.goatech.sdk")
        // Judge the key/apiUrl BEFORE touching persistent state (see `create(config:)`).
        // A rejected client must have ZERO side effects on disk — constructing these
        // unconditionally used to rotate the device/session ids that the NEXT,
        // correctly-keyed client would read (2026-09 follow-up, finding E-001).
        //
        // StorageMigration must run before ContextManager reads any key, or an existing
        // install looks brand new: fresh device id, lost identity, lost offline queue,
        // re-bucketed experiments — but only for a client that will actually run.
        if inertReason == nil {
            StorageMigration.run(storage: storage)
        }
        // `persistOnInit: false` UNCONDITIONALLY — not `inertReason == nil` — so construction
        // itself never writes to disk for ANY candidate, live or inert. `beginWork()` is what
        // persists (`context.persistOnBeginWork()`), and it runs only for the client that
        // actually wins the `initialize()` publish race. Before this, a candidate with an
        // ACCEPTED key persisted unconditionally right here in `init`, so a concurrent
        // `initialize()` LOSER — fully constructed, `destroy()`ed unpublished, `beginWork()`
        // never called — still clobbered the WINNER's already-persisted session id with one
        // nobody would ever use again (2026-09 security follow-up round 4, finding MF3-1).
        self.context = ContextManager(storage: storage, now: now, persistOnInit: false)
        self.queue = EventQueue(maxSize: config.maxQueueSize, diagnostics: bus)
        self.offlineQueue = OfflineQueue(storage: storage, diagnostics: bus)
        self.http = HTTPClient(config: config, log: log, urlProtocolClasses: urlProtocolClasses)
        self.connectivity = ConnectivityMonitor()
        self.transport = Transport(
            http: http,
            queue: queue,
            offlineQueue: offlineQueue,
            connectivity: connectivity,
            log: log,
            appVersion: config.appVersion,
            diagnostics: bus,
            lastFlushClock: lastFlushClock
        )
        self.deviceManager = DeviceManager(http: http, log: log)
        self.flagManager = FlagManager(diagnostics: bus)
        if inertReason == nil {
            self.flagManager.setOverridesAllowed(config.allowFlagOverrides ?? config.debug)
        }
        self.experimentManager = ExperimentManager(storage: storage)

        // ConfigSync callback applies config to flag/experiment managers.
        // Capture managers (not self) to avoid a reference cycle.
        let fm = self.flagManager
        let em = self.experimentManager
        let logger = self.log
        self.configSync = ConfigSync(
            http: http,
            storage: storage,
            refreshInterval: config.configRefreshInterval,
            log: log,
            onConfig: { response in
                fm.setEvaluatedFlags(response.flags)
                em.setAssignments(response.experiments)
                logger.debug(
                    "Config applied: \(response.flags.count) flags, "
                    + "\(response.experiments.count) experiments"
                )
            }
        )

        // Performance monitoring
        if config.performance.enabled, inertReason == nil {
            let monitor = PerformanceMonitor(
                http: http,
                context: context,
                config: config.performance,
                log: log
            )
            self.performanceMonitor = monitor
        } else {
            self.performanceMonitor = nil
        }

        // Crash reporting
        if config.crashes.enabled, inertReason == nil {
            let reporter = CrashReporter(
                http: http,
                context: context,
                config: config.crashes,
                storage: storage,
                log: log
            )
            self.crashReporter = reporter
        } else {
            self.crashReporter = nil
        }

        // Flush on app background so queued events survive suspension.
        // `transport`/`registrationGate` are captured directly (not self) to avoid
        // retaining the client for its whole process lifetime through this long-lived
        // closure — and because a closure built HERE, mid-`init`, cannot legally capture
        // `self` at all yet (see `RegistrationGate`'s doc for why this matters for the
        // registration wait specifically).
        let transportRef = self.transport
        let registrationGateRef = self.registrationGate
        self.lifecycleObserver = AppLifecycleObserver(
            log: log,
            diagnostics: bus,
            onBackground: {
                await registrationGateRef.awaitSettlement()
                await transportRef.flush()
            }
        )

        // Wire error tracking callbacks
        if let monitor = performanceMonitor {
            Task {
                await monitor.setOnError { [weak self] error, endpoint in
                    self?.trackSDKError(source: "performance", error: error, endpoint: endpoint)
                }
            }
        }
        if let reporter = crashReporter {
            Task {
                await reporter.setOnError { [weak self] error, endpoint in
                    self?.trackSDKError(source: "crashes", error: error, endpoint: endpoint)
                }
            }
        }

        if let inertReason {
            // Latch the same flag destroy() uses. Every public method already short-circuits
            // on it, so an inert client is a total no-op, and start() is never reached — no
            // device registration, no config sync, no flush loop, no network at all.
            // Construction has already started things that start themselves — today just
            // ConnectivityMonitor's NWPathMonitor, which is not released by dealloc and
            // needs an explicit cancel(). Latching the flag below makes destroy() an
            // early-return, so this is the only chance to release them.
            releaseSelfStartingComponents()
            _ = destroyedFlag.testAndSet()
            log.error(inertReason)
            diagnosticBus.emit(
                .error,
                .lifecycle,
                code: "lifecycle.api_key_rejected",
                message: inertReason
            )
            return
        }

        // Background work begins in `beginWork()`, called by whichever caller
        // (`create(config:)`, `createForTesting`, or `initialize(config:)`'s winner) decides
        // this client should run — NOT here. A candidate that never reaches `beginWork()`
        // does no network I/O, installs no crash handler, and writes NO PER-CLIENT IDENTITY:
        // `ContextManager` is built with `persistOnInit: false` and only `beginWork()` calls
        // `context.persistOnBeginWork()`, so a loser can never clobber the device/session ids
        // the published winner is using (round 4, finding MF3-1).
        //
        // 🔴 It is NOT byte-identical on disk to an inert client, and two earlier versions of
        // this comment wrongly said so. A NON-INERT candidate — a valid loser included — also
        // runs `StorageMigration.run` (line ~477) and constructs `CrashReporter`, which
        // creates its cache directory. Both are process-wide, idempotent and shared by every
        // client of this install, so neither can clobber another client; but both are real
        // writes, one to `UserDefaults` and one to the filesystem. An INERT client skips both.
        // Before asserting "a loser writes nothing" again, enumerate the writers —
        // `grep -rn "storage.set\|removeObject\|createDirectory\|FileManager" Sources/` —
        // rather than reasoning about `ContextManager` alone; that is exactly how this claim
        // shipped wrong twice. Deferring both behind `beginWork()` is queued in PENDING_WORK
        // (it requires deferring `ContextManager`'s read too, since the migration must
        // precede it).
    }

    // MARK: - Public API: Events

    /// Track an event with optional properties. A blank/whitespace-only `eventName` is
    /// dropped with a logged error and a diagnostic rather than crashing the host — see
    /// `validateEventName`.
    public func track(_ eventName: String, properties: [String: Any]? = nil) {
        guard !destroyedFlag.value else { return }

        guard let name = validateEventName(eventName) else {
            log.error("track() called with an empty event name — event dropped")
            diagnosticBus.emit(
                .error,
                .transport,
                code: "transport.invalid_event_name",
                message: "Event name must not be empty or whitespace-only; event was dropped"
            )
            return
        }

        // Close an aged-out session before this event joins it. This is the
        // ONLY rollover trigger that reaches every platform: the foreground
        // notification is timelier but lives behind
        // `#if canImport(UIKit) && !os(watchOS)`, so on macOS and watchOS a
        // session would otherwise last the whole process lifetime.
        //
        // Safe to roll over mid-stream because `Transport.flush()` groups each
        // drain by session id — the boundary no longer has to coincide with a
        // flush. Activity-triggered rather than timer-triggered, so an app left
        // idle in the foreground mints no empty sessions (matching the web,
        // where no events means no new session).
        context.rolloverIfExpired()
        emitSessionStartIfOwed()
        context.touchSession()
        let ctx = context.eventContext()

        let event = EnrichedEvent(
            eventId: UUID().uuidString,
            eventName: name,
            eventProperties: properties?.mapValues { AnyCodable($0) },
            deviceId: ctx.deviceId,
            anonymousId: ctx.anonymousId,
            sessionId: ctx.sessionId,
            userId: ctx.userId,
            platform: ctx.platform,
            sdkVersion: ctx.sdkVersion,
            locale: ctx.locale,
            timezone: ctx.timezone,
            timestamp: SheepitClient.formatEventTimestamp(Date())
        )

        queue.add(event)
        crashReporter?.addBreadcrumb(category: "track", message: name)
        config.onEvent?(name, properties)

        if queue.size() >= config.flushSize {
            Task {
                await awaitDeviceIdSettlementForAutoFlush()
                await transport.flush()
            }
        }
    }

    /// The wire timestamp for `EnrichedEvent.timestamp`. Sub-second precision
    /// (`.withFractionalSeconds`), not just `.withInternetDateTime`'s default second
    /// granularity: two events emitted in the same wall-clock second (e.g.
    /// `$app_install`/`$app_update` immediately followed by `$session_start` on a fresh
    /// install, or any two `track()` calls in a tight loop) would otherwise carry a
    /// byte-identical timestamp, and `insights-funnel-query.ts`'s step join is strictly
    /// `ev.ts > s${i}.ts_${i}` — so a tied timestamp makes that funnel return zero rows,
    /// permanently. `ingestEventSchema.timestamp` is `z.string().datetime()` with no
    /// `precision` constraint, so arbitrary sub-second precision is wire-compatible in
    /// both directions.
    ///
    /// A NEW `ISO8601DateFormatter` per call, deliberately not a shared static one: the
    /// type mutates internal state and is not thread-safe, and `track()` is called from
    /// arbitrary threads — caching one would be a new concurrency surface immediately
    /// before a tag.
    ///
    /// `internal`, not `private`, purely so `EventTimestampPrecisionTests` can call it with
    /// two fixed `Date`s in the SAME whole second and assert the fractional component
    /// still disambiguates them deterministically, without depending on real wall-clock
    /// timing between two statements.
    internal static func formatEventTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Force flush pending events and performance metrics to the server.
    public func flush() async {
        // Guarded on inert, NOT on destroyedFlag: destroy() latches that flag and then calls
        // flush() to drain pending events, so a destroyed-guard here would silently discard
        // them. An inert client has nothing to drain and no valid credential to drain it with.
        guard inertReason == nil else { return }
        await transport.flush()
        await performanceMonitor?.flush()
    }

    // MARK: - Public API: Flags

    /// Evaluate a feature flag. Returns synchronously from cached config.
    public func flag(_ flagKey: String, default defaultValue: FlagValue = .bool(false)) -> FlagValue {
        guard !destroyedFlag.value else { return defaultValue }
        return flagManager.evaluate(
            flagKey: flagKey,
            defaultValue: defaultValue,
            onExposure: { [weak self] key, value in
                self?.track("$flag_exposure", properties: [
                    "flag_key": key,
                    // Raw value, not a case description — matches
                    // packages/sdk-js/src/client.ts:315 and the
                    // `flag_value: "unknown"` event schema.
                    "flag_value": value.anyValue,
                ])
            }
        )
    }

    /// Override a flag value for local testing. Only applies when
    /// overrides are allowed — see `SheepitConfig.allowFlagOverrides`
    /// (defaults to following `debug`). No-ops (and does not persist) when
    /// disabled.
    public func overrideFlag(_ key: String, value: FlagValue) {
        guard !destroyedFlag.value else { return }
        flagManager.overrideFlag(key, value: value)
    }

    /// Clear all debug overrides. ALWAYS works — regardless of whether overrides are
    /// currently allowed (`SheepitConfig.allowFlagOverrides`) AND regardless of whether this
    /// client has been `destroy()`-ed. Gating WRITES is the security property that matters
    /// (a production build must not be able to apply an override); gating deletes would buy
    /// nothing and could leave a build that once ran with `debug: true` unable to purge an
    /// override it wrote to disk before shipping — including one that calls `destroy()` as
    /// part of its own teardown/reset flow before doing that cleanup.
    ///
    /// 🔴 2026-09 security follow-up to #972: this method briefly gained a
    /// `guard !destroyedFlag.value` that directly contradicted the paragraph above — a
    /// build that destroyed its client could no longer purge an override it had written.
    /// Removed; an inert (rejected-key) client never had overrides enabled in the first
    /// place, so this has nothing to purge for that case either.
    ///
    /// 🔴 2026-09 security follow-up (round 2), finding S1: the paragraph above was true of
    /// `destroyedFlag` but this method carried NO guard at all, including on `inertReason` —
    /// so an INERT client (a rejected key/apiUrl, which never reaches `start()` and is
    /// documented to make zero writes to disk) still reached `FlagManager.clearOverrides()`,
    /// which unconditionally calls `UserDefaults.standard.removeObject(forKey:)`. Gated on
    /// `inertReason`, NOT `destroyedFlag`, so the invariant above still holds: a client this
    /// call itself just `destroy()`ed can still purge.
    public func clearOverrides() {
        guard inertReason == nil else { return }
        flagManager.clearOverrides()
    }

    /// All currently-set debug overrides, keyed by flag key. Only
    /// non-empty when overrides are allowed — see
    /// `SheepitConfig.allowFlagOverrides` (defaults to following `debug`).
    public func getOverrides() -> [String: FlagValue] {
        // Guarded on inert, NOT on destroyedFlag. This is a READ, and the suite relies on it
        // still reporting after destroy() to prove the write paths went inert
        // (FlagInspectionPublicAPITests.testInertClientDoesNotWriteFlagOverrides). An inert
        // client never had overrides enabled in the first place.
        guard inertReason == nil else { return [:] }
        return flagManager.getOverrides()
    }

    /// Clear a single flag's debug override, leaving any others in place. ALWAYS works,
    /// regardless of whether overrides are currently allowed or this client has been
    /// `destroy()`-ed — see `clearOverrides()`'s doc for why.
    ///
    /// 🔴 2026-09 security follow-up (round 2), finding S1: gated on `inertReason`, not
    /// `destroyedFlag` — same rationale as `clearOverrides()`. `FlagManager.clearOverride`
    /// reaches `purgeStaleKeyFromDisk`, which does a `UserDefaults.standard.set(...)` — an
    /// inert client must not do that either.
    public func clearOverride(_ key: String) {
        guard inertReason == nil else { return }
        flagManager.clearOverride(key)
    }

    /// Diagnostic read for a debug/dev-menu flag inspector. Does NOT fire
    /// exposure — safe to sweep every known key without polluting
    /// experiment/flag exposure data. Not for use in product code paths;
    /// use `flag(_:default:)` there.
    public func inspect(_ flagKey: String, default defaultValue: FlagValue = .bool(false)) -> SheepitFlagInspection {
        guard !destroyedFlag.value else {
            return SheepitFlagInspection(
                key: flagKey,
                remoteValue: nil,
                overrideValue: nil,
                effectiveValue: defaultValue,
                source: .fallback
            )
        }
        return flagManager.inspect(flagKey: flagKey, defaultValue: defaultValue)
    }

    /// Union of flag keys with a remote value (from the last-applied
    /// `/v1/config`) and keys carrying a local override, sorted. Does NOT
    /// fire exposure.
    ///
    /// A dev menu's PRIMARY list should come from the customer's
    /// generated `Flag.allCases` (works on a fresh install with the API
    /// down). This is for the inverse — surfacing server keys the local
    /// codegen doesn't know about yet.
    public func knownFlagKeys() -> [String] {
        guard !destroyedFlag.value else { return [] }
        return flagManager.knownFlagKeys()
    }

    /// A stream of flag-change notifications: fires on config apply
    /// (a `/v1/config` refresh), override set, and override clear.
    /// Multi-subscriber — call this once per observer; each call
    /// registers an independent stream. No Combine/Observation surface
    /// exists in the SDK, so a SwiftUI dev-menu screen should iterate
    /// this in a `.task` to re-render on change.
    ///
    /// After `destroy()`, returns an already-finished stream — a `for
    /// await` consumer sees the loop end immediately rather than hanging
    /// on a stream that will never yield or complete again.
    public func flagChanges() -> AsyncStream<Void> {
        guard !destroyedFlag.value else {
            return AsyncStream { continuation in continuation.finish() }
        }
        return flagManager.changes()
    }

    // MARK: - Public API: Experiments

    /// Get the assigned variant for an experiment.
    public func experiment(_ experimentKey: String) -> SheepitExperimentResult {
        guard !destroyedFlag.value else { return SheepitExperimentResult(variant: "control") }
        return experimentManager.resolve(experimentKey: experimentKey) { [weak self] key, variant in
            self?.track("$experiment_exposure", properties: [
                "experiment_key": key,
                "variant": variant,
            ])
        }
    }

    // MARK: - Public API: Identity

    /// Identify the current user. Call after login.
    ///
    /// Mirrors `packages/sdk-js/src/identity.ts`: re-identifying with the
    /// SAME `userId` only merges traits locally — it does not flush, does
    /// not clear experiment assignments, and does not POST. Only a real
    /// identity CHANGE does that work. Before this gate, an app calling
    /// `identify()` on every screen appearance issued a
    /// `/v1/devices/:id/identify` POST each time.
    public func identify(userId: String, traits: [String: Any]? = nil) {
        guard !destroyedFlag.value else { return }

        let previousUserId = context.userId

        guard previousUserId != userId else {
            // Same user — traits-only merge.
            if let traits { context.updateUserTraits(traits) }
            diagnosticBus.emit(
                .debug,
                .identity,
                code: "identity.identify_noop",
                message: "identify() called with the current userId — traits merged only"
            )
            return
        }

        // Flush events attributed to the previous identity first.
        Task { await flush() }

        context.setUserId(userId)
        if let traits { context.updateUserTraits(traits) }

        // Reset experiments for the new user
        experimentManager.clearAssignments()
        flagManager.clearExposed()

        diagnosticBus.emit(
            .info,
            .identity,
            code: "identity.identified",
            message: "Identity changed",
            data: ["has_previous_user": AnyCodable(previousUserId != nil)]
        )

        // Post identity to server (fire-and-forget). Await registration so
        // /v1/devices/:deviceId/identify targets a device the server knows.
        Task { [weak self] in
            guard let self else { return }
            await self.registrationTask?.value
            await self.deviceManager.identify(
                deviceId: self.context.deviceId,
                userId: userId,
                attributes: traits
            )
        }
    }

    /// Reset identity. Call on logout.
    public func reset() {
        guard !destroyedFlag.value else { return }

        Task { await flush() }
        context.resetIdentity()
        experimentManager.clearAssignments()
        flagManager.clearExposed()
    }

    // MARK: - Public API: Performance

    /// Start a named performance span for custom timing measurement.
    /// Returns the span object. Call `endSpan(_:)` with the same name to complete it.
    public func startSpan(_ name: String, attributes: [String: String] = [:]) {
        guard !destroyedFlag.value else { return }
        Task { await performanceMonitor?.startSpan(name, attributes: attributes) }
    }

    /// End a previously started performance span by name.
    public func endSpan(_ name: String) {
        guard !destroyedFlag.value else { return }
        Task { await performanceMonitor?.endSpan(name) }
    }

    /// Notify the SDK that the first frame has been rendered.
    /// Used for cold/warm start measurement.
    public func markFirstFrame() {
        guard !destroyedFlag.value else { return }
        Task { await performanceMonitor?.markFirstFrame() }
    }

    /// Get a snapshot of current performance metrics.
    public func performanceSummary() async -> SheepitPerformanceSummary? {
        guard !destroyedFlag.value else { return nil }
        return await performanceMonitor?.performanceSummary()
    }

    // MARK: - Public API: Crashes

    /// Add a breadcrumb for crash report context.
    /// Breadcrumbs are recorded in a ring buffer and included in crash reports.
    public func addBreadcrumb(category: String, message: String) {
        guard !destroyedFlag.value else { return }
        crashReporter?.addBreadcrumb(category: category, message: message)
    }

    /// Set the current screen name for crash context.
    public func setScreen(_ screenName: String) {
        guard !destroyedFlag.value else { return }
        crashReporter?.setScreen(screenName)
    }

    // MARK: - Public API: Status

    /// Get current SDK status.
    public func status() -> SDKStatus {
        SDKStatus(
            initialized: !destroyedFlag.value,
            online: connectivity.isOnline,
            queueDepth: queue.size(),
            offlineQueueDepth: offlineQueue.size(),
            lastFlushAt: lastFlushClock.date,
            deviceId: context.deviceId,
            userId: context.userId,
            flagCount: flagManager.count(),
            experimentCount: experimentManager.count(),
            sdkVersion: SDKDefaults.sdkVersion,
            rejectionReason: inertReason
        )
    }

    // MARK: - Public API: Diagnostics

    /// The SDK's diagnostics bus. Subscribe for a live feed of internal
    /// events (transport, config, identity, lifecycle, connectivity)
    /// without enabling `debug` logging.
    ///
    /// ```swift
    /// let cancel = sdk.diagnostics().subscribe { event in
    ///     print(event.code, event.message)
    /// }
    /// ```
    public func diagnostics() -> DiagnosticBus {
        diagnosticBus
    }

    /// The buffered diagnostic events, oldest first. Bounded by
    /// `SheepitConfig.diagnosticBufferSize`.
    public func getRecentDiagnostics() -> [DiagnosticEvent] {
        diagnosticBus.getRecentDiagnostics()
    }

    /// Shut down the SDK. Flushes pending events and performance metrics.
    public func destroy() {
        // testAndSet so exactly one caller runs teardown even if
        // destroy() is called concurrently from two threads.
        guard destroyedFlag.testAndSet() else { return }
        performTeardown()
    }

    /// The actual teardown steps, factored out of `destroy()` so `beginWork()` can run them a
    /// SECOND time for the same instance if `destroy()` landed mid-`start()` (2026-09 security
    /// follow-up round 4, finding MF3-2 — see `beginWork()`'s doc). Every step below must be
    /// idempotent because of that: cancelling an already-cancelled/nil task, stopping an
    /// already-stopped actor, uninstalling an already-uninstalled crash handler, and clearing
    /// an already-nil singleton are all no-ops, so running this twice for one instance is safe
    /// — `destroy()` itself still only ever runs it via its own one-shot `testAndSet` guard.
    private func performTeardown() {
        Task { await flush() }
        flushTask?.cancel()
        flushTask = nil
        registrationTask?.cancel()
        registrationTask = nil
        Task { await configSync.stop() }
        if let monitor = performanceMonitor {
            Task {
                await monitor.flush()
                await monitor.stop()
            }
        }
        if let reporter = crashReporter {
            Task { await reporter.stop() }
        }
        releaseSelfStartingComponents()
        // Finish outstanding flagChanges() streams so a consumer whose
        // lifetime isn't tied to a cancellable scope sees completion
        // rather than hanging forever.
        flagManager.finishAllChanges()
        SheepitClient.instanceLock.lock()
        if SheepitClient.instance === self {
            SheepitClient.instance = nil
        }
        SheepitClient.instanceLock.unlock()
        log.debug("SDK destroyed")
    }

    // MARK: - Private

    /// Test-only: counts every actual `beginWork()` invocation across every instance ever
    /// constructed in this process — deliberately process-global rather than per-instance,
    /// so a concurrent `initialize()` test can prove "at most one racer began work" as a
    /// single deterministic number instead of depending on which specific instance a test can
    /// get a handle to (only the winner is ever returned). `resetBeginWorkCallCountForTesting()`
    /// lets a test scope the count to its own window. Not part of the public surface.
    private static let beginWorkCallCountLock = NSLock()
    private static var _beginWorkCallCountForTesting = 0
    internal static var beginWorkCallCountForTesting: Int {
        beginWorkCallCountLock.lock()
        defer { beginWorkCallCountLock.unlock() }
        return _beginWorkCallCountForTesting
    }
    internal static func resetBeginWorkCallCountForTesting() {
        beginWorkCallCountLock.lock()
        _beginWorkCallCountForTesting = 0
        beginWorkCallCountLock.unlock()
    }

    /// Starts the client's background work: device registration, config sync, the periodic
    /// flush loop, performance/crash monitoring, and the `$session_start` announce. A no-op
    /// on an inert client (rejected key/apiUrl/environment — already fully torn down by
    /// `init`).
    ///
    /// Callers: `create(config:)` and `createForTesting` invoke this immediately after
    /// construction — their callers always want a live, running client back. `initialize(config:)`
    /// invokes it ONLY for the winner of the singleton-publish race, after releasing
    /// `instanceLock` — a LOSER never calls this at all, so it never registers a device, never
    /// installs a crash handler, never emits `$session_start`, and (since round 4, finding
    /// MF3-1) never persists to disk either (2026-09 security follow-up round 3, findings
    /// MF-2/MF-3).
    ///
    /// 🔴 2026-09 security follow-up round 4, finding MF3-2: this used to guard ONLY on
    /// `inertReason`, not `destroyedFlag` — but `initialize(config:)` publishes `instance =
    /// inst` under `instanceLock` and then calls THIS function OUTSIDE the lock, so a thread
    /// that read `shared` in that window and called `destroy()` could finish tearing down
    /// (one-shot, via `destroyedFlag.testAndSet()`) before this ever ran. This function would
    /// then start device registration, config sync, the flush loop, and a crash-handler
    /// install on a client `destroy()` already handled and will never handle again — measured
    /// 40/40 trials, plus a process-global crash handler `destroy()` can no longer remove and
    /// a `ConfigSync` refresh loop nothing holds a reference to (MF-3's exact failure mode,
    /// reintroduced through the new construct/publish window). Guarding on `destroyedFlag` too
    /// closes the case where `destroy()` fully finishes BEFORE this runs. It does NOT close a
    /// host callback calling `destroy()` on the SAME thread partway through `start()` — see
    /// the recheck at the end of this function for that, deterministic, no-race case.
    private func beginWork() {
        guard inertReason == nil, !destroyedFlag.value else { return }
        context.persistOnBeginWork()
        didBeginWork = true
        SheepitClient.beginWorkCallCountLock.lock()
        SheepitClient._beginWorkCallCountForTesting += 1
        SheepitClient.beginWorkCallCountLock.unlock()
        start()
        log.debug("SDK initialized (env: \(config.environment))")

        // `start()` calls host code synchronously — `emitSessionStartIfOwed()` -> `track()` ->
        // `config.onEvent?` — and `LifecycleSafetyTests` already treats a host callback calling
        // `destroy()` on that SAME thread as a supported shape. By the time that callback
        // fires, `start()` has already assigned `flushTask`/`registrationTask`, started
        // `connectivity`, registered `lifecycleObserver`, and enqueued `configSync`'s start —
        // so a nested `destroy()` there tears all of that down correctly. What it CANNOT tear
        // down is whatever `start()` does AFTER the callback returns (currently just
        // `connectivity.onOnline { ... }`) — that runs on an already-torn-down client and
        // `destroy()` will never fire again to catch it (one-shot). Re-checking here and
        // running the SAME teardown steps again if we lost the race in the meantime closes
        // that gap without ever holding a lock across `start()`'s host callouts — a lock held
        // across `start()` would deadlock the exact way round 2's fix exists to prevent.
        // `performTeardown()` is idempotent (see its own doc), so double-running it here is
        // safe; on the far more common non-racing path `destroyedFlag.value` is still `false`
        // and this is a single atomic read with no further effect.
        if destroyedFlag.value {
            performTeardown()
        }
    }

    /// Release every component that begins work in its OWN initializer, rather than in
    /// `start()`. Called from `destroy()` and, for a client whose key was rejected, from
    /// `init` — that client never reaches `start()`, and its `destroy()` early-returns on an
    /// already-latched flag, so `init` is its only chance to let these go.
    ///
    /// 🔴 A component that starts a timer, observer, queue or monitor in its initializer
    /// belongs here. One that only starts work in its own `start()` does not — it is never
    /// started on the inert path. Both calls are idempotent.
    ///
    /// As of this writing NEITHER `lifecycleObserver` nor `connectivity` actually starts
    /// anything in its own initializer — both moved that to their `start()`/`register()`
    /// methods specifically so a rejected-key client wouldn't have to pay for it (see
    /// `ConnectivityMonitor.start()`'s doc). This function is therefore a forward-looking
    /// safety net for the NEXT component that starts itself in `init`, not evidence that one
    /// exists today — don't read its presence as proof anything is currently self-starting.
    private func releaseSelfStartingComponents() {
        releaseSelfStartingComponentsCallCount += 1
        lifecycleObserver.destroy()
        connectivity.destroy()
    }

    private func start() {
        connectivity.start()
        // Register device if this install has never had a successful registration.
        // Capture the task so identify() can await it.
        //
        // 🔴 This used to guard on `storage.string(forKey: StorageKeys.deviceId) == nil` —
        // reading state its OWN CALLER had written one statement earlier, invisible in a
        // diff of either function alone: `beginWork()` calls `context.persistOnBeginWork()`
        // right before calling this, and that write always leaves `gt_device_id` non-nil by
        // the time `start()` runs. So the guard was never true and `registrationTask` was
        // never created — `POST /v1/devices/register` never fired, and `/v1/config` could
        // never resolve the device.
        //
        // Guarding on "did registration ever SUCCEED" instead of "did we mint an id" also
        // matters for the failure case the obvious fix misses: a device whose FIRST
        // registration attempt fails (no network at first launch) still gets a locally-minted
        // id persisted either way — guarding on the id's presence would make that device look
        // permanently "already registered" and never retry.
        //
        // 🔴 A second, distinct bug shipped alongside the fix above: this call always sent
        // `existingDeviceId: nil`. Harmless while registration was dead code — but the guard
        // above was NEVER satisfiable in ANY published version either (verified against
        // `swift-v0.3.0` and the SDK's very first commit: `ContextManager.init` has
        // unconditionally persisted `gt_device_id` before `start()` ever ran since day one),
        // so `POST /v1/devices/register` has never fired in the field. That means every real
        // existing install already carries a LOCALLY-MINTED UUID — never a server-assigned
        // `dev_…` id — stamped on however many months of event history it has. Sending `nil`
        // unconditionally would make the server mint a FRESH `dev_…` id for every one of
        // them (`apps/api/src/routes/v1/devices.ts:139`) and upsert a NEW `device_assignments`
        // row keyed on it, orphaning that entire event history from the device profile the
        // moment registration starts working for real — the harm D-1 exists to prevent, one
        // step later in the pipeline than the dead-guard bug itself.
        //
        // The fix is NOT "always send `context.deviceId`" either — `beginWork()` calls
        // `context.persistOnBeginWork()` before `start()`, and `ContextManager.init` always
        // mints a fresh UUID when storage is empty, so `context.deviceId` is non-nil on every
        // launch including a genuinely fresh install. Sending it unconditionally would mean
        // the server never mints a `dev_…` id for anyone, contradicting the adopt-the-
        // server-assigned-id design this whole registration flow exists to implement.
        //
        // The real discriminator is `context.didMintDeviceId` — "was this id loaded from
        // storage, or generated fresh THIS launch" — which `deviceRegistered` cannot answer:
        //
        // | storage at launch                              | didMint | sends       | server does                            |
        // |--------------------------------------------------|---------|-------------|-----------------------------------------|
        // | fresh install                                     | true    | nil         | mints `dev_…`; SDK adopts it            |
        // | every real existing install (locally-minted UUID) | false   | that UUID   | upserts under it; event history kept    |
        // | a device already holding a server-assigned id     | false   | the `dev_…` | upserts the SAME row (forward-looking — |
        // |   (once registration succeeds, some LATER bug     |         |             | no install is in this state TODAY)      |
        // |   re-triggers a second attempt)                   |         |             |                                          |
        // | previous register attempt failed                  | false   | persisted id| retries idempotently                    |
        //
        // 🔴 A third bug, found alongside the two above: `deviceManager.register()` used to
        // treat EVERY failure identically — network hiccup, 5xx, and a PERMANENTLY rejected
        // key (401/403) or device-cap ceiling (422) all just logged and returned nil, so a
        // revoked key re-hit this endpoint on every single cold start forever, silently
        // (`log.warn` only — nothing on `diagnosticBus`, so neither the host app's own
        // `onDiagnostic` nor GoaTech itself could ever see it happening). `register()` now
        // returns a `RegistrationOutcome` that tells the two apart; see
        // `deviceRegistrationBackoffActive()` for how a terminal failure is remembered
        // without being confused for success.
        if storage.string(forKey: StorageKeys.deviceRegistered) == nil, !deviceRegistrationBackoffActive() {
            registrationTask = Task { [weak self] in
                guard let self else { return }
                // Captured BEFORE the round trip: this is the id every event enqueued during
                // this window (the SDK's own `$session_start`, or an eager host `track()`
                // call) gets stamped with, via `context.eventContext()`. `restampDeviceId`
                // below needs the exact value it read at THAT time, not whatever
                // `context.deviceId` happens to hold once this Task resumes.
                let preRegistrationDeviceId = self.context.deviceId
                switch await self.deviceManager.register(
                    anonymousId: self.context.anonymousId,
                    existingDeviceId: self.context.didMintDeviceId ? nil : self.context.deviceId
                ) {
                case .success(let deviceId):
                    // 🔴 Re-stamp the queue FIRST, then adopt the id. Order is
                    // load-bearing and this is the second time it has been argued;
                    // the deciding fact is the WIRE SHAPE, so read it before touching
                    // these two lines.
                    //
                    // `IngestEvent` carries NO device id (`Types/GeneratedTypes.swift`:
                    // type/event/properties/timestamp only). The id on the wire is
                    // `first.deviceId` — the HEAD of each session group
                    // (`Events/Transport.swift`, `buildPayload`), and groups are cut by
                    // session alone. So a queued event's own `deviceId` is invisible to
                    // the server unless that event is the head of its group.
                    //
                    // That is what makes this order the safe one. `flush()` is public and
                    // deliberately ungated (it never awaits registration settlement), and
                    // `destroy()` also fires one. If a flush lands between these two
                    // statements:
                    //
                    //   • re-stamp first (this order): every queued head already carries
                    //     the NEW id, so the batch files correctly.
                    //   • adopt first: the heads still carry the OLD id, so the WHOLE
                    //     batch files under the pre-registration id — and `drain()` has
                    //     already moved those events to the wire or to `OfflineQueue`,
                    //     which nothing re-stamps, so it is permanent.
                    //
                    // The queue is essentially never empty here ($session_start is
                    // enqueued synchronously in `start()` and auto-flushes are gated), so
                    // "adopt first" loses in the COMMON case, not a rare one.
                    //
                    // The residual this order still carries: a `track()` landing in the
                    // gap reads the old id, and if the queue happens to be empty right
                    // then (a public `flush()` drained it) that event becomes a head and
                    // files under the old id. It needs an empty queue AND a racing
                    // `track()`, so it is strictly narrower than the flush window above.
                    // Closing it fully is structural — see PENDING_WORK.md.
                    if deviceId != preRegistrationDeviceId {
                        self.queue.restampDeviceId(from: preRegistrationDeviceId, to: deviceId)
                    }
                    self.context.setDeviceId(deviceId)
                    self.storage.set("1", forKey: StorageKeys.deviceRegistered)
                case .transientFailure:
                    break // Flag stays unset — the next launch's start() retries, unchanged.
                case .terminalFailure(let statusCode):
                    self.storage.set(
                        String(self.now().timeIntervalSince1970 + SDKDefaults.deviceRegistrationTerminalBackoff),
                        forKey: StorageKeys.deviceRegistrationBackoffUntil
                    )
                    self.diagnosticBus.emit(
                        .error,
                        .identity,
                        code: "identity.device_registration_terminal_failure",
                        message: "Device registration permanently rejected (\(statusCode)) — " +
                            "backing off rather than retrying every launch",
                        data: [
                            "status_code": AnyCodable(statusCode),
                            "outcome": AnyCodable(Self.terminalFailureOutcome(for: statusCode)),
                        ]
                    )
                }
            }
            // Published synchronously, right alongside `registrationTask` itself — a
            // closure built earlier in `init` (the app-background flush handler) cannot
            // capture `self` to read `registrationTask` directly, so it awaits this
            // instead. See `RegistrationGate`'s doc.
            registrationGate.setTask(registrationTask)
        }

        // Start config sync
        Task {
            await configSync.start { [weak self] in
                self?.context.deviceId ?? ""
            }
        }

        // Start periodic flush. `[weak self]` deliberately: this loop otherwise runs for the
        // process lifetime, and an unqualified capture of `config`/`transport` (implicit
        // `self.` inside an instance method) makes it retain `self` strongly — so `self ->
        // flushTask -> this closure -> self` is a real reference cycle, and a host that drops
        // its client without calling `destroy()` leaks it forever (2026-09 follow-up).
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let flushInterval = self?.config.flushInterval else { return }
                // `flushInterval` came from the mutable public
                // `SheepitConfig.flushInterval` — sanitize right before use rather than
                // trusting the initializer clamp already applied to it. `.infinity` (the
                // idiomatic "never auto-flush" value) and `.nan` both trap converting through
                // `Duration`'s internal `Int128` representation; `0`/negative spin this loop
                // at ~150% CPU instead (2026-09 security follow-up round 3, finding MF-1).
                try? await Task.sleep(for: .seconds(flushInterval.sanitizedForSleep()))
                guard !Task.isCancelled else { break }
                await self?.awaitDeviceIdSettlementForAutoFlush()
                guard let transport = self?.transport else { return }
                await transport.flush()
            }
        }

        // Start performance monitoring
        if let monitor = performanceMonitor {
            Task { await monitor.start() }
        }

        // Start crash reporting
        if let reporter = crashReporter {
            Task { await reporter.start() }
        }

        // Flush on background + re-open the session on foreground (both
        // no-ops off UIKit platforms). Assigned before `register()` installs
        // the observer that reads it.
        lifecycleObserver.onForeground = { [weak self] in
            await self?.handleWillEnterForeground()
        }
        lifecycleObserver.register()

        // Announce a fresh install or an app upgrade, if either is owed. This call is
        // textually BEFORE `emitSessionStartIfOwed()` below, but that is not the emission
        // order: `emitAppInstallOrUpdateIfOwed()` reaches `track("$app_install" /
        // "$app_update")`, and `track()` itself calls `emitSessionStartIfOwed()` before
        // `queue.add()`-ing its own event (see `track()`'s `:684` vs `:703`) — so
        // `$session_start` is actually enqueued and delivered to `onEvent` FIRST, on this
        // very first launch. That is deliberate, not a bug: `$session_start` preceding the
        // event that triggered it is a standing, already-shipped invariant with its own
        // test (`SessionEventTests.testSessionStartPrecedesTheEventThatTriggeredIt`), and
        // `DEVICE_CONTEXT_AND_AUDIENCE_ANALYTICS.md` § 4/§ 5 requires no relative ordering
        // between install and session events — what makes the install cohort queryable is
        // `is_first_session` on `$session_start` (§ 5), not which event lands first on the
        // wire. Breaking the shipped invariant to manufacture an ordering nobody asked for
        // would be the wrong trade.
        emitAppInstallOrUpdateIfOwed()

        // Announce the session this launch opened, if it is a new one. Mirrors
        // `packages/sdk-js/src/client.ts:593`, which fires the same event at
        // the end of its own `start()` when `isNewSession` is set. In practice this call is
        // almost always a no-op by the time control reaches it — the recursion described
        // above already consumed the new-session flag on this launch.
        emitSessionStartIfOwed()

        // Drain offline queue when back online
        connectivity.onOnline { [weak self] in
            guard let self else { return }
            let queued = self.offlineQueue.drain()
            if !queued.isEmpty {
                self.log.debug("Back online — re-queuing \(queued.count) offline events")
                for event in queued { self.queue.add(event) }
                Task {
                    await self.awaitDeviceIdSettlementForAutoFlush()
                    await self.transport.flush()
                }
            }
        }
    }

    /// True while a TERMINAL registration failure (401/403/422 — see `RegistrationOutcome`)
    /// is still inside its `SDKDefaults.deviceRegistrationTerminalBackoff` window. Checked
    /// alongside — never in place of — `StorageKeys.deviceRegistered` in `start()`'s guard:
    /// that flag means "succeeded," this one means "gave up for now." Conflating them would
    /// either retry a permanently-doomed request on every single cold start (no backoff) or
    /// permanently strand a device that never actually registered once its key gets fixed
    /// (treating backoff as success). A device with neither flag set — the ordinary case —
    /// always attempts registration, matching the code before this method existed.
    private func deviceRegistrationBackoffActive() -> Bool {
        guard
            let raw = storage.string(forKey: StorageKeys.deviceRegistrationBackoffUntil),
            let until = TimeInterval(raw)
        else { return false }
        return now().timeIntervalSince1970 < until
    }

    /// One `outcome` value per terminal HTTP status, matching this repo's bug-fix
    /// observability convention (CLAUDE.md "Bug-fix observability rule") of a distinct
    /// enum-shaped value per failure mode rather than a single generic string.
    private static func terminalFailureOutcome(for statusCode: Int) -> String {
        switch statusCode {
        case 401: return "revoked_key"
        case 403: return "forbidden"
        case 422: return "device_cap_reached"
        default: return "unknown_terminal_status"
        }
    }

    /// Thin wrapper over `registrationGate.awaitSettlement()` — see that type's doc for why
    /// the gate exists at all instead of every caller just reading `registrationTask`
    /// directly (some can't: they're built before `self` is available).
    ///
    /// Waiting on the gate costs a real delay ONLY inside the narrow first-launch window
    /// while registration is still in flight; it's a synchronous no-op on every later call,
    /// including every later app launch, where `start()` never even calls `setTask`.
    ///
    /// Deliberately used ONLY by SDK-internal, fire-and-forget flush triggers — the
    /// queue-size threshold in `track()`, the periodic `flushTask` loop, the app-background
    /// and app-foreground handlers, and the connectivity-restored handler — none of which a
    /// host app directly awaits. The PUBLIC `flush()` API is never routed through this: a
    /// host that calls it must never be made to wait on a network round trip it didn't ask
    /// for. Without this gate, any of those auto-flush triggers could send events still
    /// stamped with the pre-registration device id before `EventQueue.restampDeviceId`
    /// (called from `start()`'s registration success path) ever runs — the exact race D-1's
    /// registration fix reintroduced by making registration actually happen.
    private func awaitDeviceIdSettlementForAutoFlush() async {
        await registrationGate.awaitSettlement()
    }

    /// Emit `$session_start` if a new session was minted and not yet
    /// announced. Safe to call from any boundary — `takeNewSessionFlag()`
    /// clears the flag, so the event lands exactly once per session.
    ///
    /// One property: `is_first_session` — whether this is the device's very first
    /// session ever, so the install cohort is queryable without a join back to
    /// `$app_install` (§8 decision, "Decided without escalation": `start_reason` was
    /// deferred instead — `StartupTracker` has no resume concept and times `cold_start`
    /// from SDK-init rather than process launch, so a three-value enum would be a lie).
    /// The web SDK attaches UTM / referrer / landing_page here too, but those are
    /// browser-only concepts; putting synthetic values under the same property keys would
    /// corrupt the columns analysts read for web. Everything else an iOS session needs
    /// already rides the event context: `session_id`, `device_id`, `anonymous_id`,
    /// `platform`, `locale`, `timezone`, `sdk_version`, and `app.version` (which the
    /// server resolves into `release_id`).
    /// Recursion terminates at depth 1: this calls `track()`, which calls back
    /// here, but `takeNewSessionFlag()` has already consumed the flag by then,
    /// so the inner call returns immediately. `rolloverIfExpired()` on that
    /// inner pass is likewise a no-op, having just reset `sessionLastSeen`.
    internal func emitSessionStartIfOwed() {
        guard context.takeNewSessionFlag() else { return }
        track("$session_start", properties: ["is_first_session": context.takeIsFirstSession()])
    }

    /// Emits `$app_install` exactly once per fresh install, and `$app_update` whenever the
    /// recorded app version differs from the one running now. Both read/write the SAME
    /// storage key, `StorageKeys.installedAppVersion` (§8, "Decided without escalation").
    /// The decision itself — install / update / nothing — is `AppLifecycleEventDecider`'s;
    /// see that type's doc for why decision 7's suppression check cannot be "does
    /// `StorageKeys.deviceId` exist" by the time this runs.
    ///
    /// The version resolved here MUST match what every other event's wire payload carries.
    /// `Transport.buildPayload` (audit L-005) prefers the host-provided `config.appVersion`
    /// (a release-binding customer sets this to a commit SHA / build tag, not
    /// `CFBundleShortVersionString`, so events resolve to a `Release` row) and only falls
    /// back to `CFBundleShortVersionString` when the host never set it. Using
    /// `DeviceProfile.appVersion()` alone here — as this used to — would make
    /// `previous_version`/`current_version` disagree with `app.version` on every other
    /// event in the same batch, and would mean `$app_update` never fires when only
    /// `config.appVersion` changes, the exact release-upgrade scenario the event exists for.
    ///
    /// A `nil` result (no `config.appVersion` AND no `CFBundleShortVersionString` — the
    /// XCTest host bundle may or may not carry one; a real app always carries at least the
    /// latter) makes this a no-op for THIS launch. If a later launch resolves a version
    /// where an earlier one could not, `context.didMintDeviceId` is already `false` by
    /// then (it is only ever true on the launch that minted the device id), so the decider
    /// permanently returns `.none` and that device silently never gets `$app_install` —
    /// tracked as a known limitation in `PENDING_WORK.md` rather than added machinery for,
    /// since a real app always carries `CFBundleShortVersionString`.
    internal func emitAppInstallOrUpdateIfOwed() {
        guard let currentVersion = config.appVersion ?? DeviceProfile.appVersion() else { return }
        let storedVersion = storage.string(forKey: StorageKeys.installedAppVersion)
        let decision = AppLifecycleEventDecider.decide(
            storedVersion: storedVersion,
            currentVersion: currentVersion,
            didMintDeviceId: context.didMintDeviceId
        )
        storage.set(currentVersion, forKey: StorageKeys.installedAppVersion)
        switch decision {
        case .install:
            track("$app_install")
        case .update(let previousVersion, let currentVersion):
            track("$app_update", properties: [
                "previous_version": previousVersion,
                "current_version": currentVersion,
            ])
        case .none:
            break
        }
    }

    /// Foreground handler — the timely session boundary on UIKit platforms.
    /// `track()` carries the same check for every platform and for the case
    /// where the app was never backgrounded.
    ///
    /// Guarded on `destroyedFlag`: `destroy()` removes the NotificationCenter
    /// observers but cannot cancel a `Task` this notification already spawned,
    /// and without the guard that in-flight task would roll the session over —
    /// persisting a fresh id to `UserDefaults` — and then consume the
    /// new-session flag, whose `track()` a destroyed client silently drops.
    /// The result was a session persisted to disk that never announced itself.
    /// `internal` rather than `private` so the tests can drive it: the macOS
    /// test host compiles out the notification registration entirely.
    internal func handleWillEnterForeground() async {
        guard !destroyedFlag.value else { return }
        await awaitDeviceIdSettlementForAutoFlush()
        await transport.flush()
        context.rolloverIfExpired()
        emitSessionStartIfOwed()
    }

    /// Track an SDK-internal error as an event so it appears in the dashboard.
    /// Guarded against recursion — errors from tracking this event are silently dropped.
    internal func trackSDKError(source: String, error: Error, endpoint: String? = nil) {
        var props: [String: Any] = [
            "source": source,
            "error": error.localizedDescription,
            "platform": "ios",
        ]
        if let endpoint { props["endpoint"] = endpoint }

        if let sdkError = error as? SDKError {
            switch sdkError {
            case .httpError(let code), .serverError(let code):
                props["status_code"] = code
            case .badRequest(let msg):
                props["status_code"] = 400
                props["detail"] = String(msg.prefix(500))
            case .rateLimited:
                props["status_code"] = 429
            default:
                break
            }
        }

        // Use track() directly but don't let failures cascade
        track("$error", properties: props)
    }

    /// Returns the normalized event name, or `nil` if `name` is empty or whitespace-only.
    /// `nil`, not a crash: `track()` used to `precondition` here, taking the host app down
    /// on a caller's typo (2026-09 follow-up, part of the "a rejected key must not abort the
    /// host app" property #972 shipped but did not fully apply here).
    private func validateEventName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.replacingOccurrences(of: "\\s+", with: "_", options: .regularExpression)
            .prefix(SDKDefaults.eventNameMaxLength))
    }
}
