import Foundation

/// Measures cold start (process launch to first frame) and warm start durations.
final class StartupTracker: @unchecked Sendable {
    private let onMetric: @Sendable (PerformanceMetric) -> Void
    private let processStartTime: TimeInterval
    private var coldStartRecorded = false
    private var warmStartBegin: TimeInterval?

    private(set) var coldStartMs: Double?
    private(set) var warmStartMs: Double?

    init(onMetric: @escaping @Sendable (PerformanceMetric) -> Void) {
        self.onMetric = onMetric
        self.processStartTime = ProcessInfo.processInfo.systemUptime
    }

    /// Call when the first frame is rendered after launch or foregrounding.
    func markFirstFrame() {
        let now = ProcessInfo.processInfo.systemUptime

        if let warmStart = warmStartBegin {
            let duration = (now - warmStart) * 1000
            warmStartMs = duration
            warmStartBegin = nil
            onMetric(PerformanceMetric(
                metricType: "startup",
                metricName: "warm_start",
                valueMs: duration,
                statusCode: nil,
                isError: false,
                timestamp: ISO8601DateFormatter().string(from: Date())
            ))
            return
        }

        guard !coldStartRecorded else { return }
        coldStartRecorded = true
        let duration = (now - processStartTime) * 1000
        coldStartMs = duration
        onMetric(PerformanceMetric(
            metricType: "startup",
            metricName: "cold_start",
            valueMs: duration,
            statusCode: nil,
            isError: false,
            timestamp: ISO8601DateFormatter().string(from: Date())
        ))
    }

    /// Call when the app enters the foreground (warm start begins).
    func markWarmStart() {
        warmStartBegin = ProcessInfo.processInfo.systemUptime
    }
}
