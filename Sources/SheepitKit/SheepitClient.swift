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
/// sheepit.identify(userId: "user_123") // no traits parameter — see `identify(userId:)`
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
    /// segments — `{prefix}_{type}_{slug}_{secret}` — identically in every SDK
    /// (`Docs/Technical/SDK_DEVICE_REGISTRATION_CONTRACT.md` § 5).
    ///
    /// - prefix: `^[A-Za-z0-9][A-Za-z0-9-]{0,15}$`, never compared to a literal. The server mints
    ///   `lp_` today and `si_` is the decided rename with permanent dual-accept (founder,
    ///   2026-09-09); a published SPM version is immutable, so it must admit any future vendor
    ///   prefix too. Same rule as `packages/sdk-js/src/api-key.ts`.
    /// - type: `pub` (a `sec` or `dev` key is refused with its own message).
    /// - slug: `[a-z0-9]{3}`; secret: `[a-f0-9]{64}` — exactly what `generateApiKey()`
    ///   (`packages/shared/src/utils/index.ts`) mints and `apiKeyFormatSchema` accepts, so the
    ///   tightening rejects no real key.
    ///
    /// 🔴 LOAD-BEARING (finding E-002): EXACTLY four segments. Positional matching only works for a
    /// fixed segment count — an "at least 4" version let a two-token prefix
    /// (`my_pub_sec_abc_<secret>`) slide a real `sec` token into the slug slot.
    private enum APIKeyType: String {
        case publishable = "pub"
        case secret = "sec"
        case dev = "dev"
    }

    private static let expectedSegmentCount = 4
    private static let prefixSegmentIndex = 0
    private static let typeSegmentIndex = 1
    private static let slugSegmentIndex = 2
    private static let secretSegmentIndex = 3

    private static func isKeyPrefix(_ segment: Substring) -> Bool {
        guard let first = segment.unicodeScalars.first, (1...16).contains(segment.count) else { return false }
        let alphanumeric: (Unicode.Scalar) -> Bool = {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
        }
        return alphanumeric(first) && segment.unicodeScalars.allSatisfy { alphanumeric($0) || $0 == "-" }
    }

    private static func isKeySlug(_ segment: Substring) -> Bool {
        segment.count == 3 && segment.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) }
    }

    private static func isKeySecret(_ segment: Substring) -> Bool {
        segment.count == 64 && segment.unicodeScalars.allSatisfy { ("a"..."f").contains($0) || ("0"..."9").contains($0) }
    }

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
            + "{prefix}_pub_{env}_{secret}: an alphanumeric prefix (lp, si), a 3-character "
            + "lowercase environment slug and a 64-character lowercase hex secret."

        // 🔴 2026-09 security follow-up (round 2), finding M3: this used to constrain ONLY
        // `segments[secretSegmentIndex]` to printable ASCII, leaving segment 0 (vendor) and
        // segment 2 (slug) unchecked. A CR/LF smuggled into either was admitted here and then
        // made Foundation silently drop the whole `Authorization` header on every request —
        // the exact E-004 silent-401 class this guard exists to close. Checking the WHOLE
        // trimmed key subsumes the narrower secret-only check.
        guard segments.count == expectedSegmentCount,
              isKeyPrefix(segments[prefixSegmentIndex]),
              let type = APIKeyType(rawValue: String(segments[typeSegmentIndex])),
              isKeySlug(segments[slugSegmentIndex]),
              isKeySecret(segments[secretSegmentIndex]),
              trimmed.unicodeScalars.allSatisfy(isPrintableASCII)
        else {
            return malformed
        }

        // Defense in depth, not reachable today: the 64-hex secret rule already rejects a secret
        // equal to "sec" or "dev". Kept so a future relaxation does not silently reopen E-002.
        // Case-insensitive: `SEC`/`Dev` must not evade it either.
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

    /// Printable ASCII (space through `~`). Since 0.10.0 the key's slug and secret rules are
    /// stricter than this; it still guards `environment`, sent verbatim as a header.
    private static func isPrintableASCII(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value >= 0x20 && scalar.value < 0x7F
    }

    /// Why `config.apiUrl` may not drive a client, or `nil` if it may. Identical in every SDK
    /// (`Docs/Technical/SDK_DEVICE_REGISTRATION_CONTRACT.md` § 4). A refusal makes the client
    /// inert (it never falls back to the default host).
    ///
    /// - Must be an absolute `http`/`https` URL with a non-empty host. Foundation returns EMPTY
    ///   strings, not nil, for a missing scheme/host (`"https://user:pass@"` parses with
    ///   `host == ""`), so both are checked for emptiness (round 3, finding MF-5).
    /// - REFUSED: userinfo (`user:pass@` — credentials would ride every request and be echoed into
    ///   logs), a query string or fragment (even empty), a port outside 0…65535 or non-numeric.
    /// - ALLOWED: plain `http`, `localhost`, IPv4/IPv6 literals and registry-style names such as
    ///   `sheepit_api` (BYOC compose), an empty port (`http://h:`, as WHATWG parses it), and a path
    ///   prefix (`https://app.example.com/_sheepit`). Trailing slashes are stripped by `HTTPClient`.
    private static let allowedAPIURLSchemes: Set<String> = ["http", "https"]

    static func apiURLRejectionReason(for apiUrl: String) -> String? {
        let trimmed = apiUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let shown = redactingUserinfo(from: apiUrl)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), allowedAPIURLSchemes.contains(scheme),
              let host = components.host, !host.isEmpty,
              URL(string: trimmed) != nil
        else {
            return "Invalid SheepitConfig.apiUrl \"\(shown)\". Expected "
                + "an absolute http(s) URL including a non-empty scheme and host, e.g. "
                + "\"https://api.sheepit.ai\" or your self-hosted gateway's URL."
        }
        if components.percentEncodedUser != nil || components.percentEncodedPassword != nil {
            return "Invalid SheepitConfig.apiUrl \"\(shown)\": it carries credentials (user:password@). "
                + "Remove them; the SDK authenticates with its API key."
        }
        if components.percentEncodedQuery != nil || components.percentEncodedFragment != nil {
            return "Invalid SheepitConfig.apiUrl \"\(shown)\": a query string or fragment is not allowed. "
                + "Use the base URL only, optionally with a path prefix."
        }
        if let port = components.port, !(1...65_535).contains(port) {
            return "Invalid SheepitConfig.apiUrl \"\(shown)\": port \(port) is out of range."
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
    ///
    /// The third anchor, `scheme:/`, is the single-slash form (`https:/admin:s3cret@gw.corp`),
    /// which parses with no host and so always reaches here; the run after `//` alone could not
    /// cross its lone `/`. It is anchored at the start, so an `@` later in a path is untouched.
    static func redactingUserinfo(from apiUrl: String) -> String {
        apiUrl.replacingOccurrences(
            of: "(^|//|^\\s*[A-Za-z][A-Za-z0-9+.-]*:/)[^/\\s]*@",
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
        // Info.plist first: its message names the plist key and the fix. The field it concerns
        // is left empty, so the generic gates below would reject it too, only less helpfully.
        let reason = config.activeInfoPlistIssueMessage ?? rejectionReason(
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
    /// - Parameter errorCaptureUptime: test-only seam for the monotonic clock of `captureError`'s
    ///   and `recordRequest`'s limiters (each still gets its own limiter).
    /// - Parameter appState: test-only seam for the foreground state (0.6-C). The macOS test
    ///   host has no `UIApplication`, so `AppForegroundState.live()` never tracks state there;
    ///   a test passes one that does, to run the iOS behaviour.
    /// - Parameter identifyRetryDelays: `identifyRetryDelaysForTesting`, set before work begins so the
    ///   launch identify POST already uses it.
    /// - Parameter launchRegistrationRetryDelay: `launchRegistrationRetryDelayForTesting`, likewise.
    /// - Parameter registrationJitter: `RegistrationPolicy.jitterForTesting`, likewise.
    internal static func createForTesting(
        config: SheepitConfig,
        now: @escaping @Sendable () -> Date,
        urlProtocolClasses: [AnyClass]? = nil,
        crashPendingDirectory: URL? = nil,
        crashDirectory: URL? = nil,
        errorCaptureUptime: (@Sendable () -> TimeInterval)? = nil,
        appState: AppForegroundState? = nil,
        identifyRetryDelays: [TimeInterval]? = nil,
        feedbackDirectory: URL? = nil,
        launchRegistrationRetryDelay: (@Sendable (TimeInterval) -> Duration)? = nil,
        registrationJitter: (@Sendable (Double) -> Double)? = nil
    ) -> SheepitClient {
        let reason = rejectionReason(
            for: config.apiKey,
            allowSecretKeyInClient: config.allowSecretKeyInClient
        )
        let inst = SheepitClient(
            config: config,
            inertReason: reason,
            now: now,
            urlProtocolClasses: urlProtocolClasses,
            crashPendingDirectory: crashPendingDirectory,
            crashDirectory: crashDirectory,
            errorCaptureUptime: errorCaptureUptime,
            appState: appState,
            feedbackDirectory: feedbackDirectory
        )
        inst.identifyRetryDelaysForTesting = identifyRetryDelays
        inst.launchRegistrationRetryDelayForTesting = launchRegistrationRetryDelay
        if let registrationJitter { inst.registrationPolicy.jitterForTesting = registrationJitter }
        inst.beginWork()
        return inst
    }

    /// Test-only mirror of `beginWork()` — lets a test invoke exactly what `initialize()`'s
    /// winner calls next, on a candidate built with `constructOnlyForTesting`, WITHOUT needing
    /// an actual race to land in the window `initialize()` itself can't be paused inside of.
    /// `@testable`-internal, so it cannot be reached by an app linking the released package.
    /// See `LifecycleSafetyTests`/`ConcurrentInitializeSideEffectTests` (MF3-2).
    /// Test-only seam: seed the in-memory experiment assignments the way a
    /// `/v1/config` response would, without needing the network.
    ///
    /// 🔴 Exists because the difference between `clearAssignments()` and
    /// `clearForLogout()` is visible ONLY in `assignments`, which nothing else
    /// can reach from a test — so a `reset()` wired to the wrong one was
    /// undetectable, which a mutation run proved. `@testable`-internal, so it
    /// cannot be reached by an app linking the released package.
    ///
    /// ⚠️ Writes the assignments alone, bypassing `ExposureDecisionGate`. A test of what a config
    /// apply does to an exposure decision uses `applyConfigForTesting`, which is the gated path.
    internal func seedAssignmentsForTesting(
        _ assignments: [String: SDKExperimentAssignment],
        appliedUnderUserId: String? = nil, assignmentToken: Any? = nil
    ) {
        experimentManager.setAssignments(assignments, appliedUnder: .fetchedUnder(appliedUnderUserId), assignmentToken: assignmentToken)
    }

    /// Test-only seam: apply flags and assignments exactly as `onConfig` does, through
    /// `ExposureDecisionGate.apply`. `@testable`-internal.
    internal func applyConfigForTesting(
        flags: [String: AnyCodable],
        assignments: [String: SDKExperimentAssignment],
        appliedUnder: ConfigIdentity,
        origin: ConfigApplyOrigin = .server(fetch: .max),
        assignmentToken: Any? = nil
    ) {
        exposureDecisionGate.apply(
            flags: flags,
            assignments: assignments,
            appliedUnder: appliedUnder,
            origin: origin,
            assignmentToken: assignmentToken, context: context, crashReporter: crashReporter,
            to: flagManager,
            experimentManager
        )
    }

    internal var crashReporterForTesting: CrashReporter? { crashReporter }

    /// Test-only: `exposureDecisionGate`, so a test can prove who holds it and who waits for it.
    internal var exposureDecisionGateForTesting: ExposureDecisionGate { exposureDecisionGate }

    /// Test-only: whether an `identify()` switch still awaits its config (`ExperimentManager`).
    internal var identitySwitchPendingForTesting: Bool { experimentManager.capture().identitySwitchPending }

    /// Whether a known-to-known `identify()` holds config writes off the disk (`ConfigSync.persistHold`).
    internal var configPersistHeldForTesting: Bool { configSync.persistHeldForTesting }

    /// Test-only seam: one `/v1/config` fetch through the real `ConfigSync` and its real
    /// `onConfig` wiring, so a test can prove which user id an applied config is recorded under.
    internal func refreshConfigForTesting() async {
        await configSync.refresh(deviceId: context.deviceId)
    }

    /// Test-only seam: exactly what a periodic config refresh tick runs for identity.
    ///
    /// - Parameter beforeSend: run inside the retry's task just before it decides whether to send,
    ///   so a test can land a `reset()` in the window between the tick and the request.
    internal func configRefreshTickForTesting(beforeSend: (@Sendable () -> Void)? = nil) {
        retryIdentityIfUnknown(beforeSendForTesting: beforeSend)
    }

    /// Test-only seam: wait for every identify POST queued so far, including its confirmation
    /// and the config refetch that follows a success.
    internal func awaitIdentityPostForTesting() async {
        await currentIdentifyTask()?.value
    }

    /// Synchronous so the lock is never held across a suspension point.
    private func currentIdentifyTask() -> Task<Void, Never>? {
        identifyLock.lock()
        defer { identifyLock.unlock() }
        return identifyTask
    }

    internal func beginWorkForTesting() {
        beginWork()
    }

    /// Test-only seam: take every event `track()` has queued, as it would go on the wire.
    internal func drainQueuedEventsForTesting() -> [EnrichedEvent] {
        queue.drain()
    }

    /// Test-only seam: the identify ladder's waits before each retry (`IdentifyLadder.retryDelays`),
    /// so a test does not sit out the real 1 s, 2 s and 4 s. `[]` sends each POST once.
    internal var identifyRetryDelaysForTesting: [TimeInterval]? {
        get { identifyLock.lock(); defer { identifyLock.unlock() }; return _identifyRetryDelaysForTesting }
        set { identifyLock.lock(); _identifyRetryDelaysForTesting = newValue; identifyLock.unlock() }
    }

    /// Test-only seam: maps the policy's wait (seconds) before a logout rotation's next attempt to
    /// the real sleep, so a test does not sit out the real backoff (`DeviceRotation`).
    internal var deviceRotationRetryDelayForTesting: (@Sendable (TimeInterval) -> Duration)? {
        get { deviceRotation.retryDelayOverride }
        set { deviceRotation.retryDelayOverride = newValue }
    }

    /// Test-only seam: the same mapping for the launch registration's in-session waits.
    internal var launchRegistrationRetryDelayForTesting: (@Sendable (TimeInterval) -> Duration)? {
        get { registrationTaskLock.lock(); defer { registrationTaskLock.unlock() }; return _launchRetryDelay }
        set { registrationTaskLock.lock(); _launchRetryDelay = newValue; registrationTaskLock.unlock() }
    }

    // MARK: - Internal Components

    /// Non-nil when `create(config:)` refused this client's API key OR apiUrl. Such a client
    /// is inert: see `create(config:)`. Read by `initialize(config:)`, which must not cache
    /// one.
    let inertReason: String?
    private let config: SheepitConfig
    private let log: Logger
    /// This client's slot (`ScopedStorage`): every component reads and writes through it.
    private let storage: StorageProvider
    /// The suite itself, for the storage migrations only (`StorageMigration`, `StorageScope`).
    private let rawStorage: StorageProvider
    /// `internal` rather than `private` so tests can read the live session id.
    /// Not part of the public API — `@testable import` only.
    internal let context: ContextManager
    /// Foreground or background (0.6-C); shared with `lifecycleObserver`, which writes it.
    internal let appState: AppForegroundState
    private let queue: EventQueue
    private let offlineQueue: OfflineQueue
    private let http: HTTPClient
    private let transport: Transport
    /// Internal, not private, so a test can prove an inert client released its
    /// NWPathMonitor. Not part of the public surface.
    let connectivity: ConnectivityMonitor
    private let deviceManager: DeviceManager
    /// The one registration retry/backoff policy, shared with `DeviceRotation` (`RegistrationPolicy`).
    let registrationPolicy: RegistrationPolicy
    /// Internal, not private, so a test can read `overridesAllowedForTests` directly —
    /// see that property's doc for why. Not part of the public surface.
    let flagManager: FlagManager
    private let experimentManager: ExperimentManager
    private let configSync: ConfigSync
    /// Shared with `configSync`: `reset()` and config writes are serialized through it.
    private let configResetGate: ConfigResetGate
    /// `flag()`'s decision and its exposure's assignments come from one applied config.
    private let exposureDecisionGate = ExposureDecisionGate()
    /// Shared with `configSync`: where the applied config came from and when it was fetched.
    private let configFreshness: ConfigFreshnessRecorder
    /// True while the flags in memory came from an unresolved `/v1/config` body applied to memory only
    /// (`ConfigSync.onProvisional`); exposures then carry `config_source: "unresolved"`.
    private let provisionalConfigApplied: LockedValue<Bool>
    /// `configStaleAfter` / `configOfflineMaxAge`, validated here because both are public `var`s.
    private let configLimits: CachedConfigLimits
    private let performanceMonitor: PerformanceMonitor?
    private let crashReporter: CrashReporter?
    /// The crash retry queue. Read by `CrashReporter` when there is one, and aged out by
    /// `start()` when there is not (crash reporting disabled). Injectable only via
    /// `createForTesting`.
    private let crashPendingStore: PendingCrashStore
    /// Internal, not private, for `SheepitClient+ErrorCapture.swift`.
    let diagnosticBus: DiagnosticBus
    /// `internal` so tests can drive its foreground/background transitions (0.6-C).
    internal let lifecycleObserver: AppLifecycleObserver
    private let lastFlushClock = LastFlushClock()
    /// `submitFeedback` delivery and its on-disk retry queue (`SheepitClient+Feedback.swift`).
    let feedbackSender: FeedbackSender
    /// The last name given to `screen(_:)` / `setScreen(_:)`, for the feedback context.
    let currentScreen = LockedValue<String?>(nil)

    private var flushTask: Task<Void, Never>?
    /// The most recent identify POST (`postIdentity`). Each one waits for its predecessor, so the
    /// server stores identities in the order `identify()` was called and a slow earlier POST
    /// cannot land after a later one. Guarded by `identifyLock`: `identify()` runs on any thread.
    private var identifyTask: Task<Void, Never>?
    /// Identify POSTs queued or in flight. Guarded by `identifyLock`; `retryIdentityIfUnknown()`
    /// sends nothing while it is non-zero.
    private var pendingIdentifyPosts = 0
    /// The user whose identify POST the API last rejected with a non-retryable 4xx, or answered
    /// 404 for on a device registered to replace an unknown one (`IdentifyLadder`). Guarded by `identifyLock`; `retryIdentityIfUnknown()` does not
    /// re-send for this user, and a 2xx for any user clears it.
    private var identifyRejectedUserId: String?
    /// The HTTP status that rejection was answered with (`SDKStatus.identity`). Guarded by `identifyLock`.
    private var identifyRejectedStatus: Int?
    /// The user whose identify ladder last ended `.exhausted`, until the next automatic retry trigger
    /// (`retryIdentityIfUnknown`) or a bind. Guarded by `identifyLock`; `identifySameUser` sends
    /// nothing for this user meanwhile, so a host calling `identify()` in a loop is not a POST loop.
    private var identifyExhaustedUserId: String?
    /// See `identifyRetryDelaysForTesting`. Guarded by `identifyLock`; nil in production.
    private var _identifyRetryDelaysForTesting: [TimeInterval]?
    /// The sequence of the last identify POST queued. Guarded by `identifyLock`; lets a wait in
    /// `identify(userId:timeout:)` ignore the end of a POST queued before its own.
    private var identifyPostSequence: UInt64 = 0
    /// The user of every identify POST queued or in flight, by sequence. Guarded by `identifyLock`.
    private var pendingIdentifyPostUsers: [UInt64: String] = [:]
    /// Whether `refetchConfigForAwaitedIdentify()` has a fetch in flight. Guarded by `identifyLock`.
    private var awaitedIdentifyRefetchInFlight = false
    private let identifyLock = NSLock()
    /// The waits behind `identify(userId:timeout:)` and `awaitConfig(timeout:)`.
    let identifyWaiters: IdentifyWaiters
    /// Internal, not private, for `SheepitClient+ErrorCapture.swift`.
    let destroyedFlag = AtomicFlag()
    /// Burst limiter for `captureError` (`SheepitClient+ErrorCapture.swift`), on a monotonic clock.
    let errorCaptureLimiter: ErrorCaptureLimiter
    /// `recordRequest`'s own limiter (`SheepitClient+RequestTelemetry.swift`) — separate, so a
    /// burst of failing requests cannot starve `captureError`, nor the reverse.
    let requestTelemetryLimiter: ErrorCaptureLimiter
    /// What `recordRequest` may record: `config.requestTelemetryHosts` minus the SDK's own API.
    let requestTelemetryPolicy: RequestTelemetryPolicy
    /// Test-only: receives the fire-and-forget final flush that `destroy()` starts, so a suite can
    /// await it before the next test resets a shared stub — otherwise that flush lands in the NEXT
    /// test's request log (measured: `DeviceRegistrationTests`' two `testAnAlreadyRegistered…`
    /// tests run as a pair failed 30/30, here and on `main`). Nil in production.
    static let teardownFlushHookForTesting = LockedHook<Task<Void, Never>>()
    /// Test-only: called with every `addBreadcrumb(category:message:)`, so a test can see a
    /// breadcrumb without installing the crash reporter's signal handlers.
    let breadcrumbHookForTesting = LockedHook<SheepitBreadcrumb>()
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
    ///
    /// Fix round 2 (PR #1170 review, item 10): written from THREE different execution
    /// contexts that are not otherwise synchronized with each other — `start()` (whatever
    /// thread calls `create()`), `scheduleNextLaunchRegistrationAttempt()`'s detached retry
    /// chain (the cooperative thread pool, potentially concurrent with either of the other
    /// two), and `performTeardown()` (`destroy()`, which can itself race the retry chain — see
    /// that method's own doc). A plain `var` here was a real data race, same shape as
    /// `DeviceRotation`'s `task`/`generation`, which already uses exactly this
    /// lock-guarded-computed-property pattern.
    private let registrationTaskLock = NSLock()
    private var _registrationTask: Task<Void, Never>?
    private var _launchRetryDelay: (@Sendable (TimeInterval) -> Duration)?
    private var registrationTask: Task<Void, Never>? {
        get { registrationTaskLock.lock(); defer { registrationTaskLock.unlock() }; return _registrationTask }
        set { registrationTaskLock.lock(); _registrationTask = newValue; registrationTaskLock.unlock() }
    }
    /// Mirrors `registrationTask` for callers that need to await it BEFORE `self` is fully
    /// initialized (see the type's own doc — that's the constraint it exists to route
    /// around).
    ///
    /// Fix round 2 (PR #1170 review, item 13): the claim this used to make — "`start()` writes
    /// to both; every other reader can use whichever it already has access to" — stopped being
    /// true once fix round 1's in-session retry landed. `start()` is still the only writer of
    /// THIS gate, but `registrationTask` (the class field) is reassigned on every retry
    /// attempt by `scheduleNextLaunchRegistrationAttempt()`, deliberately WITHOUT re-arming
    /// this gate — see that method's doc for why (keeping the gate pinned to the FIRST attempt
    /// is what lets `identify()`/auto-flush stop waiting after one failure instead of the whole
    /// retry chain). So `registrationTask` and this gate can point at two DIFFERENT tasks
    /// mid-retry; they are no longer interchangeable for a reader.
    private let registrationGate = RegistrationGate()
    /// Logout rotation (`reset()` on a device a user may be bound to). See the type's doc.
    private let deviceRotation: DeviceRotation
    /// Refreshes the crash context after any device-id change. Built in `init`; see there.
    let deviceIdDidChange: @Sendable () -> Void
    /// Runs BEFORE the in-memory device id changes (`DeviceRotation.Dependencies.beforeDeviceIdChange`).
    private let deviceIdWillChange: @Sendable () -> Void
    /// Test-only: called with the device id every time `deviceIdDidChange` runs.
    let deviceIdChangeHookForTesting = LockedHook<String>()
    /// Test-only: called with the new session id (or "" for none) every time
    /// `sessionDidChange()` refreshes the crash context.
    let sessionChangeHookForTesting = LockedHook<String>()
    /// Test-only: called with the exposure event's name after `flag()` / `experiment()` decided and
    /// before it is tracked, so a test can apply a config inside that window. Nil in production.
    let exposureDecisionHookForTesting = LockedHook<String>()
    /// Test-only: called with the flag key INSIDE `flag()`'s decision gate, after the value was read
    /// and before the assignments are captured, so a test can prove a config apply waits for it.
    /// 🔴 Runs under the gate: a hook that applies a config on this thread deadlocks. Nil in production.
    let flagDecisionInsideGateHookForTesting = LockedHook<String>()
    /// Test-only: called with the new user right after `identify()` stores it, on the calling
    /// thread, so a test can track an event at exactly that point. Nil in production.
    let identifyUserIdSetHookForTesting = LockedHook<String>()
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
        urlProtocolClasses: [AnyClass]? = nil,
        crashPendingDirectory: URL? = nil,
        crashDirectory: URL? = nil,
        errorCaptureUptime: (@Sendable () -> TimeInterval)? = nil,
        appState: AppForegroundState? = nil,
        feedbackDirectory: URL? = nil
    ) {
        self.inertReason = inertReason
        let appState = appState ?? AppForegroundState.live()
        self.appState = appState
        self.crashPendingStore = PendingCrashStore(
            directory: crashPendingDirectory ?? PendingCrashStore.defaultDirectory()
        )
        self.config = config
        self.now = now
        // Monotonic, NOT `now`: a wall-clock step backwards would wedge every window.
        self.errorCaptureLimiter = errorCaptureUptime.map { ErrorCaptureLimiter(uptime: $0) } ?? ErrorCaptureLimiter()
        self.requestTelemetryLimiter = errorCaptureUptime.map { ErrorCaptureLimiter(uptime: $0) } ?? ErrorCaptureLimiter()
        let requestPolicy = RequestTelemetryPolicy(hosts: config.requestTelemetryHosts, apiUrl: config.apiUrl)
        self.requestTelemetryPolicy = requestPolicy
        self.log = Logger(debug: config.debug)
        let bus = DiagnosticBus(bufferSize: config.diagnosticBufferSize)
        if let onDiagnostic = config.onDiagnostic {
            bus.subscribe(onDiagnostic)
        }
        self.diagnosticBus = bus
        if requestPolicy.ignoredEntries > 0 {
            bus.emit(
                .warn,
                .config,
                code: "request_telemetry.invalid_host",
                message: "\(requestPolicy.ignoredEntries) requestTelemetryHosts entr\(requestPolicy.ignoredEntries == 1 ? "y was" : "ies were") ignored: use a bare host name (api.example.com) or *.example.com, with no scheme, port or path"
            )
        }
        if let excluded = requestPolicy.apiHostExcluded {
            bus.emit(
                .warn,
                .config,
                code: "request_telemetry.api_host_excluded",
                message: "recordRequest() records nothing on \(excluded): it is the SDK's own apiUrl host and apiUrl has no path, so every request to it is excluded. Serve the SDK under a path prefix (e.g. https://\(excluded)/_sheepit) to record the app's own requests there"
            )
        }
        let rawStorage = UserDefaultsStorage(suiteName: "ai.goatech.sdk")
        self.rawStorage = rawStorage
        self.storage = ScopedStorage(base: rawStorage, scope: StorageScope.hash(for: config))
        // Judge the key/apiUrl BEFORE touching persistent state (see `create(config:)`).
        // A rejected client must have ZERO side effects on disk — constructing these
        // unconditionally used to rotate the device/session ids that the NEXT,
        // correctly-keyed client would read (2026-09 follow-up, finding E-001).
        //
        // StorageMigration must run before ContextManager reads any key, or an existing
        // install looks brand new: fresh device id, lost identity, lost offline queue,
        // re-bucketed experiments — but only for a client that will actually run.
        if inertReason == nil {
            StorageMigration.run(storage: rawStorage)
        }
        // `persistOnInit: false` UNCONDITIONALLY — not `inertReason == nil` — so construction
        // itself never writes to disk for ANY candidate, live or inert. `beginWork()` is what
        // persists (`context.persistOnBeginWork()`), and it runs only for the client that
        // actually wins the `initialize()` publish race. Before this, a candidate with an
        // ACCEPTED key persisted unconditionally right here in `init`, so a concurrent
        // `initialize()` LOSER — fully constructed, `destroy()`ed unpublished, `beginWork()`
        // never called — still clobbered the WINNER's already-persisted session id with one
        // nobody would ever use again (2026-09 security follow-up round 4, finding MF3-1).
        self.context = ContextManager(
            storage: storage,
            now: now,
            persistOnInit: false,
            launchedInBackground: !appState.isForeground,
            legacyStorage: rawStorage,
            appIdentity: { [appVersion = config.appVersion] in
                let snapshot = TrackSnapshot.capture(appVersion: appVersion)
                return (snapshot.appVersion, snapshot.appBuild)
            }
        )
        self.queue = EventQueue(maxSize: config.maxQueueSize, diagnostics: bus)
        self.offlineQueue = OfflineQueue(storage: storage, diagnostics: bus)
        self.http = HTTPClient(config: config, log: log, urlProtocolClasses: urlProtocolClasses)
        self.connectivity = ConnectivityMonitor()
        // Writes nothing until feedback is queued, so an inert or losing candidate touches no disk.
        self.feedbackSender = FeedbackSender(
            http: http,
            store: PendingFeedbackStore(
                directory: (feedbackDirectory ?? PendingFeedbackStore.defaultBaseDirectory())
                    .appendingPathComponent(StorageScope.hash(for: config), isDirectory: true),
                baseDirectory: feedbackDirectory ?? PendingFeedbackStore.defaultBaseDirectory()
            ),
            diagnostics: bus,
            log: log,
            appVersionOverride: config.appVersion,
            now: now
        )
        self.transport = Transport(
            http: http,
            queue: queue,
            offlineQueue: offlineQueue,
            connectivity: connectivity,
            log: log,
            diagnostics: bus,
            lastFlushClock: lastFlushClock
        )
        self.deviceManager = DeviceManager(http: http, log: log, appVersionOverride: config.appVersion)
        self.registrationPolicy = RegistrationPolicy(
            storage: storage,
            diagnostics: bus,
            log: log,
            now: now,
            appVersion: DeviceProfile.wireAppVersion(override: config.appVersion)
        )
        self.flagManager = FlagManager(diagnostics: bus)
        if inertReason == nil {
            self.flagManager.setOverridesAllowed(config.allowFlagOverrides ?? config.debug)
        }
        self.experimentManager = ExperimentManager(storage: storage, diagnostics: bus)

        // ConfigSync callback applies config to flag/experiment managers.
        // Capture managers (not self) to avoid a reference cycle.
        let fm = self.flagManager
        let em = self.experimentManager
        let decisionGate = self.exposureDecisionGate
        let contextRef = self.context
        let logger = self.log
        let resetGate = ConfigResetGate()
        self.configResetGate = resetGate
        let freshness = ConfigFreshnessRecorder()
        self.configFreshness = freshness
        let provisional = LockedValue(false)
        self.provisionalConfigApplied = provisional
        let limits = CachedConfigLimits(staleAfter: config.configStaleAfter, offlineMaxAge: config.configOfflineMaxAge)
        self.configLimits = limits
        let waiters = IdentifyWaiters(serverHeldUser: { contextRef.serverHeldUser.user })
        self.identifyWaiters = waiters
        // Crash reporting
        if config.crashes.enabled, inertReason == nil {
            let reporter = CrashReporter(
                http: http,
                context: context,
                config: config.crashes,
                appVersionOverride: config.appVersion,
                storage: storage,
                log: log,
                appState: appState,
                crashDirectory: crashDirectory,
                pendingDirectory: crashPendingStore.directory,
                diagnostics: bus,
                refreshActiveState: { reporter in
                    decisionGate.withLock {
                        let snapshot = contextRef.eventContext()
                        fm.refreshValuesObserver()
                        reporter.setExperimentState(em.activeVariants())
                        let receipt = em.receipt(eventUserId: snapshot.userId).receipt
                        return reporter.publishIdentity(snapshot, assignmentToken: receipt.token,
                            identityChanged: receipt.status == "identity_changed")
                    }
                }
            )
            self.crashReporter = reporter
            // Every later change reaches the crash context as it happens; `refreshActiveState` covers
            // what was applied before the handler mapped it.
            fm.setValuesObserver { reporter.setFlagState($0) }
            em.setVariantsObserver { reporter.setExperimentState($0) }
        } else {
            self.crashReporter = nil
        }

        let crashReporterRef = self.crashReporter

        self.configSync = ConfigSync(
            http: http,
            storage: storage,
            refreshInterval: config.configRefreshInterval,
            log: log,
            resetGate: resetGate,
            limits: limits,
            now: now,
            freshness: freshness,
            diagnostics: bus,
            // What the server's device row holds, not the app's id: see `ConfigSync.identityProvider`.
            identityProvider: {
                let held = contextRef.serverHeldUser
                return (held.user.configIdentity, held.epoch)
            },
            // Read under the lock a replacement's swap writes under: a response for a replaced id
            // is discarded, never cached (`ConfigSync.isCurrentDevice`).
            currentDeviceId: { contextRef.deviceId },
            onConfig: { response, fetchedUnder, origin in
                provisional.value = false
                decisionGate.apply(
                    flags: response.flags,
                    assignments: response.experiments,
                    appliedUnder: fetchedUnder,
                    origin: origin,
                    assignmentToken: response.rawAssignmentToken?.value,
                    context: contextRef, crashReporter: crashReporterRef,
                    to: fm,
                    em
                )
                // Inside the reset gate: records only; the waits are decided in `onApplied`.
                waiters.configApplied(fetchedUnder)
                logger.debug(
                    "Config applied: \(response.flags.count) flags, "
                    + "\(response.experiments.count) experiments"
                )
            },
            onProvisional: { response in
                // An unresolved body, applied only while nothing else is: no user, no waiters.
                provisional.value = true
                // Through the gate like any apply, so a read never sees these flags with other
                // assignments; `.provisional`, so an unresolved body never ends an identity switch.
                decisionGate.apply(
                    flags: response.flags,
                    assignments: response.experiments,
                    appliedUnder: .unknown,
                    origin: .provisional,
                    assignmentToken: response.rawAssignmentToken?.value,
                    context: contextRef, crashReporter: crashReporterRef,
                    to: fm,
                    em
                )
                logger.debug("Config applied to memory only (device unresolved): \(response.flags.count) flags")
            },
            onApplied: { waiters.configAppliedOutsideGate() }
        )

        // Performance monitoring
        if config.performance.enabled, inertReason == nil {
            let contention = SamplingContentionCounter()
            let monitor = PerformanceMonitor(
                http: http,
                context: context,
                config: config.performance,
                appVersionOverride: config.appVersion,
                log: log,
                captureContext: {
                    PerfBatchContext.sample(gate: decisionGate, context: contextRef, experiments: em,
                        appVersion: config.appVersion, diagnostics: bus, contention: contention)
                }
            )
            self.performanceMonitor = monitor
        } else {
            self.performanceMonitor = nil
        }

        // One closure for every path that changes the device id (the launch registration's
        // adoption in `start()`, and both halves of a logout rotation), so crash reports
        // always carry the current id. Launch adoption used to skip it: a crash between the
        // first registration and the next context refresh shipped the pre-registration id.
        let deviceIdChangeHook = self.deviceIdChangeHookForTesting
        let perfRef = self.performanceMonitor
        let deviceIdWillChange: @Sendable () -> Void = {
            decisionGate.withLock { em.invalidateReceiptForDeviceChange() }
            perfRef?.identityDidChange()
        }
        self.deviceIdWillChange = deviceIdWillChange
        let deviceIdDidChange: @Sendable () -> Void = {
            decisionGate.withLock { em.invalidateReceiptForDeviceChange() }
            // The device row a span's or window's receipt was issued for is gone.
            perfRef?.identityDidChange()
            crashReporterRef?.updateContext()
            deviceIdChangeHook.value?(contextRef.deviceId)
        }
        self.deviceIdDidChange = deviceIdDidChange

        let destroyedFlagRef = self.destroyedFlag
        let (experimentsRef, flagsRef) = (self.experimentManager, self.flagManager)
        self.deviceRotation = DeviceRotation(.init(
            context: context,
            deviceManager: deviceManager,
            policy: registrationPolicy,
            queue: queue,
            offlineQueue: offlineQueue,
            storage: storage,
            diagnostics: bus,
            configSync: configSync,
            registrationGate: registrationGate,
            now: now,
            isDestroyed: { destroyedFlagRef.value },
            onDeviceIdChanged: deviceIdDidChange,
            onAnonymousDeviceReplaced: {
                experimentsRef.clearExposures()
                flagsRef.clearExposed()
            },
            beforeDeviceIdChange: deviceIdWillChange
        ))
        // C5 (contract § 7): a resolved device answered `unknown_device` — replace it. Weak: the
        // rotation already holds `configSync`.
        configSync.onResolvedDeviceUnknown.value = { [weak rotation = self.deviceRotation] deviceId, outcome in
            rotation?.replaceErasedDevice(deviceId, outcome: outcome) ?? .notCurrent
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
            appState: appState,
            onBackground: {
                await registrationGateRef.awaitSettlement()
                await transportRef.flush()
            }
        )

        // Wire error tracking callbacks
        if let monitor = performanceMonitor {
            Task { [self] in
                await monitor.setOnError { [weak self] error, endpoint in
                    self?.trackSDKError(source: "performance", error: error, endpoint: endpoint)
                }
            }
        }
        if let reporter = crashReporter {
            Task { [self] in
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
            // `error` is `%{private}@`, so in the Xcode console the reason reads `<private>`.
            // An Info.plist reason is SDK-composed and never holds the key value, so repeat it
            // unredacted: a misconfigured xcconfig is otherwise nearly invisible in Debug.
            if let consoleLine = config.infoPlistConsoleWarning(forInertReason: inertReason) {
                log.warn(consoleLine)
            }
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
        track(eventName, properties: properties, decidedAssignments: nil)
    }

    /// Queues a finished session's `$session_end`: its own session id, and its last activity as
    /// the timestamp, not the moment it is noticed.
    private func trackSessionEnd(_ ended: EndedSession) {
        track(
            "$session_end",
            properties: ["duration_ms": ended.durationMs],
            decidedAssignments: nil,
            endedSession: ended
        )
    }

    /// - Parameters:
    ///   - decidedAssignments: the set an exposure's decision was made under
    ///     (`flag()` / `experiment()`); `nil` captures the current one.
    ///   - exposure: what an exposure reports, so a marked one does not spend the exposure dedup
    ///     (`ExperimentManager.receipt`).
    private func track(
        _ eventName: String,
        properties: [String: Any]?,
        decidedAssignments: ExperimentAssignmentSet?,
        exposure: DecidedExposure? = nil,
        endedSession: EndedSession? = nil
    ) {
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
        //
        // Foreground only (0.6-C). In the background nothing mints, announces or extends a
        // session: the event joins the stored session while it is live (`eventContext()`)
        // and otherwise carries none. macOS and watchOS are always foreground here.
        // A `$session_end` belongs to the session that ended, so it neither rolls over nor
        // extends the live one.
        if appState.isForeground, endedSession == nil {
            rolloverSessionIfExpired()
            emitSessionStartIfOwed()
            context.touchSession()
        }
        let (ctx, receipt, receiptSet) = exposureDecisionGate.withLock {
            let snapshot = context.eventContext()
            let set = decidedAssignments ?? experimentManager.capture()
            return (snapshot, stampReceipt(set, exposure, eventUserId: snapshot.userId), set)
        }

        let event = EnrichedEvent(
            eventId: UUID().uuidString,
            eventName: name,
            eventProperties: SheepitClient.withAppState(properties, appState.wireValue),
            deviceId: ctx.deviceId,
            anonymousId: ctx.anonymousId,
            sessionId: endedSession?.id ?? ctx.sessionId,
            userId: ctx.userId,
            platform: ctx.platform,
            sdkVersion: ctx.sdkVersion,
            // Bounded at capture to `ingestContextSchema.device.locale`'s max(16); see
            // `Transport.context(for:)` for the calendar-extension case that exceeds it.
            locale: DeviceProfile.bounded(ctx.locale, 16),
            timezone: ctx.timezone,
            timestamp: SheepitClient.formatEventTimestamp(endedSession?.endedAt ?? Date()),
            // Frozen HERE, not read at flush: an event that waits in the offline queue
            // across an app update or a region change must still describe the app and
            // device that produced it (PILOT_CORRECTNESS_DESIGN.md §2.2).
            snapshot: Self.snapshot(appVersion: config.appVersion, endedSession: endedSession),
            // Stamped here, against the SAME `ctx.userId` the event carries, so the identity
            // comparison and the event's own user cannot disagree (§2.3). An exposure brings the
            // set its decision was made under, so it names the arm the app was given.
            assignmentReceipt: receipt
        )

        queue.add(event)
        crashReporter?.addBreadcrumb(category: "track", message: Self.trackBreadcrumbMessage(name, properties))
        if queue.size() >= config.flushSize {
            Task {
                await awaitDeviceIdSettlementForAutoFlush()
                await transport.flush()
            }
        }
        // Deliberate order: the identity-change diagnostic is about THIS already-enqueued event, so it is
        // reported before the host's `onEvent` runs; both are host callbacks, outside every SDK lock.
        experimentManager.reportIdentityChange(receipt, set: receiptSet, eventUserId: ctx.userId)
        config.onEvent?(name, properties)
    }

    /// The running app and device, except that a `$session_end` carries the version and build its
    /// session began under: it is stamped at the session's last activity, which release health reads
    /// as the session's latest event.
    private static func snapshot(appVersion: String?, endedSession: EndedSession?) -> TrackSnapshot {
        let now = TrackSnapshot.capture(appVersion: appVersion)
        guard let endedSession else { return now }
        return TrackSnapshot(
            appVersion: endedSession.appVersion, appBuild: endedSession.appBuild,
            appNamespace: now.appNamespace, buildChannel: now.buildChannel,
            deviceModel: now.deviceModel, osVersion: now.osVersion, osName: now.osName,
            deviceType: now.deviceType, country: now.country)
    }

    /// An exposure `track` is recording: which experiment arm, or which flag.
    private enum DecidedExposure {
        case experiment(String, variant: String)
        case flag(String)
    }

    /// Caller holds Exposure; native identity and receipt derive from this one snapshot.
    private func publishCrashIdentityLocked() -> Bool {
        let snapshot = context.eventContext()
        let receipt = experimentManager.receipt(eventUserId: snapshot.userId).receipt
        return crashReporter?.publishIdentity(snapshot, assignmentToken: receipt.token,
            identityChanged: receipt.status == "identity_changed") ?? false
    }

    /// Freeze the decided receipt, including explicit identity-switch status, before enqueue.
    private func stampReceipt(
        _ decided: ExperimentAssignmentSet?,
        _ exposure: DecidedExposure?,
        eventUserId: String?
    ) -> AssignmentReceipt {
        let result: (receipt: AssignmentReceipt, forgetFlag: Bool)
        switch exposure {
        case nil:
            result = experimentManager.receipt(decided, eventUserId: eventUserId)
        case .experiment(let key, let variant):
            result = experimentManager.receipt(decided, eventUserId: eventUserId, experimentKey: key, variant: variant)
        case .flag(let key):
            result = experimentManager.receipt(decided, eventUserId: eventUserId, flagKey: key)
            if result.forgetFlag { flagManager.forgetExposures([key]) }
        }
        return result.receipt
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
        // The value and the assignments its exposure carries are read under one gate, so a config
        // applied in between cannot pair this value with the next config's arms. `onExposure` only
        // records here: tracking reaches host closures, which must run outside the gate.
        var decided: (reason: FlagExposureReason, assignments: ExperimentAssignmentSet)?
        let value = exposureDecisionGate.withLock {
            flagManager.evaluate(flagKey: flagKey, defaultValue: defaultValue) { _, _, reason in
                flagDecisionInsideGateHookForTesting.value?(flagKey)
                decided = (reason, experimentManager.capture())
            }
        }
        guard let decided else { return value }
        exposureDecisionHookForTesting.value?("$flag_exposure")
        track("$flag_exposure", properties: withConfigFreshness([
            "flag_key": flagKey,
            // Raw value, not a case description — matches
            // packages/sdk-js/src/client.ts and the
            // `flag_value: "unknown"` event schema.
            "flag_value": value.anyValue,
            // What makes a dedup regression visible server-side: repeated `first`
            // exposures for one device and flag within a session mean it broke again. One
            // legitimate repeat: a `first` sent marked during an identity switch is sent again,
            // attributed, when the switch ends (`ExperimentManager.flagsExposedWhileMarked`).
            "exposure_reason": decided.reason.rawValue,
        ]), decidedAssignments: decided.assignments, exposure: .flag(flagKey))
        if decided.reason == .valueChanged {
            diagnosticBus.emit(
                .info,
                .flag,
                code: "flag.exposure_value_changed",
                message: "Flag value changed — exposure recorded again.",
                data: ["flag_key": AnyCodable(flagKey)]
            )
        }
        return value
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
        // The variant and the assignment set come from one `ExperimentManager` lock acquisition;
        // the exposure carries that set, not whatever config is applied by the time it is tracked.
        var decided: (variant: String, reason: ExperimentExposureReason, assignments: ExperimentAssignmentSet)?
        let result = experimentManager.resolve(experimentKey: experimentKey) { _, variant, reason, assignments in
            decided = (variant, reason, assignments)
        }
        guard let decided else { return result }
        exposureDecisionHookForTesting.value?("$experiment_exposure")
        track("$experiment_exposure", properties: withConfigFreshness([
            "experiment_key": experimentKey,
            "variant": decided.variant,
            "exposure_reason": decided.reason.rawValue,
        ]), decidedAssignments: decided.assignments, exposure: .experiment(experimentKey, variant: decided.variant))
        if decided.reason == .variantChanged {
            diagnosticBus.emit(
                .info,
                .experiment,
                code: "experiment.exposure_variant_changed",
                message: "Experiment arm changed — exposure recorded for the new arm.",
                data: ["experiment_key": AnyCodable(experimentKey), "variant": AnyCodable(decided.variant)]
            )
        }
        return result
    }

    // MARK: - Public API: Identity

    /// Identify the current user. Call after login.
    ///
    /// Mirrors `packages/sdk-js/src/identity.ts`: re-identifying with the
    /// SAME `userId` does not flush, does not clear experiment assignments,
    /// and does not POST. Only a real identity CHANGE does that work. Before
    /// this gate, an app calling `identify()` on every screen appearance
    /// issued a `/v1/devices/:id/identify` POST each time.
    ///
    /// 🔴 **The `traits` parameter was REMOVED in 0.7.0** (founder decision
    /// D-SDK4). It is a compile error now, deliberately: the values were
    /// merged into the device row's `attributes` column on the server, which
    /// survived both `reset()` and a GDPR erase.
    ///
    /// ⚠️ Event properties are NOT a replacement for targeting. Flag and
    /// experiment rules resolve only `user_group` membership, the built-in
    /// context fields and device `attributes.*` — an event property never
    /// reaches the rule evaluator, so a rule referencing one silently matches
    /// nobody. Track the value for dashboards and experiment metrics
    /// (`track("plan_selected", properties: ["plan": "pro"])`); to keep
    /// TARGETING on it, put the user in a group and target `user_group`.
    ///
    /// - Parameter userId: Your own id for this person. Max
    ///   `SDKDefaults.userIdMaxLength` UTF-16 units; a longer one is refused,
    ///   never truncated.
    public func identify(userId: String) {
        dispatchIdentify(userId: userId)
    }

    /// What one `identify(userId:)` call did, for `identify(userId:timeout:)` to wait on.
    enum IdentifyDispatch {
        /// Nothing queued and nothing will bind: destroyed, a `userId` that is too long, or the
        /// same user with a reason not to send (rejected, registration backed off, ladder exhausted).
        case notSent
        /// An identify POST with this sequence (or one already in flight) decides it.
        case posted(UInt64)
        /// The same user, and the row is already known to hold them. POSTs from this sequence on
        /// can still fail the wait.
        case alreadyBound(UInt64)
    }

    /// `identify(userId:)`, reporting what it did.
    @discardableResult
    func dispatchIdentify(userId: String) -> IdentifyDispatch {
        guard !destroyedFlag.value else { return .notSent }

        // Refused, not truncated (founder decision, S3c): ingest and device identify both cap
        // a user id at 256 UTF-16 units, so every event tracked under a longer one was
        // rejected. Truncating would silently merge two users sharing a prefix.
        guard userId.utf16.count <= SDKDefaults.userIdMaxLength else {
            log.error("identify() ignored: userId is \(userId.utf16.count) UTF-16 units, max \(SDKDefaults.userIdMaxLength)")
            diagnosticBus.emit(
                .error,
                .identity,
                code: "identity.identify_rejected",
                message: "identify() ignored — userId exceeds \(SDKDefaults.userIdMaxLength) characters",
                data: [
                    "length": AnyCodable(userId.utf16.count),
                    "max_length": AnyCodable(SDKDefaults.userIdMaxLength),
                ]
            )
            return .notSent
        }

        // Read BEFORE the identity changes: the POST is sent only while no `reset()` has run since
        // this call (`identifySendGuard`). Read after, a `reset()` in between would go unseen.
        let resetToken = configResetGate.current
        let previousUserId = context.userId

        guard previousUserId != userId else {
            // Same user: nothing to flush, nothing to re-bucket. A POST only if the server's row is
            // not known to hold them: the stored id is the app's own label and survives a change of
            // key or environment, so "same user" alone said nothing about THIS server's row.
            return identifySameUser(userId, resetToken: resetToken)
        }

        // Flush events attributed to the previous identity first.
        Task { await flush() }

        // 🔴 One known user to ANOTHER: the config on disk was evaluated for the previous user, and
        // with no age limit (0.10.2) an offline relaunch would apply it to this one forever. Only the
        // persisted copy goes; memory keeps answering until this user's refetch lands, as before.
        // Anonymous to known keeps it: that body is the device's own. BEFORE `setUserId`, which
        // persists the new user: a process killed in between would otherwise relaunch as this user
        // over the previous user's body. Until a body fetched for this user's row lands, nothing
        // else is written to disk (`ConfigSync.dropPersistedCacheForUserChange(newUserId:)`).
        if previousUserId != nil {
            configSync.dropPersistedCacheForUserChange(newUserId: userId)
        }

        // Clears the exposures only. The server's assignments stay, still labelled
        // with the row's previous user, so events tracked until the identify POST succeeds and its
        // refetch lands carry `identity_changed` for every experiment, whatever its kind.
        // 🔴 BEFORE `setUserId`: a `track()` on another thread in between would carry the new user
        // with no switch armed, crediting a device-kind arm to them.
        // The exposures are cleared AFTER it, or a read in between re-fires as the previous user.
        let (switchToken, crashPublished) = exposureDecisionGate.withLock {
            let token = experimentManager.beginIdentitySwitch(to: userId)
            context.setUserId(userId)
            // A span started under the previous user keeps them; the cumulative windows do not.
            performanceMonitor?.identitySwitched()
            experimentManager.clearExposures()
            let published = publishCrashIdentityLocked()
            return (token, published)
        }
        defer { crashReporter?.recordIdentityPublication(crashPublished) }
        identifyUserIdSetHookForTesting.value?(userId)
        // Every wait for the user the app no longer names is superseded.
        identifyWaiters.supersede(by: userId)
        flagManager.clearExposed()

        diagnosticBus.emit(
            .info,
            .identity,
            code: "identity.identified",
            message: "Identity changed",
            data: ["has_previous_user": AnyCodable(previousUserId != nil)]
        )

        // Synchronously, before the POST is even queued: from here until a POST answers, the SDK
        // cannot say which user the server's device row holds (`ServerHeldUser`).
        context.setServerHeldUser(.unknown)
        if registrationTooFarOffForIdentify() {
            // The app's label is kept, so events carry the user and the periodic retry binds the
            // row once the device registers; this call settles now instead of waiting a day.
            diagnosticBus.emit(
                .info,
                .identity,
                code: "identity.identify_deferred",
                message: "identify() not sent: this device is not registered yet and registration is backed off",
                data: ["reason": AnyCodable("not_registered")]
            )
            // Never sent, so never bound: the next server config ends the switch (`IdentitySwitch`).
            // Owed now: a poll answered 304 applies nothing and would leave the switch armed.
            if experimentManager.identityBindSettledWithoutAck(
                switchToken, afterFetch: configSync.fetchesStarted.current) {
                // Weak and guarded: a refetch outliving `destroy()` writes config to shared storage.
                Task { [weak self] in
                    guard let self, !self.destroyedFlag.value else { return }
                    await self.configSync.refetchUnconditionally(deviceId: self.context.deviceId)
                }
            }
            return .notSent
        }
        return .posted(postIdentity(
            userId: userId,
            sendIf: identifySendGuard(resetToken: resetToken),
            identitySwitchToken: switchToken
        ))
    }

    /// IDENTIFY_WAIT_BUDGET (`RegistrationPolicy.identifyWaitBudgetSeconds`): true when the current
    /// device is not registered in this scope and the persisted window still open is longer than an
    /// identify may wait. A shorter window is waited out through `registrationGate`.
    private func registrationTooFarOffForIdentify() -> Bool {
        guard !registrationPolicy.isRegistered(context.deviceId),
              let window = registrationPolicy.openWindow() else { return false }
        return window > RegistrationPolicy.identifyWaitBudgetSeconds
    }

    /// `identify()` with the user the app already names. No-op while the row is known to hold them,
    /// once their POST was rejected (sending it again gets the same answer), while registration is
    /// backed off (the POST can only 404), or after their ladder ran out until the next automatic
    /// retry. Otherwise one POST through the automatic guard, idle-only so it never doubles the launch
    /// POST, and without the user-change side effects: the app's user did not change.
    private func identifySameUser(_ userId: String, resetToken: UInt64) -> IdentifyDispatch {
        // The same guards as the automatic retry, plus "its ladder just ran out": `identify()` is host
        // code and may be called on every screen, so each failure mode needs a reason not to resend.
        let reason: String?
        if context.serverHeldUser.user == .known(userId) {
            reason = nil
        } else if identifyRejected(for: userId) {
            reason = "rejected"
        } else if registrationTooFarOffForIdentify() {
            reason = "not_registered"
        } else if registrationPolicy.isRegistered(context.deviceId), deviceRegistrationBackoffActive() {
            reason = "backoff"
        } else if identifyExhausted(for: userId) {
            reason = "recently_exhausted"
        } else {
            return .posted(postIdentity(
                userId: userId,
                onlyIfIdle: true,
                sendIf: automaticIdentifySendGuard(userId: userId, resetToken: resetToken)
            ))
        }
        diagnosticBus.emit(
            .debug,
            .identity,
            code: "identity.identify_noop",
            message: reason.map { "identify() called with the current userId — no POST (\($0))" }
                ?? "identify() called with the current userId — no POST",
            data: reason.map { ["reason": AnyCodable($0)] }
        )
        return reason == nil ? .alreadyBound(alreadyBoundFailingFrom(userId)) : .notSent
    }

    /// The first POST whose failure fails a wait on a row already known to hold `userId`: the
    /// earliest one for them still queued or in flight (it marks the row unknown as it goes out, so
    /// its failure means the row is no longer known to hold them), else the next one queued.
    private func alreadyBoundFailingFrom(_ userId: String) -> UInt64 {
        identifyLock.lock()
        defer { identifyLock.unlock() }
        return pendingIdentifyPostUsers.filter { $0.value == userId }.keys.min() ?? identifyPostSequence &+ 1
    }

    /// For `identify(userId:timeout:)` on a row already known to hold the user, when the config in
    /// memory was not fetched for them. At most one in flight: a screen awaiting on every appearance
    /// must not turn into one full (ETag-less) config fetch per call.
    func refetchConfigForAwaitedIdentify() {
        identifyLock.lock()
        let start = !awaitedIdentifyRefetchInFlight
        awaitedIdentifyRefetchInFlight = true
        identifyLock.unlock()
        guard start else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.configSync.refetchUnconditionally(deviceId: self.context.deviceId)
            self.awaitedIdentifyRefetchFinished()
        }
    }

    /// Synchronous so the lock is never held across a suspension point.
    private func awaitedIdentifyRefetchFinished() {
        identifyLock.lock()
        awaitedIdentifyRefetchInFlight = false
        identifyLock.unlock()
    }

    /// POST the identity and record what the server's device row holds afterwards.
    ///
    /// 🔴 A 2xx records `.known(userId)` REGARDLESS of the app's current identity: the row holds
    /// the posted user, and labelling it with anything else is how a bounce (A, then B, then A
    /// with the last POST failing) credited A's events to the arms bucketed for B. A failure
    /// records `.unknown`: an unanswered POST may have been stored. A fetch in flight across the
    /// answer is applied as unknown: the label was set unknown when the request was sent, and a
    /// success moves the epoch. A failure moves it only if something recorded a known user since
    /// (`ContextManager.markServerHeldUserUnknown()`).
    ///
    /// 🔴 After a success the config is refetched with no `If-None-Match`. The ETag carries no
    /// user and identifying moves no `config_version`, so a conditional refetch would 304 and keep
    /// the previous user's body. Done here, after the POST, not in `identify()`: a refetch before
    /// the server holds the new user would only fetch the old bucketing again.
    ///
    /// A success that lands after `reset()` still records `.known(userId)` and refetches: the row
    /// does hold that user, and `/v1/config` resolves the user from the row, not from the request
    /// (`config-evaluation-context.ts`), so that refetch returns exactly what the next ordinary poll
    /// after the logout returns. What must not happen is SENDING a POST for a user who has since
    /// logged out, which is `sendIf`.
    ///
    /// - Parameters:
    ///   - sendIf: checked before the request is first sent (`false` sends nothing and leaves the
    ///     label alone) and again before every HTTP retry attempt (`false` ends the POST as
    ///     `.notSent`, label unknown). `identifySendGuard` for `identify()`,
    ///     `automaticIdentifySendGuard` for the launch re-POST and the retry.
    ///   - beforeSendForTesting: see `configRefreshTickForTesting(beforeSend:)`.
    /// - Returns: the sequence of the POST queued, or with `onlyIfIdle` and one already pending, of
    ///   the last one queued. Every exit of the task signals `identifyWaiters` with it, except a
    ///   destroyed client's (`destroy()` ends every wait itself).
    @discardableResult
    private func postIdentity(
        userId: String,
        onlyIfIdle: Bool = false,
        sendIf: (@Sendable () -> Bool)? = nil,
        identitySwitchToken: UInt64? = nil,
        beforeSendForTesting: (@Sendable () -> Void)? = nil
    ) -> UInt64 {
        identifyLock.lock()
        defer { identifyLock.unlock() }
        // Checked and counted under the same lock, so two triggers cannot both see "idle".
        if onlyIfIdle, pendingIdentifyPosts > 0 { return identifyPostSequence }
        pendingIdentifyPosts += 1
        identifyPostSequence &+= 1
        let sequence = identifyPostSequence
        pendingIdentifyPostUsers[sequence] = userId
        let previous = identifyTask
        identifyTask = Task { [weak self] in
            defer { self?.identifyPostFinished(sequence) }
            // Cancelling this task (`destroy()`) cancels every POST queued before it too, so no
            // queued or retrying POST from a destroyed client can move the row later.
            await withTaskCancellationHandler {
                await previous?.value
            } onCancel: {
                previous?.cancel()
            }
            guard !Task.isCancelled, let self, !self.destroyedFlag.value else { return }
            // Await registration so /v1/devices/:deviceId/identify targets a device the server knows.
            // Through the gate, which is lock-guarded: `registrationTask` itself is written by
            // `start()` and `destroy()` on other threads, and ticks and reconnects reach this path.
            await self.registrationGate.awaitSettlement()
            guard !Task.isCancelled, !self.destroyedFlag.value else { return }
            beforeSendForTesting?()
            // 🔴 `sendIf` is re-checked by the ladder before every request, after the queue and the
            // registration wait, not only when the POST was queued: a `reset()` in between, or
            // during the backoff after a 5xx, would otherwise bind the logged-out user to the row
            // again. Only a `reset()` while an attempt is on the wire cannot be undone by the client.
            let isCurrent: () -> Bool = { [weak self] in
                guard let self, !Task.isCancelled, !self.destroyedFlag.value else { return false }
                return sendIf?() ?? true
            }
            let startDeviceId = self.context.deviceId
            let result = await IdentifyLadder.run(deviceId: startDeviceId, IdentifyLadder.Dependencies(
                post: { [weak self, deviceManager] deviceId in
                    // 🔴 Unknown again as each POST goes out, not only when `identify()` was called:
                    // an earlier queued POST may have answered in between and set a known user, and
                    // from the moment this request is sent the server may commit it before any config
                    // fetch is evaluated. Moving from a known user also moves the epoch, invalidating
                    // a fetch already in flight. Here, after the ladder's `isCurrent`, so an attempt that
                    // check stops leaves the label alone (a `reset()` landing between here and
                    // `identifyOnce`'s own `sendIf` still leaves it unknown: one extra refetch).
                    self?.context.markServerHeldUserUnknown()
                    return await deviceManager.identifyOnce(deviceId: deviceId, userId: userId, sendIf: sendIf)
                },
                reregister: { [deviceRotation] deviceId in await deviceRotation.replaceUnknown(deviceId) },
                markBound: { [weak self] deviceId in
                    // 🔴 Before the request: an unanswered POST may still be committed, and a logout
                    // must then rotate this device (`DeviceRotation.deviceMayBeBound()`). And before
                    // `isCurrent`, which `reset()` orders itself against (`IdentifyLadder`).
                    self?.deviceRotation.markBindAttempted(deviceId: deviceId)
                },
                isCurrent: isCurrent,
                sleep: { seconds in try? await Task.sleep(for: .seconds(seconds)) },
                delays: self.identifyRetryDelaysForTesting ?? IdentifyLadder.retryDelays
            ))
            guard !Task.isCancelled, !self.destroyedFlag.value else { return }
            // 🔴 An answer for a device the client has since rotated away from: whatever it did, it did
            // to the abandoned row. Recording it would label the NEW row with that user, and its
            // refetch would name the old device again.
            guard self.context.deviceId == result.deviceId else {
                self.diagnosticBus.emit(
                    .debug,
                    .identity,
                    code: "identity.identify_answer_for_rotated_device",
                    message: "Identify POST answered for a device replaced by reset() — ignored"
                )
                // Never `.ready` from it: it bound the abandoned row.
                self.identifyWaiters.identifyFailed(userId, sequence: sequence)
                return
            }
            if result.outcome.isBound {
                // Recorded even if `sendIf` stopped holding while the answer was on the wire: the
                // row does hold this user, and `/v1/config` resolves the user from the row, so the
                // refetch returns what the next poll after that `reset()` returns (`ServerHeldUser`).
                self.recordIdentifyRejection(nil, status: nil)
                self.recordIdentifyExhausted(nil)
                self.context.setServerHeldUser(.known(userId))
                // After the label: a wait is `.ready` once the refetch below is applied for them.
                self.identifyWaiters.identifyBound(userId)
                self.reportIdentifyResult(result)
                await self.configSync.refetchUnconditionally(deviceId: self.context.deviceId)
                return
            }
            // A failure the app has moved past is stale too: after a `reset()` the label and the
            // device are the rotation's, and the failure says nothing about them (an answer for the
            // rotation's placeholder, which is never registered, is a 404).
            guard isCurrent() else {
                self.identifyWaiters.identifyFailed(userId, sequence: sequence)
                return
            }
            // Nothing sent leaves the label alone: after a `reset()` it is the fresh device's.
            if result.attempts > 0 { self.context.markServerHeldUserUnknown() }
            // Unbound (or unanswered): the next server fetch started after this ends the identity
            // switch this POST was sent for, so a bind that never succeeds cannot keep device-kind
            // claims unattributed for the session. That fetch is made below: a 304 poll applies
            // nothing. A retry or same-user POST carries no token: it settles nothing.
            let settled = identitySwitchToken.map {
                self.experimentManager.identityBindSettledWithoutAck(
                    $0, afterFetch: self.configSync.fetchesStarted.current)
            } ?? false
            // On a replacement device now, but unbound: the config held is the dead device's. Not
            // when settled: the settle's own refetch below fetches for that same device.
            if result.deviceId != startDeviceId, result.outcome != .stale, !settled {
                Task { [weak self] in
                    guard let self, !self.destroyedFlag.value else { return }
                    await self.configSync.refetchUnconditionally(deviceId: result.deviceId)
                }
            }
            switch result.outcome {
            case .rejected:
                self.recordIdentifyRejection(userId, status: result.status)
            case .notFound where result.deviceId != startDeviceId:
                // A device registered a moment ago is unknown too: another try would only register
                // another one, so this user is not retried. Without a replacement (backoff, a failed
                // registration) the retry tick tries again.
                self.recordIdentifyRejection(userId, status: result.status)
            case .exhausted:
                self.recordIdentifyExhausted(userId)
            default:
                break
            }
            self.reportIdentifyResult(result)
            self.identifyWaiters.identifyFailed(userId, sequence: sequence)
            if settled, !self.destroyedFlag.value {
                await self.configSync.refetchUnconditionally(deviceId: self.context.deviceId)
            }
        }
        return sequence
    }

    /// How the bind ended, for the app's diagnostics and the project's own data. `stale` reports
    /// nothing: the app moved on, so there is nothing to fix. Web counterpart: `reportIdentifyResult`.
    private func reportIdentifyResult(_ result: IdentifyLadder.Result) {
        let detail: [String: AnyCodable] = [
            "outcome": AnyCodable(result.outcome.rawValue),
            "attempts": AnyCodable(result.attempts),
            "status": AnyCodable(result.status),
        ]
        switch result.outcome {
        case .bound, .stale:
            return
        case .boundAfterRetry, .boundAfterReregister:
            diagnosticBus.emit(
                .info,
                .identity,
                code: "identity.identify_recovered",
                message: "identify() bound the user after a retry or a fresh device registration",
                data: detail
            )
        case .rejected, .notFound, .exhausted:
            // 🔴 The user stays unbound: config keeps evaluating this device anonymously. The event
            // is what makes that visible in the project's own data, not just a console line.
            diagnosticBus.emit(
                .warn,
                .identity,
                code: "identity.identify_failed",
                message: "identify() could not bind the user on the server — flags evaluate anonymously",
                data: detail
            )
            track("$identify_failed", properties: [
                "outcome": result.outcome.rawValue,
                "attempts": result.attempts,
                "status": result.status,
            ])
        }
    }

    private func identifyPostFinished(_ sequence: UInt64) {
        identifyLock.lock()
        pendingIdentifyPosts -= 1
        pendingIdentifyPostUsers[sequence] = nil
        identifyLock.unlock()
    }

    /// Synchronous so the lock is never held across a suspension point. `status` is the ladder's last
    /// HTTP status; 0 (nothing answered) is stored as nil.
    private func recordIdentifyRejection(_ userId: String?, status: Int?) {
        identifyLock.lock()
        identifyRejectedUserId = userId
        identifyRejectedStatus = status == 0 ? nil : status
        identifyLock.unlock()
    }

    private func recordIdentifyExhausted(_ userId: String?) {
        identifyLock.lock()
        identifyExhaustedUserId = userId
        identifyLock.unlock()
    }

    private func identifyExhausted(for userId: String) -> Bool {
        identifyLock.lock()
        defer { identifyLock.unlock() }
        return identifyExhaustedUserId == userId
    }

    private func lastIdentifyRejection() -> SDKStatus.Identity.IdentifyRejection? {
        identifyLock.lock()
        defer { identifyLock.unlock() }
        return identifyRejectedUserId.map { .init(userId: $0, statusCode: identifyRejectedStatus) }
    }

    private func identifyRejected(for userId: String) -> Bool {
        identifyLock.lock()
        defer { identifyLock.unlock() }
        return identifyRejectedUserId == userId
    }

    /// `sendIf` for an `identify()` POST: send only while no `reset()` has run since `identify()` was
    /// called. Not bound to the user: identifying A then B still sends A's POST first, in order.
    private func identifySendGuard(resetToken: UInt64) -> @Sendable () -> Bool {
        let gate = configResetGate
        return { gate.current == resetToken }
    }

    /// `sendIf` for a POST the SDK re-sends on its own: send only while no `reset()` has run since
    /// it was queued and the app still names this user. The token is read before the caller reads
    /// the user id, so a `reset()` racing the queueing either clears that read or moves the token.
    /// Takes the gate's lock, then the context's, one after the other; never both at once.
    private func automaticIdentifySendGuard(userId: String, resetToken: UInt64) -> @Sendable () -> Bool {
        let gate = configResetGate
        let context = self.context
        return { gate.current == resetToken && context.userId == userId }
    }

    /// Re-send the identify POST while a user is stored, the server-held label is `.unknown`, and no
    /// identify POST is queued or in flight.
    ///
    /// Any identify POST that fails (offline, a 5xx, a 429, a lost response), whether sent at launch
    /// or by `identify()`, otherwise leaves the label unknown for the rest of the session, and every
    /// user-bucketed entry unattributed. Called at most once per periodic config refresh (not the
    /// launch fetch) and on each offline→online transition. A retry is one POST, which bounds it
    /// to one per refresh interval plus one per reconnect, and none once a POST succeeds. It goes through the same serialized chain as
    /// `identify()`: the label is set unknown as the request is sent, and `destroy()` cancels it.
    ///
    /// Not sent while device registration is backed off after a terminal failure (the device is not
    /// on the server, so the POST can only 404), nor for a user whose POST was rejected with a
    /// non-retryable 4xx. Nor once `reset()` ran or the app names another user by the time the POST
    /// would go out (`automaticIdentifySendGuard`).
    private func retryIdentityIfUnknown(beforeSendForTesting: (@Sendable () -> Void)? = nil) {
        // A retry trigger: from here `identify()` with the same user may send again.
        recordIdentifyExhausted(nil)
        let resetToken = configResetGate.current
        guard !destroyedFlag.value, let userId = context.userId,
              context.serverHeldUser.user == .unknown,
              !deviceRegistrationBackoffActive(),
              !identifyRejected(for: userId) else { return }
        postIdentity(
            userId: userId,
            onlyIfIdle: true,
            sendIf: automaticIdentifySendGuard(userId: userId, resetToken: resetToken),
            beforeSendForTesting: beforeSendForTesting
        )
    }

    /// Reset identity. Call on logout.
    public func reset() {
        guard !destroyedFlag.value else { return }

        Task { await flush() }
        // 🔴 The token moves BEFORE the rotation decision is read, which stops every identify POST
        // not yet past its guard. An identify ladder marks its device before it checks that guard
        // (`IdentifyLadder`), so one that passed it has already marked, and the read below rotates.
        // Read first, a ladder that marked and sent between the read and the token kept a device the
        // POST then bound to the logged-out user. Nothing else is cleared here: the config clear
        // still moves the token again below, after the rotation, so no fetch names the old device.
        // Not applied from here on for `awaitConfig`: the config in memory is cleared below.
        configResetGate.reset { identifyWaiters.configCleared() }
        // Every identify wait so far ends `.failed`: the user it waits for is being logged out.
        identifyWaiters.resetHappened()
        // Read before anything is cleared: whether a user is, or may be, on the server's row.
        let rotateDevice = deviceRotation.deviceMayBeBound()
        let mintSession = appState.isForeground
        let crashPublished = exposureDecisionGate.withLock {
            // THIS clear is the one that matters for receipts: it ends the receipt in the same critical
            // section as the identity, so no capture pairs the logged-out receipt with the cleared user.
            // The second one below (inside the config gate, with the evaluated flags and the disk clear)
            // is defence in depth for anything applied between the two; it is not load-bearing alone.
            experimentManager.clearForLogout()
            context.resetIdentity(mintSession: mintSession)
            // After the identity is cleared, still inside the gate: a span or frame window captured
            // before this point carries an older epoch; one captured after reads the cleared identity.
            performanceMonitor?.identityDidChange()
            return publishCrashIdentityLocked()
        }
        defer { crashReporter?.recordIdentityPublication(crashPublished) }
        sessionDidChange()
        // 🔴 Clearing locally is not enough: `/v1/config` evaluates the SERVER's device row, which
        // stays bound to the logged-out user (there is no unbind), so the next fetch re-delivered
        // their values. A device a user may be bound to is swapped for a fresh one (`DeviceRotation`).
        // Before the gate below moves, so a fetch that starts after it cannot name the old device.
        if rotateDevice {
            deviceRotation.rotate()
        } else {
            diagnosticBus.emit(
                .debug,
                .identity,
                code: "identity.device_kept_on_reset",
                message: "reset() on a device no user is bound to — device kept"
            )
        }
        // 🔴 `resetIdentity()` clears the IDENTITY. It does not clear what was
        // evaluated FOR that identity, and those are three separate places: the
        // cached `/v1/config` body in `UserDefaults`, the evaluated flag values
        // in memory, and the server experiment assignments in memory.
        //
        // Leaving any of them means the next user of this device — or this
        // device after a restore, since `UserDefaults` is included in backups —
        // sees the previous user's targeting. The cache key carries no user
        // component, so it persisted and was re-applied on the next launch.
        //
        // Queued events are NOT dropped: `flush()` above sends them, and
        // anything still queued is owed to whoever generated it.
        //
        // 🔴 All of it in ONE critical section of `configResetGate`, which also bumps its token.
        // A config fetch that started before this point writes and applies only inside the same
        // gate and only if the token has not moved, so it can neither write the logged-out user's
        // body back to disk nor apply it to memory, and its ETag is never sent afterwards.
        //
        // There is deliberately no follow-up clear on the `ConfigSync` actor. A detached
        // `clearCache()` ran at an arbitrary later time: it could miss a response that landed
        // first, and it deleted whatever cache was on disk when it finally ran, including one
        // written after this reset (measured deleting a cache seeded 42 µs later).
        configResetGate.reset {
            exposureDecisionGate.withLock {
                experimentManager.clearForLogout()
                _ = publishCrashIdentityLocked()
                flagManager.clearEvaluated()
            }
            identifyWaiters.configCleared()
            // 🔴 The on-disk copy goes SYNCHRONOUSLY, here. A user who logs out and immediately
            // force-quits (or is killed by the OS) must not leave `gt_config` on disk for the next
            // launch to re-apply via `applyLaunchCache(deviceId:)` — precisely the case this
            // exists to prevent, and the one where inclusion in device backups matters most. sdk-js clears
            // synchronously; this keeps the two platforms honest.
            storage.removeObject(forKey: StorageKeys.sdkConfig)
            storage.removeObject(forKey: StorageKeys.sdkConfigCachedAt)
            storage.removeObject(forKey: StorageKeys.sdkConfigFetchedUnder)
            storage.removeObject(forKey: StorageKeys.sdkConfigResolvedFor)
            configFreshness.clear()
            provisionalConfigApplied.value = false
        }
        // Queued feedback carries the logged-out user's words, email and id: deleted now, on this
        // thread, like the cached config above, under every key and environment.
        feedbackSender.store.clear()
    }

    // MARK: - Public API: Performance

    /// Start a named performance span for custom timing measurement.
    /// Returns the span object. Call `endSpan(_:)` with the same name to complete it.
    public func startSpan(_ name: String, attributes: [String: String] = [:]) {
        guard !destroyedFlag.value else { return }
        let snapshot = performanceMonitor?.spanSnapshot()
        Task { await performanceMonitor?.startSpan(name, attributes: attributes, snapshot: snapshot) }
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
        breadcrumbHookForTesting.value?(SheepitBreadcrumb(timestamp: now(), category: category, message: message))
    }

    /// Set the current screen name for crash context. Sends no event — `screen(_:properties:)`
    /// does both.
    ///
    /// The name is normalized like `screen(_:properties:)`'s (trimmed, NUL removed, capped on a
    /// character boundary); an empty result clears the crash context's screen.
    public func setScreen(_ screenName: String) {
        guard !destroyedFlag.value else { return }
        let bounded = Self.boundedScreenName(screenName)
        crashReporter?.setScreen(bounded)
        currentScreen.value = bounded.isEmpty ? nil : bounded
    }

    /// Record that the user is now on `name`: tracks a `$screen` event carrying the property
    /// `screen` = `name` (plus `properties`), and sets the crash context's screen, so a crash
    /// report says where the app was. Call it from your own navigation code — the SDK does not
    /// track screens automatically.
    ///
    /// `name` is normalized by `boundedScreenName` — trimmed, NUL removed, capped at
    /// `SDKDefaults.screenNameMaxUTF8Bytes` (the crash context's fixed C buffer) — so the event
    /// and a later crash report carry the same string. A `screen` key in `properties` is
    /// overwritten by `name`. A name that normalizes to empty (blank, or a single character
    /// wider than the cap) is dropped with a `transport.invalid_screen_name` diagnostic, like
    /// `track()`'s.
    public func screen(_ name: String, properties: [String: Any]? = nil) {
        guard !destroyedFlag.value else { return }

        // Judged AFTER bounding: a lone grapheme cluster wider than the cap bounds to "".
        let screenName = Self.boundedScreenName(name)
        guard !screenName.isEmpty else {
            log.error("screen() called with an empty screen name — event dropped")
            diagnosticBus.emit(
                .error,
                .transport,
                code: "transport.invalid_screen_name",
                message: "Screen name is empty after trimming, NUL removal and the 255-byte cap; event was dropped"
            )
            return
        }

        var props = properties ?? [:]
        props[Self.screenPropertyKey] = screenName
        track(Self.screenEventName, properties: props)
        setScreen(screenName)
    }

    static let screenEventName = "$screen"
    static let screenPropertyKey = "screen"

    /// A `track` breadcrumb's message: the event name, and for `$screen` the screen too
    /// (`"$screen: Checkout"`) — otherwise a crash's trail read "$screen" for every navigation.
    static func trackBreadcrumbMessage(_ name: String, _ properties: [String: Any]?) -> String {
        guard name == screenEventName, let screen = properties?[screenPropertyKey] as? String, !screen.isEmpty else {
            return name
        }
        return "\(name): \(screen)"
    }

    /// `name` trimmed, with every U+0000 removed, then cut to `SDKDefaults.screenNameMaxUTF8Bytes`
    /// on a character boundary and trimmed again (so `bound(bound(x)) == bound(x)`). The C crash context is written with `strlen` and truncated by
    /// BYTE: a NUL would end it early while the event carried the whole string, and a byte cut
    /// could split a multi-byte character. After this, neither can happen.
    static func boundedScreenName(_ name: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: name.unicodeScalars.filter { $0 != "\u{0}" })
        let cleaned = String(scalars).trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""
        var bytes = 0
        for character in cleaned {
            let size = character.utf8.count
            guard bytes + size <= SDKDefaults.screenNameMaxUTF8Bytes else { break }
            result.append(character)
            bytes += size
        }
        // Again after the cut, which can land just after a space: keeps the function idempotent.
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
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
            rejectionReason: inertReason,
            identity: inertReason == nil && !destroyedFlag.value ? identityStatus() : nil,
            configFreshness: inertReason == nil && !destroyedFlag.value
                ? configFreshness.snapshot(now: now(), staleAfter: configLimits.staleAfter) : nil
        )
    }

    /// Adds `config_source` and `config_age_ms` to an exposure event: whether the value came from
    /// the server or the on-device cache, and how old that config was, so an analysis can separate
    /// evaluations made offline from a stale cache. `config_source: "unresolved"` (no age) for a body
    /// the server could not resolve this device for, applied to memory only, so an analysis can drop
    /// those untargeted defaults. Adds nothing when no config is applied.
    private func withConfigFreshness(_ properties: [String: Any]) -> [String: Any] {
        guard let stamp = configFreshness.exposureStamp(now: now()) else {
            guard provisionalConfigApplied.value else { return properties }
            var merged = properties
            merged["config_source"] = "unresolved"
            return merged
        }
        var merged = properties
        merged["config_source"] = stamp.source.rawValue
        // Absent when the age is unknown (a launch cache stamped later than the device clock).
        if let ageMs = stamp.ageMs { merged["config_age_ms"] = ageMs }
        return merged
    }

    private func identityStatus() -> SDKStatus.Identity {
        let serverUser: SDKStatus.Identity.ServerUser
        switch context.serverHeldUser.user {
        case .unknown: serverUser = .unknown
        case .known(let userId?) where !userId.isEmpty: serverUser = .user(userId)
        case .known: serverUser = .anonymous
        }
        return SDKStatus.Identity(
            serverUser: serverUser,
            deviceRegistered: storage.string(forKey: StorageKeys.deviceRegistered) == context.deviceId,
            lastIdentifyRejection: lastIdentifyRejection()
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
    ///
    /// The final flush is fire-and-forget, and the offline backlog stays on disk until it is
    /// answered. A client created on the same storage before that flush finishes loads and sends
    /// the same backlog: stored once (dedup on `event_id`), metered twice. See PENDING_WORK.md,
    /// "two clients on one storage key".
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
        let finalFlush = Task { await flush() }
        Self.teardownFlushHookForTesting.value?(finalFlush)
        flushTask?.cancel()
        flushTask = nil
        registrationTask?.cancel()
        deviceRotation.cancel()
        // An identify POST that retries after teardown (HTTPClient backs off 1 s then 5 s) could
        // move the server's row after a newer client has already recorded what it holds.
        currentIdentifyTask()?.cancel()
        registrationTask = nil
        Task { await configSync.stop() }
        if let monitor = performanceMonitor {
            Task {
                await monitor.flush()
                await monitor.stop()
            }
        }
        if let reporter = crashReporter {
            // Detached HERE, synchronously, before stop() unmaps the crash context: a config apply
            // still in flight would otherwise write into the unmapped page. Clearing waits out a
            // delivery in progress (the observer lock spans it), and breaks the reporter ↔
            // manager reference cycle.
            flagManager.setValuesObserver(nil)
            experimentManager.setVariantsObserver(nil)
            Task { await reporter.stop() }
        }
        let feedback = feedbackSender
        Task { await feedback.stop() }
        releaseSelfStartingComponents()
        // Finish outstanding flagChanges() streams so a consumer whose
        // lifetime isn't tied to a cancellable scope sees completion
        // rather than hanging forever.
        flagManager.finishAllChanges()
        // Every identify / config wait ends; none starts after this.
        identifyWaiters.close()
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
        // Before anything persists or `start()` reads the slot: an upgraded install's unscoped server
        // state goes and its offline queue joins this slot (`StorageScope.adoptLegacyState`). Here,
        // not in `init`, so a candidate that never begins work writes nothing.
        if let adoption = StorageScope.adoptLegacyState(raw: rawStorage, into: offlineQueue) {
            reportScopeAdoption(adoption)
        }
        context.persistOnBeginWork()
        // Every launch, not only the one that carried the legacy id over (`retireLegacyDeviceId`).
        StorageScope.retireLegacyDeviceId(raw: rawStorage, scoped: storage)
        if context.replacedUnusableDeviceId {
            diagnosticBus.emit(
                .warn,
                .identity,
                code: "identity.device_id_replaced_unusable",
                message: "The stored device id cannot be sent, so a fresh one was minted",
                data: ["reason": AnyCodable(context.unusableDeviceIdReason ?? "unknown")]
            )
        }
        experimentManager.dropLegacyStickyMap()
        didBeginWork = true
        SheepitClient.beginWorkCallCountLock.lock()
        SheepitClient._beginWorkCallCountForTesting += 1
        SheepitClient.beginWorkCallCountLock.unlock()
        start()
        log.debug("SDK initialized (env: \(config.environment))")
        // After `start()`, so a host `onDiagnostic` that calls `destroy()` here is caught by the
        // same re-check below as one fired from inside `start()`.
        // `.fault`, not a console line: a self-hosted app that lost `SheepitAPIURL` sends its
        // events to the hosted API without any error, so the unified log must say so. Only for the
        // absent-key case (`activeInfoPlistNotice`): an app that names the hosted API in code or in
        // its plist chose it, and gets no fault.
        if let notice = config.hostedDefaultNotice {
            log.fault(notice)
            diagnosticBus.emit(.info, .config, code: InfoPlistReader.hostedDefaultCode, message: notice)
        }
        for warning in config.activeInfoPlistWarnings {
            log.warn(warning)
            diagnosticBus.emit(.warn, .config, code: InfoPlistReader.warningCode, message: warning)
        }
        for issue in configLimits.issues {
            log.warn(issue)
            diagnosticBus.emit(.warn, .config, code: "config.cache_limit_invalid", message: issue)
        }

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

    /// Emitted here, after `StorageScope`'s process-wide lock is released: a host `onDiagnostic` runs
    /// synchronously and may call into another client that is beginning work.
    private func reportScopeAdoption(_ adoption: StorageScope.Adoption) {
        let queue = adoption.queue
        if queue.unencodable > 0 {
            diagnosticBus.emit(
                .error,
                .transport,
                code: "offline_queue.unencodable_dropped",
                message: "Dropped \(queue.unencodable) events that cannot be encoded as JSON (non-finite number?)",
                data: ["dropped_count": AnyCodable(queue.unencodable)]
            )
        }
        if queue.trimmed > 0 {
            diagnosticBus.emit(
                .warn,
                .transport,
                code: "offline_queue.trimmed",
                message: "Offline queue full (\(offlineQueue.capacity)) — dropped \(queue.trimmed) of the oldest events",
                data: [
                    "max_size": AnyCodable(offlineQueue.capacity),
                    "dropped_count": AnyCodable(queue.trimmed),
                ]
            )
        }
        diagnosticBus.emit(
            .info,
            .identity,
            code: "identity.scope_adopted",
            message: "Upgraded from unscoped storage: server state re-established for this apiUrl, environment and key",
            data: [
                "legacy_server_state_discarded": AnyCodable(adoption.serverStateDiscarded),
                "legacy_queue_events_adopted": AnyCodable(queue.kept),
            ]
        )
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
        // Register this device unless this scope already registered the CURRENT id with the
        // installed app version (`RegistrationPolicy.isRegistered`). Contract:
        // `Docs/Technical/SDK_DEVICE_REGISTRATION_CONTRACT.md`.
        //
        // 🔴 "Client proposes, server disposes": the id `ContextManager` loaded or minted (and
        // `persistOnBeginWork()` just wrote) is proposed as `device_id` on every attempt — never
        // nil. It is already the id on every event, crash and `/v1/config` request, so when the
        // server honours it (always, for a well-formed proposal) nothing changes hands: no
        // re-stamp, no device-id change callback, no config refetch. 0.9.x sent nil on a fresh
        // install, so the server minted `dev_…` and every launch's pre-registration events and
        // config fetch named an id the server never issued.
        //
        // 🔴 Guarded on "did registration SUCCEED" (the scoped marker), never on whether an id
        // exists: `beginWork()` always writes one before this runs, so that guard was never true
        // and registration never fired in any version before 0.4.
        //
        // A persisted backoff window still open defers the first attempt to its end instead of
        // skipping the launch: nothing is sent inside it, and the gate is NOT armed for it, so
        // `identify()` and the auto-flush do not wait out a window of up to 24 h.
        if !registrationPolicy.isRegistered(context.deviceId) {
            let proposal = context.deviceId
            if let window = registrationPolicy.openWindow() {
                scheduleNextLaunchRegistrationAttempt(proposal: proposal, after: window)
                // Within IDENTIFY_WAIT_BUDGET an identify waits for this attempt; past it the gate
                // stays unarmed and `identify()` settles "not registered yet" instead of waiting.
                if window <= RegistrationPolicy.identifyWaitBudgetSeconds {
                    registrationGate.setTask(registrationTask)
                }
            } else {
                registrationTask = Task { [weak self] in
                    await self?.attemptLaunchRegistration(proposal: proposal)
                }
                // Published synchronously, right alongside `registrationTask` itself — a
                // closure built earlier in `init` (the app-background flush handler) cannot
                // capture `self` to read `registrationTask` directly, so it awaits this
                // instead. See `RegistrationGate`'s doc.
                registrationGate.setTask(registrationTask)
            }
        }

        // 🔴 Every identified launch re-sends its identify POST once, whatever the label says. The
        // client cannot see the server's commit order: a POST it stopped waiting for (a timeout, a
        // lost connection, or one already on the wire when `destroy()` ran) can commit after a
        // later POST succeeded, leaving the row on another user while the label names this one.
        // Re-sending bounds that to the session it happened in; without it, it lasted until a
        // different user was identified, across relaunches (identifying the same user is a no-op).
        // It also covers an install upgraded from an SDK that did not record the row, and a POST
        // that failed before the app was killed. Cost: one POST per identified launch. The route's
        // same-user path writes no merge record and consumes no merge rate limit.
        //
        // 🔴 Unknown BEFORE config sync starts: this POST changes what the row is known to hold,
        // and the previous process's POST may already be committed.
        //
        // 🔴 Guarded like the retry: it waits for registration, and a `reset()` in that window ("session
        // expired" at launch) must not bind the logged-out user to the row again.
        let launchResetToken = configResetGate.current
        let launchUserId = context.userId
        if launchUserId != nil {
            context.setServerHeldUser(.unknown)
        }

        // 🔴 The cached config is applied HERE, synchronously, before `create(config:)` /
        // `initialize(config:)` return: a flag read on the app's next line must answer with the
        // cached value even when the server is unreachable. Applied from inside the `Task` below,
        // it raced the app's first reads, and an app that reads its flags once at launch kept the
        // defaults for the session. Race-free off the actor: see
        // `ConfigSync.applyLaunchCache(deviceId:)`.
        //
        // 🔴 Between the `.unknown` mark and the launch POST: the mark decides the label the cache
        // is applied under, and the POST, the one writer that can move that label to a USER, is not
        // queued yet, so no answer to it can land first. The app cannot call `identify()` either:
        // the client has not been handed back. One other writer is already running: the launch
        // registration above, which on a REPLACED id labels the fresh row `.known(nil)`
        // (`adoptLaunchRegistration`). Its answer landing before this line needs a full round trip
        // inside a few synchronous calls; if it does, the label it writes is true of the row (no
        // user), never another user's.
        configSync.applyLaunchCache(deviceId: context.deviceId)

        if let userId = launchUserId {
            // Past IDENTIFY_WAIT_BUDGET the POST could only 404: the periodic retry binds once the
            // device has registered (`retryIdentityIfUnknown`).
            if !registrationTooFarOffForIdentify() {
                postIdentity(
                    userId: userId,
                    sendIf: automaticIdentifySendGuard(userId: userId, resetToken: launchResetToken)
                )
            }
        }

        // F-2: bind an identified install's C5 replacement at once, through the same retry.
        deviceRotation.onIdentifiedDeviceReplaced.value = { [weak self] in self?.retryIdentityIfUnknown() }

        // Start config sync
        Task { [self] in
            await configSync.start(
                deviceIdGetter: { [weak self] in self?.context.deviceId ?? "" },
                onRefreshTick: { [weak self] in self?.retryIdentityIfUnknown() }
            )
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

        // Start crash reporting — or, with crash reporting disabled, age out whatever an
        // earlier enabled launch left queued (sends nothing). Here, not in `init`: an inert or
        // losing client never reaches `start()` and must touch no disk.
        if let reporter = crashReporter {
            Task { await reporter.start() }
        } else {
            // Off the caller's thread, like the enabled path: `start()` runs inside `create()`,
            // usually on the main thread, and this lists and deletes files.
            let store = crashPendingStore
            let bus = diagnosticBus
            let logger = log
            let clock = now
            Task.detached {
                CrashReporter.reapExhausted(store: store, now: clock(), diagnostics: bus, log: logger)
            }
        }

        // Feedback an earlier launch could not deliver. Off this thread: it lists directories.
        // First, other scopes' queues (an old key or environment) nobody can send any more.
        let feedback = feedbackSender
        let feedbackClock = now
        Task.detached {
            feedback.store.reapStrandedScopes(now: feedbackClock(), maxAge: FeedbackSender.maxAge)
            await feedback.drain()
        }

        // Flush on background + re-open the session on foreground (both
        // no-ops off UIKit platforms). Assigned before `register()` installs
        // the observer that reads it.
        // 🔴 0.6-C: after a background launch this is what opens the first session — the
        // notification flips `appState` first, then `handleWillEnterForeground()` mints and
        // announces it exactly once.
        lifecycleObserver.onForeground = { [weak self] in
            await self?.handleWillEnterForeground()
        }
        lifecycleObserver.onEnterBackground = { [weak self] in
            guard let self, !self.destroyedFlag.value else { return }
            self.context.touchSessionIfLive()
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

        // Flush as soon as connectivity returns rather than waiting for the next tick.
        // `Transport.flush()` sends the offline queue itself (S3c), so this no longer moves
        // anything; moving it here too would put one event in both queues.
        connectivity.onOnline { [weak self] in
            guard let self else { return }
            // A launch identify POST that failed while offline is re-sent once the network is back.
            self.retryIdentityIfUnknown()
            guard self.offlineQueue.size() > 0 else { return }
            Task {
                await self.awaitDeviceIdSettlementForAutoFlush()
                await self.transport.flush()
            }
        }
    }

    /// One launch-registration attempt of `proposal`, the id in use when the chain started. Every
    /// failure is persisted by `RegistrationPolicy` and the next attempt scheduled after the window
    /// it returns, until the launch's attempt budget is spent or the answer is terminal.
    /// `proposal` is also the chain's supersession guard: once `reset()` rotates to another device
    /// (`DeviceRotation`), nothing this chain learns is applied.
    private func attemptLaunchRegistration(proposal: String) async {
        guard context.deviceId == proposal, !Task.isCancelled, !destroyedFlag.value else { return }
        guard registrationPolicy.takeAttempt() else { return }
        let outcome = await deviceManager.register(anonymousId: context.anonymousId, proposedDeviceId: proposal)
        // 🔴 A logout rotation ran while this was in flight: the answer is about the device the
        // logout abandoned. Adopting it would put the logged-out user's row back in use, and a
        // failure says nothing about the new device, so it must not back it off either.
        guard context.deviceId == proposal else {
            diagnosticBus.emit(
                .debug,
                .identity,
                code: "identity.device_registration_superseded",
                message: "Launch registration answered after reset() switched devices — discarded"
            )
            return
        }
        switch outcome {
        case .success(let deviceId):
            adoptLaunchRegistration(deviceId, proposal: proposal)
        case .transientFailure(let reason, let retryAfter):
            guard !Task.isCancelled else { return }
            launchRegistrationFailed(.transient, outcome: reason, data: [:], retryAfter: retryAfter, proposal: proposal)
        case .terminalFailure(let rejection):
            launchRegistrationFailed(
                .terminal,
                outcome: Self.terminalFailureOutcome(for: rejection),
                data: rejection.diagnosticData,
                proposal: proposal
            )
        case .capReached(let rejection, let retryAfter):
            guard !Task.isCancelled else { return }
            launchRegistrationFailed(
                .cap,
                outcome: "device_cap_reached",
                data: rejection.diagnosticData,
                retryAfter: retryAfter,
                proposal: proposal
            )
        case .rateLimited(let retryAfter):
            guard !Task.isCancelled else { return }
            launchRegistrationFailed(
                .rateLimited,
                outcome: "rate_limited",
                data: ["status_code": AnyCodable(429)],
                retryAfter: retryAfter,
                proposal: proposal
            )
        }
    }

    /// The answer's `device_id` becomes this device's. Equal to the proposal (the normal case):
    /// the registered marker is written, and config is refetched unless a body the server resolved
    /// for this device already applies (`ConfigSync.refetchAfterRegistration`). Replaced by the server: the swap machinery runs —
    /// persist the adopted id FIRST, then re-stamp both queues, then adopt it in memory
    /// (compare-and-set), label the new row, refresh the crash context and refetch config. So no
    /// re-stamped event can leave, or sit on disk, before the id it names is durable. A public
    /// `flush()` landing between the persist and the in-memory re-stamp still sends the queued events
    /// under the proposal: the accepted cost of persisting first (listed for the PR body).
    ///
    /// Residuals of the replaced case, both structural (see PENDING_WORK.md): a `track()` racing
    /// this block reads the old id and enqueues it after the re-stamp; and a request already in
    /// flight that then fails persists its LIVE old-id events after the re-stamp ran.
    private func adoptLaunchRegistration(_ deviceId: String, proposal: String) {
        if deviceId != proposal {
            context.persistDeviceIdAhead(deviceId)
            queue.restampDeviceId(from: proposal, to: deviceId)
            offlineQueue.restampDeviceId(from: proposal, to: deviceId)
            deviceIdWillChange()
            guard context.replaceDeviceId(proposal, with: deviceId) else {
                // A rotation won the race: put its id back on disk.
                context.persistDeviceIdAhead(context.deviceId)
                return
            }
            // After the compare-and-set, so a lost race never relabels the rotation's device. A
            // replaced id is a row the server created for this request: it holds no user.
            context.setServerHeldUser(.known(nil))
        }
        registrationPolicy.recordSuccess(deviceId)
        diagnosticBus.emit(
            .info,
            .identity,
            code: "identity.device_registered",
            message: deviceId == proposal
                ? "Device registered under its own id"
                : "Device registered; the server replaced the proposed id",
            data: ["outcome": AnyCodable(deviceId == proposal ? "proposed" : "replaced")]
        )
        let replaced = deviceId != proposal
        if replaced { deviceIdDidChange() }
        // The launch fetch started alongside this registration, so on a fresh install it named a
        // device with no row and was refused; nothing else refetches until the next poll.
        guard !destroyedFlag.value else { return }
        let configSync = self.configSync
        let isCurrent: @Sendable () -> Bool = { [weak self] in
            guard let self else { return false }
            return !self.destroyedFlag.value && self.context.deviceId == deviceId
        }
        Task {
            await configSync.refetchAfterRegistration(
                deviceId: deviceId, replaced: replaced, isCurrent: isCurrent)
        }
    }

    /// Persists the failure, reports it, and schedules the next attempt unless the answer was
    /// terminal. Every failure class reaches here: there is no return path without a write.
    private func launchRegistrationFailed(
        _ failure: RegistrationPolicy.FailureClass,
        outcome: String,
        data: [String: AnyCodable],
        retryAfter: TimeInterval? = nil,
        proposal: String
    ) {
        let wait = registrationPolicy.recordFailure(failure, retryAfter: retryAfter)
        var payload = data
        payload["outcome"] = AnyCodable(outcome)
        if let wait { payload["retry_in_ms"] = AnyCodable(Int(wait * 1000)) }
        switch failure {
        case .terminal:
            diagnosticBus.emit(
                .error,
                .identity,
                code: "identity.device_registration_terminal_failure",
                message: "Device registration permanently rejected — backing off 24 h rather than retrying every launch",
                data: payload
            )
        case .cap, .rateLimited:
            diagnosticBus.emit(
                .warn,
                .identity,
                code: "identity.device_registration_cap_reached",
                message: "Device registration throttled (\(outcome)) — retrying with backoff",
                data: payload
            )
        case .transient:
            diagnosticBus.emit(
                .warn,
                .identity,
                code: "identity.device_registration_failed",
                message: "Device registration failed — retrying with backoff",
                data: payload
            )
        }
        guard let wait else { return }
        scheduleNextLaunchRegistrationAttempt(proposal: proposal, after: wait)
    }

    /// Spawns the NEXT launch-registration attempt as its OWN unstructured `Task` instead of
    /// recursing inline within the current one. `registrationGate` (and so every auto-flush and
    /// `identify()` waiting on it) was fed the FIRST attempt's task only; a retry chain recursing
    /// inside that task would keep them blocked for the whole chain (up to an hour per wait).
    /// Reassigning `registrationTask` here (but never re-arming the gate) keeps `destroy()` able to
    /// cancel whichever attempt is pending.
    ///
    /// Checks `destroyedFlag` BEFORE scheduling: `destroy()` flips it before `performTeardown()`
    /// cancels `registrationTask`, so a task published after that point would never be cancelled.
    private func scheduleNextLaunchRegistrationAttempt(proposal: String, after seconds: TimeInterval) {
        guard !destroyedFlag.value else { return }
        let delay = launchRegistrationRetryDelayForTesting?(seconds) ?? .seconds(seconds)
        registrationTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, !self.destroyedFlag.value else { return }
            await self.attemptLaunchRegistration(proposal: proposal)
        }
    }

    /// True while a persisted registration backoff window is open (`RegistrationPolicy`). It means
    /// "gave up for now", never "succeeded": the two are separate keys.
    private func deviceRegistrationBackoffActive() -> Bool {
        registrationPolicy.openWindow() != nil
    }
    /// One `outcome` value per terminal HTTP status, matching this repo's bug-fix
    /// observability convention (CLAUDE.md "Bug-fix observability rule") of a distinct
    /// enum-shaped value per failure mode rather than a single generic string. 422 is NOT
    /// here — it is `.capReached`, not `.terminalFailure`, and its own branch above stamps
    /// `"device_cap_reached"` directly.
    private static func terminalFailureOutcome(for rejection: RegistrationRejection) -> String {
        if rejection.reason == RegistrationRejection.validationError { return "invalid_request" }
        switch rejection.statusCode {
        case 400: return "invalid_request"
        case 401: return "revoked_key"
        case 403: return "forbidden"
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
    ///
    /// Also announces the session that just aged out (`$session_end`), BEFORE the start of its
    /// successor. Both are taken first so the nested `track()` calls find nothing owed.
    internal func emitSessionStartIfOwed() {
        guard !destroyedFlag.value else { return }
        let ended = context.takeEndedSession()
        let startOwed = context.takeNewSessionFlag()
        if let ended {
            trackSessionEnd(ended)
            context.markSessionEndQueued(ended.id)
        }
        guard startOwed else { return }
        track("$session_start", properties: ["is_first_session": context.takeIsFirstSession()])
    }

    /// Emits `$app_install` exactly once per fresh install, and `$app_update` whenever the
    /// recorded app version differs from the one running now. Both read/write the SAME
    /// storage key, `StorageKeys.installedAppVersion` (§8, "Decided without escalation").
    /// The decision itself — install / update / nothing — is `AppLifecycleEventDecider`'s;
    /// see that type's doc for why decision 7's suppression check cannot be "does
    /// `StorageKeys.deviceId` exist" by the time this runs.
    ///
    /// The version resolved here MUST match what every other event's wire payload carries,
    /// so it is `DeviceProfile.wireAppVersion(override:)`: `config.appVersion` when the host
    /// set it, else `CFBundleShortVersionString`, bounded exactly as every stream bounds it.
    /// The STORED value is bounded the same way before comparing, so a long version stored
    /// unbounded by an older SDK does not fire one spurious `$app_update` after the upgrade.
    /// Using `DeviceProfile.appVersion()` alone here — as this used to — would make
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
        guard let currentVersion = DeviceProfile.wireAppVersion(override: config.appVersion) else { return }
        let storedVersion = DeviceProfile.hostOverride(storage.string(forKey: StorageKeys.installedAppVersion))
            .map { DeviceProfile.boundedForAllStreams($0) }
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

    /// `properties` plus `app_state` (0.6-C), when the state is tracked. A host property of the
    /// same name is kept: the host's value is the one record the SDK cannot rebuild.
    static func withAppState(_ properties: [String: Any]?, _ appState: String?) -> [String: AnyCodable]? {
        var wire = properties?.mapValues { AnyCodable($0) }
        guard let appState else { return wire }
        if wire == nil { wire = [:] }
        if wire?["app_state"] == nil { wire?["app_state"] = AnyCodable(appState) }
        return wire
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
        rolloverSessionIfExpired()
        emitSessionStartIfOwed()
    }

    private func rolloverSessionIfExpired() {
        if context.rolloverIfExpired() { sessionDidChange() }
    }

    /// Every path that changes the session id refreshes the crash context, which holds its own
    /// copy. It was written only at crash-handler install and on a device-id change, so a crash
    /// after a rollover shipped the previous session — and, since 0.6-C, a crash after the first
    /// foreground of a background launch would ship none, which release health counts as an
    /// orphan crash.
    private func sessionDidChange() {
        crashReporter?.updateContext()
        sessionChangeHookForTesting.value?(context.sessionId ?? "")
    }

    /// Track an SDK-internal error as a `$error` event so it appears in the dashboard.
    /// `origin: "sdk"` / `type: "sdk_internal"` separate it from a host app's
    /// `captureError` (`origin: "app"` / `type: "handled"`); `source` is what the server's
    /// host-app error predicate excludes on.
    ///
    /// No recursion is possible: only `PerformanceMonitor` and `CrashReporter` call this, and
    /// a failed SEND of this event goes to the `DiagnosticBus` (`transport.*`), never back here.
    internal func trackSDKError(source: String, error: Error, endpoint: String? = nil) {
        var props: [String: Any] = [
            "source": source,
            "error": error.localizedDescription,
            "platform": DeviceProfile.platform,
            "origin": "sdk",
            "type": "sdk_internal",
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

        track(SDKErrorEvent.name, properties: props)
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
