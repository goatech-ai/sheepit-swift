import Foundation

/// The structured crash report payload sent to `POST /v1/crashes/report`
/// (`crashReportIngestSchema` in packages/shared/src/schemas/platform.ts).
///
/// Encoded by hand rather than synthesized so that `thread_info` is capped on the wire by ONE
/// rule, whatever built the payload: see `wireThreads(_:)`. Every field added in 0.10.1 is
/// optional and the schema is a non-strict `z.object`, so an API that does not know a field
/// strips it rather than answering 400.
struct CrashReportPayload: Encodable, Sendable {
    let platform: String
    let appVersion: String
    let buildNumber: String?
    let osVersion: String?
    let deviceModel: String?
    let exceptionType: String
    let exceptionMessage: String?
    let stackTrace: CrashStackTrace
    /// Every captured thread (up to `SHEEPIT_MAX_THREADS`); the wire carries `wireThreads`.
    var threadInfo: [CrashThreadInfo]?
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
    /// Stable per-report id (`PendingCrashStore.Entry.id`), identical on every retry, so the
    /// server can recognise a re-send.
    var reportId: String? = nil
    var assignmentToken: String? = nil
    var assignmentStatus: String? = nil

    /// Local upload diagnostic only; never encoded as a new wire field.
    var captureIdentityOutcome: String? = nil

    // From the crash supplement (0.10.1+); nil for a report captured without one.
    /// The SheepitKit version that CAPTURED the crash — not the one uploading it a launch later.
    var captureSdkVersion: String? = nil
    var osBuild: String? = nil
    var arch: String? = nil
    var crashedThreadRegisters: CrashRegisters? = nil
    /// Candidate frames of the crashed thread that matched no loaded image and were left out.
    var framesDropped: Int? = nil
    /// The Mach exception the signal stands for (`EXC_BAD_ACCESS` for SIGSEGV/SIGBUS, …).
    /// Display only: `exception_type` stays the signal name, which groups and filters crashes.
    var machExceptionType: String? = nil
    /// The image table is incomplete — more than 512 images were loaded, or one could not be read
    /// — so frames were kept without the in-image check and an address may be a garbage word.
    /// Sent only when true.
    var imagesTruncated: Bool? = nil

    /// `crashReportIngestSchema.thread_info` is `.max(50)`, and a 400 is permanent to
    /// `CrashReporter`: a report with more threads was dropped for good. The handler captures up
    /// to 128.
    static let maxWireThreads = 50

    /// At most `maxWireThreads`, in capture order, always including the crashed thread: when it
    /// falls past the cap it takes the last slot.
    static func wireThreads(_ threads: [CrashThreadInfo]?) -> [CrashThreadInfo]? {
        guard let threads, threads.count > maxWireThreads else { return threads }
        var kept = Array(threads.prefix(maxWireThreads))
        if !kept.contains(where: \.isCrashed), let crashed = threads.first(where: \.isCrashed) {
            kept[maxWireThreads - 1] = crashed
        }
        return kept
    }

    /// `crash-ingest.ts` caps the body at 524_288 bytes and answers 413, which `CrashReporter`
    /// treats as permanent: a report from an app with many deep thread stacks was lost. Headroom
    /// is left for the encoder's own variance.
    static let maxWireBytes = 448 * 1024

    /// This payload trimmed until its encoded body fits `maxBytes`: first the other threads'
    /// frames (to 32, 8, then none), then the other threads themselves, from the end. The crashed
    /// thread, `stack_trace` and the exception are never touched.
    func fittingBudget(_ maxBytes: Int = maxWireBytes) -> CrashReportPayload {
        func size(_ payload: CrashReportPayload) -> Int {
            (try? JSONEncoder().encode(payload).count) ?? Int.max
        }
        let full = size(self)
        // Int.max is an encode failure, not a size: upload as is and let the server say why.
        guard full > maxBytes, full != Int.max, let threads = Self.wireThreads(threadInfo) else { return self }
        var trimmed = self
        for keep in [32, 8, 0] {
            trimmed.threadInfo = threads.map { $0.isCrashed ? $0 : $0.keepingFrames(keep) }
            if size(trimmed) <= maxBytes { return trimmed }
        }
        var remaining = trimmed.threadInfo ?? []
        while size(trimmed) > maxBytes, let last = remaining.lastIndex(where: { !$0.isCrashed }) {
            remaining.remove(at: last)
            trimmed.threadInfo = remaining
        }
        return trimmed
    }

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
        case reportId = "report_id"
        case assignmentToken = "assignment_token"
        case assignmentStatus = "assignment_status"
        case captureSdkVersion = "sdk_version"  // never a case named sdkVersion: the release lane greps Sources for exactly one SDKDefaults declaration
        case osBuild = "os_build"
        case arch
        case crashedThreadRegisters = "crashed_thread_registers"
        case framesDropped = "frames_dropped"
        case machExceptionType = "mach_exception_type"
        case imagesTruncated = "images_truncated"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(platform, forKey: .platform)
        try c.encode(appVersion, forKey: .appVersion)
        try c.encodeIfPresent(buildNumber, forKey: .buildNumber)
        try c.encodeIfPresent(osVersion, forKey: .osVersion)
        try c.encodeIfPresent(deviceModel, forKey: .deviceModel)
        try c.encode(exceptionType, forKey: .exceptionType)
        try c.encodeIfPresent(exceptionMessage, forKey: .exceptionMessage)
        try c.encode(stackTrace, forKey: .stackTrace)
        try c.encodeIfPresent(Self.wireThreads(threadInfo), forKey: .threadInfo)
        try c.encode(isForeground, forKey: .isForeground)
        try c.encodeIfPresent(freeMemoryMb, forKey: .freeMemoryMb)
        try c.encodeIfPresent(freeDiskMb, forKey: .freeDiskMb)
        try c.encodeIfPresent(batteryLevel, forKey: .batteryLevel)
        try c.encodeIfPresent(screenName, forKey: .screenName)
        try c.encodeIfPresent(breadcrumbs, forKey: .breadcrumbs)
        try c.encodeIfPresent(activeFlags, forKey: .activeFlags)
        try c.encodeIfPresent(customData, forKey: .customData)
        try c.encodeIfPresent(userId, forKey: .userId)
        try c.encodeIfPresent(sessionId, forKey: .sessionId)
        try c.encodeIfPresent(deviceId, forKey: .deviceId)
        try c.encodeIfPresent(networkType, forKey: .networkType)
        try c.encodeIfPresent(binaryImages, forKey: .binaryImages)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encodeIfPresent(reportId, forKey: .reportId)
        try c.encodeIfPresent(assignmentToken, forKey: .assignmentToken)
        try c.encodeIfPresent(assignmentStatus, forKey: .assignmentStatus)
        try c.encodeIfPresent(captureSdkVersion, forKey: .captureSdkVersion)
        try c.encodeIfPresent(osBuild, forKey: .osBuild)
        try c.encodeIfPresent(arch, forKey: .arch)
        try c.encodeIfPresent(crashedThreadRegisters, forKey: .crashedThreadRegisters)
        try c.encodeIfPresent(framesDropped, forKey: .framesDropped)
        try c.encodeIfPresent(machExceptionType, forKey: .machExceptionType)
        try c.encodeIfPresent(imagesTruncated, forKey: .imagesTruncated)
    }
}
