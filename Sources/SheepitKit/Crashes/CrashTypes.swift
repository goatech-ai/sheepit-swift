import Foundation

// MARK: - Public Types

/// Configuration for the crash reporting module.
public struct CrashConfig: Sendable {
    /// Whether crash reporting is enabled.
    public var enabled: Bool

    /// Maximum number of breadcrumbs retained before a crash.
    public var breadcrumbCapacity: Int

    /// Number of consecutive crashes within `crashLoopWindowSeconds` before
    /// the crash reporter disables itself to prevent crash loops.
    public var crashLoopThreshold: Int

    /// Time window (seconds) for crash loop detection.
    public var crashLoopWindowSeconds: Int

    public init(
        enabled: Bool = true,
        breadcrumbCapacity: Int = 32,
        crashLoopThreshold: Int = 3,
        crashLoopWindowSeconds: Int = 60
    ) {
        self.enabled = enabled
        self.breadcrumbCapacity = breadcrumbCapacity
        self.crashLoopThreshold = crashLoopThreshold
        self.crashLoopWindowSeconds = crashLoopWindowSeconds
    }
}

/// A breadcrumb recorded before a crash, providing context for what
/// the user was doing leading up to the crash.
public struct SheepitBreadcrumb: Sendable {
    public let timestamp: Date
    public let category: String
    public let message: String

    /// Explicit because Swift only synthesises an INTERNAL memberwise
    /// initializer when a struct declares none — public stored properties
    /// do not change that. Without this, the type is readable but not
    /// constructible outside the module, which made the `LPBreadcrumb`
    /// deprecation shim untrue for the external consumers it exists to
    /// serve. `SheepitSpan` already declared one.
    public init(timestamp: Date, category: String, message: String) {
        self.timestamp = timestamp
        self.category = category
        self.message = message
    }
}

// MARK: - Internal Types

/// The structured crash report payload sent to `POST /v1/crashes/report`.
struct CrashReportPayload: Encodable, Sendable {
    let platform: String
    let appVersion: String
    let buildNumber: String?
    let osVersion: String?
    let deviceModel: String?
    let exceptionType: String
    let exceptionMessage: String?
    let stackTrace: CrashStackTrace
    let threadInfo: [CrashThreadInfo]?
    let isForeground: Bool
    let freeMemoryMb: Int?
    let freeDiskMb: Int?
    let batteryLevel: Int?
    let screenName: String?
    let breadcrumbs: [CrashBreadcrumbPayload]?
    let activeFlags: [String: AnyCodable]?
    let activeExperiments: [String: AnyCodable]?
    let customData: [String: AnyCodable]?
    let userId: String?
    let sessionId: String?
    let deviceId: String?
    let networkType: String?
    /// Per-image Mach-O UUIDs captured at crash time. Required for
    /// server-side symbolication; stays optional so older receivers
    /// still accept the payload during phased rollout.
    let binaryImages: [CrashBinaryImage]?
    let timestamp: String

    enum CodingKeys: String, CodingKey {
        case platform
        case appVersion = "app_version"
        case buildNumber = "build_number"
        case osVersion = "os_version"
        case deviceModel = "device_model"
        case exceptionType = "exception_type"
        case exceptionMessage = "exception_message"
        case stackTrace = "stack_trace"
        case threadInfo = "thread_info"
        case isForeground = "is_foreground"
        case freeMemoryMb = "free_memory_mb"
        case freeDiskMb = "free_disk_mb"
        case batteryLevel = "battery_level"
        case screenName = "screen_name"
        case breadcrumbs
        case activeFlags = "active_flags"
        case activeExperiments = "active_experiments"
        case customData = "custom_data"
        case userId = "user_id"
        case sessionId = "session_id"
        case deviceId = "device_id"
        case networkType = "network_type"
        case binaryImages = "binary_images"
        case timestamp
    }
}

/// A single loaded Mach-O image captured from the crash context. The UUID
/// is the LC_UUID load-command value — the same key used to look up the
/// matching dSYM on the server for symbolication.
struct CrashBinaryImage: Encodable, Sendable {
    let uuid: String
    let name: String
    /// Hex string ("0x00000001029c8000") so large addresses survive JSON.
    let loadAddress: String
    let size: UInt64

    enum CodingKeys: String, CodingKey {
        case uuid, name, size
        case loadAddress = "load_address"
    }
}

struct CrashStackTrace: Encodable, Sendable {
    let frames: [CrashStackFrame]
    let exception: CrashException
}

struct CrashStackFrame: Encodable, Sendable {
    let index: Int
    let function: String?
    let imageName: String?
    let rawAddress: String?
    let symbolAddress: String?
    let imageAddress: String?
    let isAppFrame: Bool

    enum CodingKeys: String, CodingKey {
        case index, function
        case imageName = "image_name"
        case rawAddress = "raw_address"
        case symbolAddress = "symbol_address"
        case imageAddress = "image_address"
        case isAppFrame = "is_app_frame"
    }
}

struct CrashException: Encodable, Sendable {
    let type: String
    let message: String?
    let mechanism: String?
}

struct CrashThreadInfo: Encodable, Sendable {
    let threadId: UInt64
    let name: String?
    let isCrashed: Bool
    let frames: [CrashStackFrame]

    enum CodingKeys: String, CodingKey {
        case threadId = "thread_id"
        case name
        case isCrashed = "is_crashed"
        case frames
    }
}

struct CrashBreadcrumbPayload: Encodable, Sendable {
    let timestamp: String
    let category: String
    let message: String
}
