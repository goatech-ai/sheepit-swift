import Foundation

// MARK: - Public Types

/// Configuration for the performance monitoring module.
public struct PerformanceConfig: Sendable {
    /// Whether performance monitoring is enabled.
    public var enabled: Bool

    /// Whether cold/warm start tracking is enabled.
    public var startupTrackingEnabled: Bool

    /// Whether frame rate tracking is enabled (iOS only).
    public var frameTrackingEnabled: Bool

    /// Whether network request metrics are captured.
    public var networkTrackingEnabled: Bool

    /// Whether memory usage tracking is enabled.
    public var memoryTrackingEnabled: Bool

    /// Threshold in milliseconds for detecting Application Not Responding.
    public var anrThresholdMs: Double

    /// Threshold in milliseconds for a slow frame (default 16.67ms = 60fps).
    public var slowFrameThresholdMs: Double

    /// Threshold in milliseconds for a frozen frame.
    public var frozenFrameThresholdMs: Double

    /// Interval in seconds between automatic flushes of performance data.
    public var flushInterval: TimeInterval

    /// Maximum number of metrics to batch before flushing.
    public var maxBatchSize: Int

    public init(
        enabled: Bool = false,
        startupTrackingEnabled: Bool = true,
        frameTrackingEnabled: Bool = true,
        networkTrackingEnabled: Bool = true,
        memoryTrackingEnabled: Bool = true,
        anrThresholdMs: Double = 5000,
        slowFrameThresholdMs: Double = 16.67,
        frozenFrameThresholdMs: Double = 700.0,
        flushInterval: TimeInterval = 30.0,
        maxBatchSize: Int = 50
    ) {
        self.enabled = enabled
        self.startupTrackingEnabled = startupTrackingEnabled
        self.frameTrackingEnabled = frameTrackingEnabled
        self.networkTrackingEnabled = networkTrackingEnabled
        self.memoryTrackingEnabled = memoryTrackingEnabled
        self.anrThresholdMs = anrThresholdMs
        self.slowFrameThresholdMs = slowFrameThresholdMs
        self.frozenFrameThresholdMs = frozenFrameThresholdMs
        self.flushInterval = flushInterval
        self.maxBatchSize = maxBatchSize
    }
}

/// A performance span representing a timed operation.
public struct SheepitSpan: Sendable {
    /// Name identifying the span (e.g. "checkout_flow", "image_load").
    public let name: String

    /// When the span started.
    public let startTime: Date

    /// When the span ended, or nil if still in progress.
    public let endTime: Date?

    /// Arbitrary key-value attributes attached to the span.
    public let attributes: [String: String]

    public init(
        name: String,
        startTime: Date = Date(),
        endTime: Date? = nil,
        attributes: [String: String] = [:]
    ) {
        self.name = name
        self.startTime = startTime
        self.endTime = endTime
        self.attributes = attributes
    }
}

/// Summary of collected performance metrics for developer inspection.
public struct SheepitPerformanceSummary: Sendable {
    /// Cold start duration in milliseconds, or nil if not measured.
    public let coldStartMs: Double?

    /// Warm start duration in milliseconds, or nil if not measured.
    public let warmStartMs: Double?

    /// Number of slow frames detected.
    public let slowFrameCount: Int

    /// Number of frozen frames detected.
    public let frozenFrameCount: Int

    /// Total number of frames observed.
    public let totalFrameCount: Int

    /// Peak memory usage in megabytes.
    public let memoryPeakMb: Double

    /// Number of ANR events detected.
    public let anrCount: Int

    /// Explicit because Swift synthesises only an INTERNAL memberwise
    /// initializer for a struct that declares none. Without it a customer
    /// can read `performanceSummary()` but cannot construct one to fixture
    /// or mock in their own tests. Same reason as `SheepitBreadcrumb`.
    public init(
        coldStartMs: Double?,
        warmStartMs: Double?,
        slowFrameCount: Int,
        frozenFrameCount: Int,
        totalFrameCount: Int,
        memoryPeakMb: Double,
        anrCount: Int
    ) {
        self.coldStartMs = coldStartMs
        self.warmStartMs = warmStartMs
        self.slowFrameCount = slowFrameCount
        self.frozenFrameCount = frozenFrameCount
        self.totalFrameCount = totalFrameCount
        self.memoryPeakMb = memoryPeakMb
        self.anrCount = anrCount
    }
}

// MARK: - Internal Types

/// A single performance metric for API transport.
struct PerformanceMetric: Encodable, Sendable {
    let metricType: String
    let metricName: String
    let valueMs: Double
    let statusCode: Int?
    let isError: Bool
    let timestamp: String

    enum CodingKeys: String, CodingKey {
        case timestamp
        case metricType = "metric_type"
        case metricName = "metric_name"
        case valueMs = "value_ms"
        case statusCode = "status_code"
        case isError = "is_error"
    }
}

/// Batch request payload for POST /v1/performance.
struct PerfBatchRequest: Encodable, Sendable {
    let batch: [PerformanceMetric]
    let context: PerfBatchContext
    let sentAt: String

    enum CodingKeys: String, CodingKey {
        case batch, context
        case sentAt = "sent_at"
    }
}

/// Context included with each performance batch.
struct PerfBatchContext: Encodable, Sendable {
    let platform: String
    let appVersion: String?
    let buildNumber: String?
    let osVersion: String
    let deviceModel: String
    let userId: String?
    let sessionId: String
    let deviceId: String
    let country: String?
    let networkType: String?
    let activeFlags: [String: AnyCodable]?
    let activeExperiments: [String: AnyCodable]?

    enum CodingKeys: String, CodingKey {
        case platform, country
        case appVersion = "app_version"
        case buildNumber = "build_number"
        case osVersion = "os_version"
        case deviceModel = "device_model"
        case userId = "user_id"
        case sessionId = "session_id"
        case deviceId = "device_id"
        case networkType = "network_type"
        case activeFlags = "active_flags"
        case activeExperiments = "active_experiments"
    }
}
