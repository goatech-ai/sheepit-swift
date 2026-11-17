import Foundation

/// Measures cold start (process launch to first frame) and warm start durations.
/// Every field below is read and written under `lock`: foreground notifications arrive on main, the
/// summary reads on the monitor actor. Sampling (`captureContext`) always runs outside it.
final class StartupTracker: @unchecked Sendable {
    private let onMetric: @Sendable (PerformanceMetric) -> Void
    private let processStartTime: TimeInterval
    private let captureContext: @Sendable () -> PerfBatchContext?
    private let epoch: IdentityEpoch
    private let lock = NSLock()
    private var coldStartRecorded = false
    private var warmStartBegin: TimeInterval?
    private var coldContext: PerfBatchContext?
    private var warmContext: PerfBatchContext?
    /// An identity change (`IdentityEpoch.window`) before the first frame drops a pending warm start
    /// and re-captures the cold context; neither may carry the previous identity.
    private var seenEpoch: UInt64
    private var _coldStartMs: Double?
    private var _warmStartMs: Double?

    var coldStartMs: Double? { lock.lock(); defer { lock.unlock() }; return _coldStartMs }
    var warmStartMs: Double? { lock.lock(); defer { lock.unlock() }; return _warmStartMs }

    init(captureContext: @escaping @Sendable () -> PerfBatchContext? = { nil },
         initialContext: PerfBatchContext? = nil,
         epoch: IdentityEpoch = IdentityEpoch(),
         onMetric: @escaping @Sendable (PerformanceMetric) -> Void) {
        self.captureContext = captureContext
        self.coldContext = initialContext ?? captureContext()
        self.epoch = epoch
        self.seenEpoch = epoch.window
        self.onMetric = onMetric
        self.processStartTime = ProcessInfo.processInfo.systemUptime
    }

    /// Call when the first frame is rendered after launch or foregrounding.
    func markFirstFrame() {
        let now = ProcessInfo.processInfo.systemUptime
        // Epoch first, then the sample; a sample a reset overtook is not used.
        let sampledWindow = epoch.window
        let sampled = captureContext()
        let live = epoch.window == sampledWindow ? sampled : nil
        lock.lock()
        let epochMoved = epoch.window != seenEpoch
        if epochMoved {
            seenEpoch = epoch.window
            warmStartBegin = nil
            warmContext = nil
            if !coldStartRecorded { coldContext = live }
        }

        if let warmStart = warmStartBegin {
            let duration = (now - warmStart) * 1000
            _warmStartMs = duration
            warmStartBegin = nil
            // A warm start spans a foreground transition; if the user or device changed inside it the
            // start context's receipt belongs to someone else.
            var context = warmContext
            if let held = context, let live, !held.sameIdentity(as: live) {
                context = live.deviceId != nil ? live.withoutReceipt() : held.anonymized()
            }
            lock.unlock()
            onMetric(PerformanceMetric(
                metricType: "startup",
                metricName: "warm_start",
                valueMs: duration,
                statusCode: nil,
                isError: false,
                timestamp: ISO8601DateFormatter().string(from: Date()),
                context: context
            ))
            return
        }

        guard !coldStartRecorded else { lock.unlock(); return }
        coldStartRecorded = true
        let duration = (now - processStartTime) * 1000
        _coldStartMs = duration
        let context = coldContext
        lock.unlock()
        onMetric(PerformanceMetric(
            metricType: "startup",
            metricName: "cold_start",
            valueMs: duration,
            statusCode: nil,
            isError: false,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            context: context
        ))
    }

    /// Call when the app enters the foreground (warm start begins).
    func markWarmStart() {
        let started = ProcessInfo.processInfo.systemUptime
        let sampledWindow = epoch.window
        let sampled = captureContext()
        // A sample a reset overtook names the old identity: keep only the measurement.
        let context = epoch.window == sampledWindow ? sampled : sampled?.anonymized()
        lock.lock()
        if epoch.window != seenEpoch {
            seenEpoch = epoch.window
            if !coldStartRecorded { coldContext = context }
        }
        warmStartBegin = started
        warmContext = context
        lock.unlock()
    }
}
