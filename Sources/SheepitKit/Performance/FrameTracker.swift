import Foundation
#if canImport(UIKit)
import UIKit
import QuartzCore
#endif

/// Tracks frame rendering performance using CADisplayLink to detect slow and frozen frames.
final class FrameTracker: @unchecked Sendable {
    private let onMetric: @Sendable (PerformanceMetric) -> Void
    private let slowFrameThresholdMs: Double
    private let frozenFrameThresholdMs: Double

    #if canImport(UIKit)
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    #endif

    private(set) var slowFrameCount = 0
    private(set) var frozenFrameCount = 0
    private(set) var totalFrameCount = 0

    init(
        slowFrameThresholdMs: Double,
        frozenFrameThresholdMs: Double,
        onMetric: @escaping @Sendable (PerformanceMetric) -> Void
    ) {
        self.slowFrameThresholdMs = slowFrameThresholdMs
        self.frozenFrameThresholdMs = frozenFrameThresholdMs
        self.onMetric = onMetric
    }

    /// Start frame tracking. Must be called on the main thread.
    func start() {
        #if canImport(UIKit)
        guard displayLink == nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(handleFrame(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
        #endif
    }

    /// Stop frame tracking.
    func stop() {
        #if canImport(UIKit)
        displayLink?.invalidate()
        displayLink = nil
        #endif
    }

    /// Report a summary metric of current frame stats.
    func reportSummary() {
        onMetric(PerformanceMetric(
            metricType: "frames",
            metricName: "frame_summary",
            valueMs: Double(totalFrameCount),
            statusCode: nil,
            isError: slowFrameCount > 0 || frozenFrameCount > 0,
            timestamp: ISO8601DateFormatter().string(from: Date())
        ))
    }

    #if canImport(UIKit)
    @objc private func handleFrame(_ link: CADisplayLink) {
        let currentTimestamp = link.timestamp
        guard lastTimestamp > 0 else {
            lastTimestamp = currentTimestamp
            return
        }

        let frameDurationMs = (currentTimestamp - lastTimestamp) * 1000
        lastTimestamp = currentTimestamp
        totalFrameCount += 1

        if frameDurationMs >= frozenFrameThresholdMs {
            frozenFrameCount += 1
            onMetric(PerformanceMetric(
                metricType: "frames",
                metricName: "frozen_frame",
                valueMs: frameDurationMs,
                statusCode: nil,
                isError: true,
                timestamp: ISO8601DateFormatter().string(from: Date())
            ))
        } else if frameDurationMs >= slowFrameThresholdMs {
            slowFrameCount += 1
            onMetric(PerformanceMetric(
                metricType: "frames",
                metricName: "slow_frame",
                valueMs: frameDurationMs,
                statusCode: nil,
                isError: false,
                timestamp: ISO8601DateFormatter().string(from: Date())
            ))
        }
    }
    #endif
}
