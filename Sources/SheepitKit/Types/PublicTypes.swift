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
    /// Clamped to a floor of 1 here AND at the actual consumer, `EventQueue.init` — this is a
    /// public `var`, so `var cfg = ...; cfg.maxQueueSize = 0` bypasses this initializer clamp
    /// entirely and reaches `EventQueue` unclamped. `EventQueue.add` evicts the oldest event
    /// once `count >= maxSize`, which traps on an empty array at `maxSize == 0` — and #973's
    /// `start() -> emitSessionStartIfOwed() -> track("$session_start")` enqueues an event
    /// during construction, so `maxQueueSize: 0` aborted the host process from inside
    /// `create()` (2026-09 security follow-up, round 2, finding M2; the mutation bypass is
    /// round 3, finding MF-1).
    public var maxQueueSize: Int
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

    /// Audit L-005 / X2-001: explicit version string baked in by the host
    /// app at build time. Stamped on every event as `app_version` so the
    /// ingest path's release-resolver can attribute events to a Release
    /// row. Defaults to nil → SDK falls back to
    /// Bundle.main.CFBundleShortVersionString, which is the human-facing
    /// marketing version (e.g. "1.0.0") and rarely matches a Release row's
    /// commit-SHA-derived version. For TestFlight + App Store builds the
    /// host should pass the GIT commit SHA (or build pipeline tag) here so
    /// iOS events flow into the same release-intelligence loop as web.
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

    public init(
        apiKey: String,
        environment: String = "production",
        apiUrl: String = SheepitConfig.defaultAPIUrl,
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
        allowFlagOverrides: Bool? = nil
    ) {
        self.apiKey = apiKey
        self.environment = environment
        self.apiUrl = apiUrl
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
    public let userId: String?
    public let flagCount: Int
    public let experimentCount: Int
    public let sdkVersion: String
    /// Non-nil when the SDK refused this client's API key at construction. `initialized`
    /// alone cannot tell you that: a refused client and a `destroy()`ed one both report
    /// `false`. Assert this is nil at launch to catch a misconfigured key.
    public let rejectionReason: String?

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
        rejectionReason: String? = nil
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
    static let sdkVersion = "0.4.0"
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
    static let configMaxAge: TimeInterval = 24 * 60 * 60
    static let offlineQueueMax = 500
    static let eventNameMaxLength = 200
    /// How long `start()` withholds a RETRY after a terminal (401/403/422) registration
    /// failure, before treating the device as eligible to try again. Matches
    /// `configMaxAge`'s once-a-day cadence — long enough that a permanently revoked key
    /// does not hammer the endpoint on every cold start, short enough that a fix shipped
    /// in a later build (or capacity freed server-side) is picked up within a day rather
    /// than never.
    static let deviceRegistrationTerminalBackoff: TimeInterval = 24 * 60 * 60
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
    static let offlineQueue = "gt_offline_queue"
    static let sessionId = "gt_session_id"
    static let sessionLastSeen = "gt_session_last_seen"
    static let experimentAssignments = "gt_exp_assignments"
    /// Set only after a SUCCESSFUL `POST /v1/devices/register` round trip — not merely
    /// once a device id has been minted locally. See `SheepitClient.start()`'s guard.
    static let deviceRegistered = "gt_device_registered"
    /// Epoch-seconds string. Set only after a TERMINAL registration failure (401/403/422 —
    /// see `RegistrationOutcome`), never after success or a transient failure. Deliberately
    /// NOT the same key as `deviceRegistered`: a revoked key that gets fixed in a later
    /// build must still be retried eventually, just not on every single cold start while
    /// it's broken. See `SheepitClient.start()`'s guard.
    static let deviceRegistrationBackoffUntil = "gt_device_registration_backoff_until"
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
