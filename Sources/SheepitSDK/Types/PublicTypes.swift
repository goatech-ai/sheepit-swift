import Foundation

// MARK: - Configuration

/// Configuration for the Sheepit SDK.
public struct SheepitConfig: Sendable {
    /// Default API URL. Update this when migrating to a custom domain.
    public static let defaultAPIUrl = "https://api.goatech.ai"

    public let apiKey: String
    public var environment: String
    public var apiUrl: String
    public var flushInterval: TimeInterval
    public var flushSize: Int
    public var configRefreshInterval: TimeInterval
    public var maxQueueSize: Int
    public var retryAttempts: Int
    public var debug: Bool
    public var onEvent: (@Sendable (String, [String: Any]?) -> Void)?

    /// Configuration for performance monitoring.
    public var performance: PerformanceConfig

    /// Configuration for crash reporting.
    public var crashes: CrashConfig

    /// XCTest-only escape hatch for the secret-key guard in `Sheepit.create`.
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
        self.flushInterval = flushInterval
        self.flushSize = flushSize
        self.configRefreshInterval = configRefreshInterval
        self.maxQueueSize = maxQueueSize
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
        sdkVersion: String
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
    }
}

// MARK: - Constants

enum SDKDefaults {
    /// Stamped on every event (`EnrichedEvent.sdkVersion`) and exposed via
    /// `status().sdkVersion`, so it is the only signal that distinguishes a
    /// pre-migration build from a post-migration one in ingested data.
    /// Bumped for the `lp_*` → `gt_*` storage rename. `1.0.0` is reserved
    /// for the first published tag.
    static let sdkVersion = "1.0.0"
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
}
