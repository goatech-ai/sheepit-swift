import Foundation

// MARK: - Configuration

/// Configuration for the Sheepit SDK.
public struct SheepitConfig: Sendable {
    /// Default API URL. Update this when migrating to a custom domain.
    public static let defaultAPIUrl = "https://api.sheepit.ai"

    public let apiKey: String
    public var environment: String
    public var apiUrl: String
    /// Clamped to `TimeInterval.sleepFloor...TimeInterval.sleepCeiling` IN THE INITIALIZER
    /// only — this is a `var`, so `var cfg = ...; cfg.flushInterval = .infinity` bypasses
    /// that clamp entirely. The property is public and mutable for good reason (a host may
    /// want to change the flush cadence at runtime), so the REAL fix lives at the consumer —
    /// every `Task.sleep(for: .seconds(flushInterval))` site sanitizes via
    /// `TimeInterval.sanitizedForSleep()` right before use. `.infinity` (the idiomatic "never
    /// auto-flush" value) and `.nan` both trap converting through `Duration`'s internal
    /// `Int128` representation; `0`/negative don't trap but spin the flush loop at ~150% CPU
    /// (2026-09 security follow-up round 3, finding MF-1). This initializer clamp is defense
    /// in depth, not the fix.
    public var flushInterval: TimeInterval
    public var flushSize: Int
    /// Same caveat as `flushInterval` — clamped here, bypassable via direct mutation,
    /// actually enforced at `ConfigSync`'s `Task.sleep` site via
    /// `TimeInterval.sanitizedForSleep()` (finding MF-1).
    public var configRefreshInterval: TimeInterval
    /// The age past which a successful fetch was expected to have replaced the cached config.
    /// An older cache is still applied and reported stale in `status().configFreshness`; it only
    /// reports, it deletes nothing. Default 24 hours. `.infinity` means never stale by age. Zero,
    /// negative and NaN use the default; it is lowered to `configOfflineMaxAge` when larger.
    /// Validated again where it is used, since this is a `var`.
    public var configStaleAfter: TimeInterval
    /// The oldest cached config applied at launch, measured from when the server last sent or
    /// confirmed it (a 304). Default `.infinity`: no limit. A device that cannot reach the server
    /// keeps the flags and experiment assignments it last fetched, whatever their age, until a
    /// successful fetch replaces them or `reset()` deletes them (logout, so the next user of the
    /// device never sees them). A failed fetch never deletes the cache.
    ///
    /// Set a finite number of seconds to bound how long a device that stops fetching serves old
    /// targeting: checked at launch only, past it the cache is deleted and flags read their
    /// defaults until a fetch lands. `604_800` (7 days) is the behaviour of 0.9.0 to 0.10.1;
    /// `86_400` that of 0.8.0 and earlier. Zero, negative and NaN use the default.
    public var configOfflineMaxAge: TimeInterval
    /// Clamped to a floor of 1 here AND at the actual consumer, `EventQueue.init` — this is a
    /// public `var`, so `var cfg = ...; cfg.maxQueueSize = 0` bypasses this initializer clamp
    /// entirely and reaches `EventQueue` unclamped. `EventQueue.add` evicts the oldest event
    /// once `count >= maxSize`, which traps on an empty array at `maxSize == 0` — and #973's
    /// `start() -> emitSessionStartIfOwed() -> track("$session_start")` enqueues an event
    /// during construction, so `maxQueueSize: 0` aborted the host process from inside
    /// `create()` (2026-09 security follow-up, round 2, finding M2; the mutation bypass is
    /// round 3, finding MF-1).
    public var maxQueueSize: Int
    /// HTTP attempts per request for the SDK requests that retry in-line. Since 0.10.0 it does NOT
    /// affect device registration, which sends one request per attempt under its own policy
    /// (`Docs/Technical/SDK_DEVICE_REGISTRATION_CONTRACT.md` § 3).
    public var retryAttempts: Int
    public var debug: Bool
    public var onEvent: (@Sendable (String, [String: Any]?) -> Void)?

    /// Configuration for performance monitoring.
    public var performance: PerformanceConfig

    /// Configuration for crash reporting.
    public var crashes: CrashConfig

    /// XCTest-only escape hatch for the secret-key guard in `SheepitClient.create`.
    /// Production callers should never set this. Default false.
    /// (Audit E-002, 2026-04-25.)
    public var allowSecretKeyInClient: Bool

    /// The app version sent as `app_version` on events, crash reports, performance
    /// metrics and device registration. Defaults to nil → `CFBundleShortVersionString`
    /// (e.g. "1.4.0"), which is what `sheepit ci release --version` registers for an
    /// Apple build, so most apps leave this unset.
    ///
    /// Set it only when your pipeline registers releases under a different version
    /// string, and then to exactly that string: the API matches a release on platform,
    /// version and build (`CFBundleVersion`) together. Bounded to 63 bytes of UTF-8.
    public var appVersion: String?

    /// Live diagnostics subscriber, wired to the SDK's `DiagnosticBus`
    /// at init. Equivalent to `onDiagnostic` in
    /// `packages/sdk-js/src/types.ts`. Invoked on whichever thread
    /// produced the event — do not assume main.
    public var onDiagnostic: DiagnosticListener?

    /// How many diagnostic events the bounded ring buffer retains for
    /// `getRecentDiagnostics()`. Clamped to 1...10_000.
    public var diagnosticBufferSize: Int

    /// Whether `overrideFlag` / `clearOverride` / `clearOverrides` are
    /// allowed to take effect. `nil` (the default) follows `debug` — the
    /// pre-existing behavior. Set explicitly when a build wants the
    /// developer menu (e.g. an internal/TestFlight build) WITHOUT also
    /// enabling verbose SDK logging, or wants to force overrides off in a
    /// debug build. When disabled, `overrideFlag` / `clearOverride` no-op
    /// and do not persist to disk, and `getOverrides()` reads as empty.
    public var allowFlagOverrides: Bool?

    /// Hosts whose failed requests `recordRequest(method:url:status:durationMs:responseBytes:error:)`
    /// may record as `$http_error`. Empty (the default) records nothing — the feature is opt-in.
    /// Each entry is a bare host name (`api.example.com`), matched exactly and case-insensitively,
    /// or `*.example.com` for every subdomain of `example.com` (not `example.com` itself; a
    /// single-label `*.com` or `*.localhost` is refused — list the exact host). An entry with a
    /// scheme, port or path is ignored, with a `request_telemetry.invalid_host` diagnostic. The SDK's own `apiUrl` is never recorded, even
    /// when listed here — with no path in `apiUrl`, that is its whole host
    /// (`request_telemetry.api_host_excluded`). Read once, when the client is created.
    public var requestTelemetryHosts: [String]

    /// What `init(bundle:)` could not use from Info.plist. Internal: `SheepitClient`'s admission
    /// gate turns an active one into an inert client with this message. See
    /// `SheepitConfig+InfoPlist.swift`.
    var infoPlistIssues: [InfoPlistIssue] = []

    /// Set by `init(bundle:)` when `SheepitAPIURL` is absent and `apiUrl` fell to the hosted
    /// default; a started client logs which host that is. See `activeInfoPlistNotice`.
    var apiURLDefaultedFromInfoPlist = false

    /// `init(apiKey:…)` was called without `apiUrl`, so it fell to the hosted default. Not set by
    /// the Info.plist path, which passes its own value (`apiURLDefaultedFromInfoPlist`).
    var apiURLWasOmitted = false

    /// Non-fatal Info.plist problems a started client logs. See `activeInfoPlistWarnings`.
    var infoPlistWarnings: [String] = []

    public init(
        apiKey: String,
        environment: String = "production",
        apiUrl: String? = nil,
        flushInterval: TimeInterval = 5.0,
        flushSize: Int = 20,
        configRefreshInterval: TimeInterval = 300,
        maxQueueSize: Int = 1000,
        retryAttempts: Int = 3,
        debug: Bool = false,
        onEvent: (@Sendable (String, [String: Any]?) -> Void)? = nil,
        performance: PerformanceConfig = .init(),
        crashes: CrashConfig = .init(),
        allowSecretKeyInClient: Bool = false,
        appVersion: String? = nil,
        onDiagnostic: DiagnosticListener? = nil,
        diagnosticBufferSize: Int = DiagnosticBus.defaultBufferSize,
        allowFlagOverrides: Bool? = nil,
        requestTelemetryHosts: [String] = [],
        configStaleAfter: TimeInterval = 86_400,
        configOfflineMaxAge: TimeInterval = .infinity
    ) {
        self.apiKey = apiKey
        self.environment = environment
        self.apiUrl = apiUrl ?? SheepitConfig.defaultAPIUrl
        self.apiURLWasOmitted = apiUrl == nil
        self.flushInterval = flushInterval.sanitizedForSleep()
        self.flushSize = flushSize
        self.configRefreshInterval = configRefreshInterval.sanitizedForSleep()
        self.maxQueueSize = max(1, maxQueueSize)
        self.retryAttempts = retryAttempts
        self.debug = debug
        self.onEvent = onEvent
        self.performance = performance
        self.crashes = crashes
        self.allowSecretKeyInClient = allowSecretKeyInClient
        self.appVersion = appVersion
        self.onDiagnostic = onDiagnostic
        self.diagnosticBufferSize = diagnosticBufferSize
        self.allowFlagOverrides = allowFlagOverrides
        self.requestTelemetryHosts = requestTelemetryHosts
        let limits = CachedConfigLimits(staleAfter: configStaleAfter, offlineMaxAge: configOfflineMaxAge)
        self.configStaleAfter = limits.staleAfter
        self.configOfflineMaxAge = limits.offlineMaxAge
    }
}

// MARK: - Flag Values

/// A value returned by a feature flag evaluation.
///
/// The `.json` case exists so an object- or array-valued flag survives
/// evaluation intact — before it was added, `FlagValue.from(_:)` fell
/// through to `.bool(false)` and a JSON flag silently read as `false`.
///
/// Note the JS SDK's exported type is
/// `boolean | string | number | Record<string, unknown>`
/// (`packages/sdk-js/src/types.ts:78`) — it declares no array member even
/// though arrays flow through its untyped runtime store. Swift models
/// both containers under `.json`; closing that gap on the JS side is a
/// separate change.
public enum FlagValue: Sendable, Equatable {
    case bool(Bool)
    case string(String)
    case int(Int)
    case double(Double)
    /// An object, array, or JSON `null` flag value. Wraps `AnyCodable`
    /// so the payload stays `Sendable` and round-trips through
    /// `JSONEncoder` / `JSONDecoder`.
    case json(AnyCodable)

    public var boolValue: Bool? {
        if case .bool(let val) = self { return val }
        return nil
    }

    public var stringValue: String? {
        if case .string(let val) = self { return val }
        return nil
    }

    public var intValue: Int? {
        if case .int(let val) = self { return val }
        return nil
    }

    public var doubleValue: Double? {
        if case .double(let val) = self { return val }
        return nil
    }

    /// The wrapped JSON payload for a `.json` flag. `nil` for every
    /// other case.
    public var jsonValue: AnyCodable? {
        if case .json(let val) = self { return val }
        return nil
    }

    /// The wrapped JSON payload as a dictionary, when the flag holds a
    /// JSON object. `nil` for arrays, `null`, and non-`.json` cases.
    public var jsonObject: [String: Any]? {
        guard case .json(let val) = self else { return nil }
        return val.value as? [String: Any]
    }

    /// The wrapped JSON payload as an array, when the flag holds a JSON
    /// array. `nil` for objects, `null`, and non-`.json` cases.
    public var jsonArray: [Any]? {
        guard case .json(let val) = self else { return nil }
        return val.value as? [Any]
    }

    /// Decode a `.json` flag straight into a `Decodable` model.
    /// Returns `nil` for non-`.json` cases and for payloads that do not
    /// match `type`.
    public func decodeJSON<T: Decodable>(_ type: T.Type) -> T? {
        guard case .json(let val) = self else { return nil }
        guard let data = try? JSONEncoder().encode(val) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// The underlying primitive/container, for callers that need the raw
    /// value rather than a case match. Used for `$flag_exposure`'s
    /// `flag_value` property so the emitted shape matches the JS SDK
    /// (`packages/sdk-js/src/client.ts:315` sends the raw value).
    public var anyValue: Any {
        switch self {
        case .bool(let val): return val
        case .string(let val): return val
        case .int(let val): return val
        case .double(let val): return val
        case .json(let val): return val.value
        }
    }

    /// Create a FlagValue from any JSON-decodable value.
    ///
    /// `Bool` is matched before `Int` deliberately: `NSNumber`-boxed
    /// booleans coming out of `JSONSerialization` also cast to `Int`.
    public static func from(_ value: Any) -> FlagValue {
        switch value {
        case let bool as Bool: return .bool(bool)
        case let int as Int: return .int(int)
        case let double as Double: return .double(double)
        case let string as String: return .string(string)
        case let anyCodable as AnyCodable: return .from(anyCodable.value)
        case is NSNull: return .json(AnyCodable(NSNull()))
        case let array as [Any]: return .json(AnyCodable(array))
        case let dict as [String: Any]: return .json(AnyCodable(dict))
        default: return .bool(false)
        }
    }
}

// MARK: - Experiment Result

/// Result of an experiment variant assignment.
///
/// Audit E-008 — `payload` is now `[String: AnyCodable]?` (was
/// `[String: Any]?`) so the struct is provably Sendable under Swift
/// 6 strict concurrency. Access primitive values via
/// `result.payload?["key"]?.value` (or use the typed accessors on
/// AnyCodable).
public struct SheepitExperimentResult: Sendable {
    public let variant: String
    public let payload: [String: AnyCodable]?

    public init(variant: String, payload: [String: AnyCodable]? = nil) {
        self.variant = variant
        self.payload = payload
    }
}

// MARK: - SDK Status

/// Current status of the SDK.
public struct SDKStatus: Sendable {
    public let initialized: Bool
    public let online: Bool
    public let queueDepth: Int
    public let offlineQueueDepth: Int
    public let lastFlushAt: Date?
    public let deviceId: String?
    /// The app's own label: the id last passed to `identify()`, kept on the device. It is NOT what
    /// flags are evaluated for — that is `identity.serverUser`, what the server's device row holds.
    public let userId: String?
    public let flagCount: Int
    public let experimentCount: Int
    public let sdkVersion: String
    /// Non-nil when the SDK refused this client's API key at construction. `initialized`
    /// alone cannot tell you that: a refused client and a `destroy()`ed one both report
    /// `false`. Assert this is nil at launch to catch a misconfigured key.
    public let rejectionReason: String?
    /// What the server this client talks to (its apiUrl, environment and key) knows about this
    /// device. nil for a client whose key was refused (it never talks to a server) or that was
    /// destroyed.
    public let identity: Identity?
    /// The config flags and experiments are evaluated from: whether it came from the server or the
    /// on-device cache, when the server last sent or confirmed it, and its age. nil when none is
    /// applied (nothing cached and no fetch has landed yet, after `reset()`, or for a refused or
    /// destroyed client): flags then read their defaults.
    public let configFreshness: ConfigFreshness?

    /// The server's side of identity, which `userId` cannot show: a user the app identified is not
    /// necessarily bound on the server (a POST still in flight, failed, or rejected).
    public struct Identity: Sendable, Equatable {
        /// The user the server's device row holds, as far as the SDK knows.
        public enum ServerUser: Sendable, Equatable {
            /// The SDK does not know what the row holds: an identify POST is in flight or failed, or
            /// nothing has told it. This is also the lasting state of an anonymous install whose
            /// stored device id the server accepted as is (only a newly minted id is known to hold
            /// no user). Flags then evaluate for whatever the row holds.
            case unknown
            /// The row is known to hold no user (a newly minted device, or after `reset()`): flags
            /// evaluate for the device alone.
            case anonymous
            /// The row holds this user: flags evaluate for them.
            case user(String)
        }

        /// The last identify POST the server refused for good. Cleared by the next one it accepts.
        public struct IdentifyRejection: Sendable, Equatable {
            public let userId: String
            /// The HTTP status of the refusal (a 4xx, or 404 on a just-registered device).
            public let statusCode: Int?

            public init(userId: String, statusCode: Int?) {
                self.userId = userId
                self.statusCode = statusCode
            }
        }

        public let serverUser: ServerUser
        /// Whether THIS apiUrl, environment and key registered the device id the SDK uses now. False
        /// after another scope's `reset()` moved the shared id to a fresh device, until this scope
        /// registers it on its next launch.
        public let deviceRegistered: Bool
        public let lastIdentifyRejection: IdentifyRejection?

        public init(serverUser: ServerUser, deviceRegistered: Bool, lastIdentifyRejection: IdentifyRejection? = nil) {
            self.serverUser = serverUser
            self.deviceRegistered = deviceRegistered
            self.lastIdentifyRejection = lastIdentifyRejection
        }
    }

    /// Explicit because Swift synthesises only an INTERNAL memberwise
    /// initializer for a struct that declares none. Without it a customer
    /// can read `status()` but cannot construct one to fixture or mock in
    /// their own tests. Same reason as `SheepitBreadcrumb`.
    public init(
        initialized: Bool,
        online: Bool,
        queueDepth: Int,
        offlineQueueDepth: Int,
        lastFlushAt: Date?,
        deviceId: String?,
        userId: String?,
        flagCount: Int,
        experimentCount: Int,
        sdkVersion: String,
        rejectionReason: String? = nil,
        identity: Identity? = nil,
        configFreshness: ConfigFreshness? = nil
    ) {
        self.initialized = initialized
        self.online = online
        self.queueDepth = queueDepth
        self.offlineQueueDepth = offlineQueueDepth
        self.lastFlushAt = lastFlushAt
        self.deviceId = deviceId
        self.userId = userId
        self.flagCount = flagCount
        self.experimentCount = experimentCount
        self.sdkVersion = sdkVersion
        self.rejectionReason = rejectionReason
        self.identity = identity
        self.configFreshness = configFreshness
    }
}

// MARK: - Sleep-interval sanitization

extension TimeInterval {
    /// The smallest interval a sleep-driven loop (periodic flush, config refresh) is allowed
    /// to run at. Below this — including `0` or negative — `Task.sleep` doesn't trap, it
    /// spins the owning loop at near-100% CPU (measured ~150% at `flushInterval: 0`/`-1`,
    /// 2026-09 security follow-up round 2, finding M2), which no "did it crash" test catches.
    static let sleepFloor: TimeInterval = 1.0

    /// The largest interval a sleep-driven loop may wait — generous (a day) for any real
    /// flush/refresh cadence, but small enough to stay far inside what `Duration.seconds`
    /// can represent without overflow.
    static let sleepCeiling: TimeInterval = 86_400

    /// Sanitizes a host-supplied interval before it reaches `Task.sleep(for: .seconds(_:))`
    /// or any other `Duration` conversion. `.infinity` — the idiom a caller reaches for to
    /// mean "never auto-flush" — and `.nan` both trap the process converting through
    /// `Duration`'s internal `Int128` representation ("Double value cannot be converted to
    /// _Int128 because it is outside the representable range"), and so does a finite but
    /// astronomical value like `1e19` or `1e30`. Every `Task.sleep` site that takes a public
    /// `SheepitConfig`/`PerformanceConfig` value must call this immediately before use — the
    /// initializer clamp on the config struct is defense in depth only, since the property is
    /// a mutable public `var` (2026-09 security follow-up round 3, finding MF-1).
    func sanitizedForSleep() -> TimeInterval {
        guard isFinite else { return .sleepFloor }
        return min(.sleepCeiling, max(.sleepFloor, self))
    }
}

// MARK: - Constants

enum SDKDefaults {
    /// Stamped on every event (`EnrichedEvent.sdkVersion`) and exposed via
    /// `status().sdkVersion`, so it is the only signal that distinguishes a
    /// pre-migration build from a post-migration one in ingested data.
    /// Must equal the CHANGELOG's top heading and the `swift-v<version>` tag;
    /// `publish-sdk-swift.yml` refuses to release on a mismatch. The package
    /// is deliberately on `0.x` while the API settles, and `2.0.0` is reserved
    /// for the first stable release — see the CHANGELOG's "Version policy".
    static let sdkVersion = "0.11.0"
    /// Stamped on every ingest batch (`context.sdk.name`) so the dashboard can filter /
    /// triage by which SDK sent a given event. Follows the monorepo directory-name
    /// convention (`sdk-js`, `sdk-server`, `sdk-swift`) and is pinned by
    /// `apps/api/src/__tests__/v1/ingest.test.ts`'s "stamps the six device-context
    /// columns" regression test, which asserts this exact string round-trips to
    /// `events_raw.sdk_name`. Bounded to 32 chars by `ingestContextSchema.sdk.name`;
    /// `"sdk-swift"` is 9.
    ///
    /// 🔴 This SDK is FIRST, not matching an existing practice. An earlier version of
    /// this comment claimed the other SDKs "already use" this on the wire; they do not.
    /// `sdk-js` builds `context.device` as `{ id, platform, locale }` and sends no
    /// `context.sdk` at all (it has an `SDK_VERSION` constant that never reaches the
    /// wire), and `sdk-server` sends only `{ platform: "server" }`. So until they catch
    /// up, `sdk_name` / `os_name` / `device_model` / `timezone` / `device_type` /
    /// `build_channel` populate for iOS traffic and stay EMPTY for web and server — a
    /// real breakdown inconsistency a customer will see, not a cosmetic gap. Tracked in
    /// PENDING_WORK.md; do not "reconcile" it by weakening this SDK.
    static let sdkName = "sdk-swift"
    static let apiUrl = SheepitConfig.defaultAPIUrl
    static let environment = "production"
    static let flushInterval: TimeInterval = 5.0
    static let flushSize = 20
    static let configRefreshInterval: TimeInterval = 300
    static let maxQueueSize = 1000
    static let retryAttempts = 3
    static let retryBackoff: [TimeInterval] = [1.0, 5.0, 15.0]
    /// Back-off applied after a 429 that carried no `Retry-After`
    /// header. Matches the JS SDK's `parseInt(... ?? "5")` default.
    static let defaultRetryAfter: TimeInterval = 5.0
    static let sessionTimeoutSeconds: TimeInterval = 30 * 60
    /// `SheepitConfig.configStaleAfter`'s default. 0.8.0 and earlier deleted the cache here.
    static let configStaleAfter: TimeInterval = 24 * 60 * 60
    /// `SheepitConfig.configOfflineMaxAge`'s default: no limit (0.10.2). 0.9.0 to 0.10.1 deleted a
    /// cache older than 7 days at launch, so an app that could not reach the server lost its flags.
    static let configOfflineMaxAge: TimeInterval = .infinity

    /// The largest `/v1/config` body written to UserDefaults, and the largest read back at
    /// launch (512 KiB). The cache is decoded on the launch thread and no longer expires, so an
    /// outsized body would cost every launch for good; a flag/experiment set that fits in one
    /// config response is far below this. Over it, the body is applied in memory only.
    static let configCacheMaxBytes = 512 * 1024
    static let offlineQueueMax = 500
    static let eventNameMaxLength = 200
    /// `screen(_:)`'s name cap: the crash context's `screen_name[256]` C buffer less its NUL
    /// terminator. Also inside the crash endpoint's `screen_name` max(256).
    static let screenNameMaxUTF8Bytes = 255
    /// `ingestContextSchema.app.version` / `.build` — UTF-16 units, as zod counts them.
    static let appVersionMaxLength = 64
    /// `ingestContextSchema.user.id` and `deviceIdentifySchema.user_id`, UTF-16 units.
    static let userIdMaxLength = 256

    /// Back-off after the nth consecutive retryable ingest failure (5xx / network): 5 s,
    /// doubling, capped at 5 minutes. Any 2xx resets the count.
    static func failureBackoff(_ failures: Int) -> TimeInterval {
        let exponent = Double(min(max(failures, 1), 10) - 1)
        return min(300, 5 * pow(2, exponent))
    }
    /// The flat backoff after a terminal registration answer (400 `VALIDATION_ERROR`, 401, 403),
    /// and the longest stored window ever honoured (`RegistrationBackoff`). Long enough that a
    /// revoked key does not hammer the endpoint every launch, short enough that a fixed build or
    /// key is picked up within a day. Other windows: `RegistrationPolicy`.
    static let deviceRegistrationTerminalBackoff: TimeInterval = 24 * 60 * 60
    /// How many COUNTED upload attempts a queued crash report gets before it is dropped — at
    /// most one per launch. Only a 5xx counts (`CrashReporter.spendsAttempt`): offline,
    /// timeouts, 401/402/403/404 and 429 do not. So this bound is for a report the server keeps
    /// failing on — and for a poison report that crashes the app while being read or sent,
    /// which is counted before either.
    static let crashUploadMaxAttempts = 5
    /// How long a queued crash report stays eligible, from the launch that first found it. The
    /// ONLY per-report bound on failures that do not count as attempts (offline, 401/403/404,
    /// 402 daily cap, 429): a capped report is re-sent after the UTC-midnight reset, a device
    /// offline over a long weekend still reports, and a misconfigured proxy has a week to be
    /// fixed. Past a week the crash is stale for release-health purposes.
    static let crashUploadMaxAge: TimeInterval = 7 * 24 * 60 * 60
    /// Most crash reports queued on disk at once (~320 KB each). Enforced when a new crash is
    /// adopted, by dropping the oldest (`dropped_queue_full`); not by the attempt count, since
    /// uncounted failures let reports accumulate.
    static let crashPendingMaxReports = 5
    /// No crash this SDK queues can predate this (2026-01-01 UTC, before 0.7.0 existed). A clock
    /// reading earlier is wrong — typically a boot before NTP settles, reading the epoch — and
    /// age is not judged against it.
    static let crashClockFloor = Date(timeIntervalSince1970: 1_767_225_600)
    /// How far past `now` a first-seen time may be before it is treated as a skewed clock.
    static let crashClockFutureTolerance: TimeInterval = 24 * 60 * 60
    /// How often the crash context's `free_memory_mb` is refreshed (also on every memory warning).
    static let crashMemorySampleInterval: TimeInterval = 30
}

/// Persistence keys. `gt_*` since the LaunchPad → GoaTech rename, matching
/// `STORAGE_KEYS` in `packages/sdk-js/src/defaults.ts`.
///
/// The legacy `lp_*` strings live ONLY in `StorageMigration.swift`, which
/// copies them across on first launch so an existing install does not lose
/// its device id, identity, offline queue, or experiment assignments.
///
/// `lp_debug_overrides` is deliberately NOT renamed — sdk-js keeps that one
/// on the old prefix too (`packages/sdk-js/src/flags.ts:3`), and it holds
/// throwaway QA state that is not worth diverging over.
enum StorageKeys {
    static let deviceId = "gt_device_id"
    static let anonymousId = "gt_anonymous_id"
    static let identity = "gt_identity"
    static let sdkConfig = "gt_config"
    /// When `sdkConfig` was written. A SEPARATE key rather than a field inside
    /// the blob, because the blob is the raw HTTP response bytes — adding a
    /// field would mean re-encoding it and would break every cache written by
    /// an older version. Absent means "written before this key existed", which
    /// `ConfigSync` treats as stale: one cache miss on upgrade, then correct.
    static let sdkConfigCachedAt = "gt_config_cached_at"
    /// The `ServerHeldUser` label the cached `sdkConfig` body was fetched under, as JSON. Absent
    /// or unreadable means unknown: the body's assignments are then applied as `.unknown`.
    static let sdkConfigFetchedUnder = "gt_config_fetched_under"
    /// The device id the cached `sdkConfig` body was answered `resolved` for (contract § 7, C5).
    /// Written only for a resolved 2xx; absent (a header-less body, or a cache written before this
    /// key) means not resolved, so an erased device is not detected from that cache.
    static let sdkConfigResolvedFor = "gt_config_resolved_for"
    /// The `ServerHeldUser` state, as JSON with an explicit `state`. Not cleared by `reset()`:
    /// logout does not change the server's device row. It is what `reset()` reads to decide
    /// whether to switch to a fresh device (`DeviceRotation`).
    static let serverHeldUser = "gt_server_held_user"
    static let offlineQueue = "gt_offline_queue"
    static let sessionId = "gt_session_id"
    static let sessionLastSeen = "gt_session_last_seen"
    /// When the stored session began, as epoch seconds; absent for a session an older SDK stored
    /// (it then ends without a `$session_end`, as there is no duration to report).
    static let sessionStartedAt = "gt_session_started_at"
    /// The last stored session id a `$session_end` was queued for, so a launch that dies before
    /// opening a new session does not announce the same end twice.
    static let sessionEndedId = "gt_session_ended_id"
    /// The app version and build the stored session began under ("" for none), so its `$session_end`
    /// is attributed to that release even if the app was updated since.
    static let sessionAppVersion = "gt_session_app_version"
    static let sessionAppBuild = "gt_session_app_build"
    static let experimentAssignments = "gt_exp_assignments"
    /// Set only after a SUCCESSFUL `POST /v1/devices/register` round trip — not merely
    /// once a device id has been minted locally. See `SheepitClient.start()`'s guard. Holds the
    /// device id it registered, per scope (`StorageScope`): the id is shared, so registered means
    /// "this slot names the current id".
    static let deviceRegistered = "gt_device_registered"
    /// The device ids recent identify POSTs were SENT for (written before the request, so an
    /// unanswered POST counts; format in `BindMarker`). While it holds the current id, `reset()`
    /// treats the device as possibly bound and rotates it (`DeviceRotation`). NOT scoped: it
    /// describes the shared device, so a bind under any key makes `reset()` under every key rotate.
    static let deviceBindAttempted = "gt_device_bind_attempted"
    /// The wire app version (`DeviceProfile.wireAppVersion`, "" for none) the device was last
    /// registered with, per scope, beside `deviceRegistered`. A different installed version
    /// registers again so the row's app/os versions stay current
    /// (`Docs/Technical/SDK_DEVICE_REGISTRATION_CONTRACT.md` § 6). Absent counts as different.
    static let deviceRegisteredAppVersion = "gt_device_registered_app_version"
    /// The ONE registration backoff record, a JSON string with `until`, `failures_total` and `sdk_version`
    /// (`RegistrationBackoff`). Written on every failed registration, cleared by a success.
    /// Deliberately NOT the same key as `deviceRegistered`: "gave up for now" is not "succeeded".
    static let deviceRegistrationBackoff = "gt_device_registration_backoff"
    /// 0.9.x and earlier: the backoff as two keys. Read by nothing; removed whenever the record is
    /// written or cleared.
    static let legacyDeviceRegistrationBackoffUntil = "gt_device_registration_backoff_until"
    static let legacyDeviceRegistrationBackoffSDKVersion = "gt_device_registration_backoff_sdk"
    /// The app version (`CFBundleShortVersionString`) recorded the last time
    /// `SheepitClient.emitAppInstallOrUpdateIfOwed()` ran. Absent on every install that
    /// predates 0.4.0 — its absence is what triggers the backfill-without-emitting path on
    /// decision 7 (`AppLifecycleEventDecider`). Deliberately a SEPARATE key from
    /// `deviceId`: an existing install's `deviceId` is always non-nil by the time this runs
    /// (`persistOnBeginWork()` already wrote it), so this marker — not that one — is the
    /// only way to tell "have we ever run this bookkeeping before" from "does a device id
    /// exist."
    static let installedAppVersion = "gt_installed_app_version"
}
