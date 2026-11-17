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
    private let captureContext: @Sendable () -> PerfBatchContext?
    /// The summary is cumulative over one identity window and carries that window's start context.
    /// Poll aliases never split it. `reset()`, a user switch and a device change do (`IdentityEpoch.window`),
    /// and a report that finds the live user or device differing from this context ships with no token
    /// instead (a receipt is bound to the identity it was issued for). Either way the counters restart.
    /// All of it is under `lock`; frames arrive on main, reports on the actor.
    private var summaryContext: PerfBatchContext?
    private var summaryNeedsCapture = false
    private var windowEpoch: UInt64
    private let epoch: IdentityEpoch
    private let lock = NSLock()

    #if canImport(UIKit)
    private var displayLink: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0
    #endif

    private var slow = 0, frozen = 0, total = 0
    var slowFrameCount: Int { rolledOver { slow } }
    var frozenFrameCount: Int { rolledOver { frozen } }
    var totalFrameCount: Int { rolledOver { total } }

    init(
        slowFrameThresholdMs: Double,
        frozenFrameThresholdMs: Double,
        captureContext: @escaping @Sendable () -> PerfBatchContext? = { nil },
        initialContext: PerfBatchContext? = nil,
        epoch: IdentityEpoch = IdentityEpoch(),
        onMetric: @escaping @Sendable (PerformanceMetric) -> Void
    ) {
        self.captureContext = captureContext
        self.summaryContext = initialContext ?? captureContext()
        self.epoch = epoch
        self.windowEpoch = epoch.window
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
        // Sampled outside `lock`: it takes other locks. Epoch FIRST, then the sample: a sample that a
        // reset overtook may still name the old identity, so it is not used (the next report catches up).
        let sampledWindow = epoch.window
        let sampled = captureContext()
        let live = epoch.window == sampledWindow ? sampled : nil
        lock.lock()
        rollLocked()
        let counts = (total, slow, frozen)
        var context = summaryContext
        if summaryNeedsCapture {
            // A window that restarted and has seen no frame has nothing to say, least of all under a new identity.
            if total == 0 { lock.unlock(); return }
            summaryContext = live
            summaryNeedsCapture = false
            context = live
        } else if let held = summaryContext, let live, !held.sameIdentity(as: live) {
            // The counts belong to the window `held` opened, which is not the live identity's: they ship
            // with no user, device or receipt, and the window restarts for whoever is live.
            context = held.anonymized()
            summaryContext = live.deviceId == nil ? nil : live
            summaryNeedsCapture = live.deviceId == nil
            slow = 0; frozen = 0; total = 0
        }
        lock.unlock()
        onMetric(PerformanceMetric(
            metricType: "frames",
            metricName: "frame_summary",
            valueMs: Double(counts.0),
            statusCode: nil,
            isError: counts.1 > 0 || counts.2 > 0,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            context: context
        ))
    }

    private func rollLocked() {
        let current = epoch.window
        guard current != windowEpoch else { return }
        windowEpoch = current
        slow = 0; frozen = 0; total = 0
        summaryContext = nil
        summaryNeedsCapture = true
    }

    /// Runs `read` under the lock after discarding a window the identity epoch has outlived.
    private func rolledOver<T>(_ read: () -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        rollLocked()
        return read()
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
        recordFrame(durationMs: frameDurationMs)
    }
    #endif

    /// Same frame accounting as CADisplayLink; emitted metrics capture their completion context.
    func recordFrame(durationMs: Double) {
        let kind: Int = rolledOver {
            total += 1
            if durationMs >= frozenFrameThresholdMs { frozen += 1; return 2 }
            if durationMs >= slowFrameThresholdMs { slow += 1; return 1 }
            return 0
        }

        if kind == 2 {
            onMetric(PerformanceMetric(
                metricType: "frames",
                metricName: "frozen_frame",
                valueMs: durationMs,
                statusCode: nil,
                isError: true,
                timestamp: ISO8601DateFormatter().string(from: Date()),
                context: captureContext()
            ))
        } else if kind == 1 {
            onMetric(PerformanceMetric(
                metricType: "frames",
                metricName: "slow_frame",
                valueMs: durationMs,
                statusCode: nil,
                isError: false,
                timestamp: ISO8601DateFormatter().string(from: Date()),
                context: captureContext()
            ))
        }
    }
}
