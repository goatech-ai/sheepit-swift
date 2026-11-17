import Foundation

// MARK: - Public Types

/// Configuration for the crash reporting module.
public struct CrashConfig: Sendable {
    /// Whether crash reporting is enabled.
    public var enabled: Bool

    /// Maximum number of breadcrumbs a crash report carries: the newest this many. The on-disk
    /// ring holds 32, so a larger value acts as 32; 0 sends none. Applied when the report is
    /// read on the next launch, so that launch's configuration decides.
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

/// A single loaded Mach-O image captured from the crash context. The UUID
/// is the LC_UUID load-command value — the same key used to look up the
/// matching dSYM on the server for symbolication.
struct CrashBinaryImage: Encodable, Sendable {
    let uuid: String
    let name: String
    /// Hex string ("0x00000001029c8000") so large addresses survive JSON.
    let loadAddress: String
    /// The image's `__TEXT` size since 0.10.1 (its largest segment before).
    let size: UInt64
    // From the crash supplement (0.10.1+); absent for a report captured without one.
    var cpuType: Int32? = nil
    /// Raw `cpusubtype`, capability bits included (arm64e carries its pointer-auth ABI bit).
    var cpuSubtype: UInt32? = nil
    /// Signed hex ("0x4000", "-0x4000"): runtime header address minus the link-time `__TEXT` vmaddr.
    var vmaddrSlide: String? = nil
    /// Whether the image ships inside the app bundle — its full path, not its name.
    var isAppImage: Bool? = nil

    enum CodingKeys: String, CodingKey {
        case uuid, name, size
        case loadAddress = "load_address"
        case cpuType = "cpu_type"
        case cpuSubtype = "cpu_subtype"
        case vmaddrSlide = "vmaddr_slide"
        case isAppImage = "is_app_image"
    }
}

/// The crashed thread's registers at the trap site, pointer-auth stripped, as hex strings.
struct CrashRegisters: Encodable, Sendable, Equatable {
    let pc: String
    let lr: String?
    let fp: String
    let sp: String
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

    /// This thread with only its first `count` frames.
    func keepingFrames(_ count: Int) -> CrashThreadInfo {
        CrashThreadInfo(threadId: threadId, name: name, isCrashed: isCrashed, frames: Array(frames.prefix(count)))
    }

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
