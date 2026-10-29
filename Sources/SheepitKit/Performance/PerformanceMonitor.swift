import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Orchestrates all performance trackers, buffers metrics, and flushes to the API.
/// Mirrors the Transport actor pattern for batched delivery.
actor PerformanceMonitor {
    private let http: HTTPClient
    private let context: ContextManager
    private let config: PerformanceConfig
    private let log: Logger
    var onError: (@Sendable (Error, String) -> Void)?

    private var startupTracker: StartupTracker?
    private var frameTracker: FrameTracker?
    private var anrWatchdog: ANRWatchdog?
    private var memoryTracker: MemoryTracker?

    /// `SheepitConfig.appVersion`; see `DeviceProfile.wireAppVersion(override:)`.
    private let appVersionOverride: String?
    private var buffer: [PerformanceMetric] = []
    private var spans: [String: SheepitSpan] = [:]
    private var flushTask: Task<Void, Never>?
    private var isRunning = false
    /// Set by a 402 (daily cap) or 429: until then metrics are dropped, not buffered or sent —
    /// the same stance as `CrashReporter` and `DeviceManager`, so a capped project is not re-posted
    /// every flush. Cleared once the time has passed.
    private var suspendedUntil: Date?
    /// One POST at a time: the buffer is cleared before the `await`, so a flush-on-full triggered
    /// by metrics arriving during the round trip would otherwise fire a concurrent POST.
    private var isFlushing = false
    private let now: @Sendable () -> Date

    init(
        http: HTTPClient,
        context: ContextManager,
        config: PerformanceConfig,
        appVersionOverride: String?,
        log: Logger,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.now = now
        self.http = http
        self.context = context
        self.config = config
        self.appVersionOverride = appVersionOverride
        self.log = log
    }

    func setOnError(_ handler: @escaping @Sendable (Error, String) -> Void) {
        self.onError = handler
    }

    // MARK: - Lifecycle

    /// Start all enabled trackers and begin periodic flushing.
    func start() {
        guard !isRunning else { return }
        isRunning = true

        // Create metric callback that buffers into this actor
        let metricCallback: @Sendable (PerformanceMetric) -> Void = { [weak self] metric in
            guard let monitor = self else { return }
            Task { await monitor.addMetric(metric) }
        }

        // Initialize trackers based on config
        if config.startupTrackingEnabled {
            let tracker = StartupTracker(onMetric: metricCallback)
            self.startupTracker = tracker
            tracker.markFirstFrame()
        }

        if config.frameTrackingEnabled {
            let tracker = FrameTracker(
                slowFrameThresholdMs: config.slowFrameThresholdMs,
                frozenFrameThresholdMs: config.frozenFrameThresholdMs,
                onMetric: metricCallback
            )
            self.frameTracker = tracker
            DispatchQueue.main.async {
                tracker.start()
            }
        }

        if config.memoryTrackingEnabled {
            let tracker = MemoryTracker(onMetric: metricCallback)
            self.memoryTracker = tracker
            DispatchQueue.main.async {
                tracker.start()
            }
        }

        let watchdog = ANRWatchdog(thresholdMs: config.anrThresholdMs, onMetric: metricCallback)
        self.anrWatchdog = watchdog
        watchdog.start()

        #if canImport(UIKit)
        let startup = startupTracker
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { _ in
            startup?.markWarmStart()
        }

        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            startup?.markFirstFrame()
        }
        #endif

        // Start periodic flush
        flushTask = Task {
            while !Task.isCancelled {
                // `config.flushInterval` came from the mutable public
                // `PerformanceConfig.flushInterval` — sanitize right before use rather than
                // trusting the initializer clamp already applied to it (2026-09 security
                // follow-up round 3, finding MF-1).
                try? await Task.sleep(for: .seconds(config.flushInterval.sanitizedForSleep()))
                guard !Task.isCancelled else { break }
                await flush()
            }
        }

        log.debug("Performance monitor started")
    }

    /// Stop all trackers and flush remaining metrics.
    func stop() {
        guard isRunning else { return }
        isRunning = false

        frameTracker?.stop()
        anrWatchdog?.stop()
        memoryTracker?.stop()
        flushTask?.cancel()
        flushTask = nil

        log.debug("Performance monitor stopped")
    }

    // MARK: - Metric Collection

    /// Add a metric to the buffer. Flushes automatically when batch is full.
    func addMetric(_ metric: PerformanceMetric) {
        if isSuspended() { return }
        buffer.append(metric)
        if buffer.count >= config.maxBatchSize {
            Task { await flush() }
        }
    }

    // MARK: - Flush

    /// Flush buffered metrics to POST /v1/performance.
    func flush() async {
        if isSuspended() {
            buffer.removeAll()
            return
        }
        guard !buffer.isEmpty, !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }

        // Report periodic summaries before flush
        frameTracker?.reportSummary()
        memoryTracker?.reportMetric()

        let metrics = buffer
        buffer.removeAll()

        let ctx = context.eventContext()
        let payload = PerfBatchRequest(
            batch: metrics,
            context: PerfBatchContext(
                platform: DeviceProfile.platform,
                // The same version and build events and crashes send; `perfBatchContextSchema` caps both at 64.
                appVersion: DeviceProfile.wireAppVersion(override: appVersionOverride),
                buildNumber: DeviceProfile.wireBuildNumber(),
                osVersion: DeviceProfile.osVersion(),
                deviceModel: DeviceProfile.deviceModel(),
                userId: ctx.userId,
                sessionId: ctx.sessionId,
                deviceId: ctx.deviceId,
                // `perfBatchContextSchema.country` is `length(2)`: see `TrackSnapshot.countryCode`.
                country: TrackSnapshot.countryCode(Locale.current.region?.identifier),
                networkType: nil,
                activeFlags: nil,
                activeExperiments: nil
            ),
            sentAt: ISO8601DateFormatter().string(from: Date())
        )

        do {
            _ = try await http.postRaw(path: SDKEndpoints.perfIngest, body: payload)
            log.debug("Flushed \(metrics.count) performance metrics")
        } catch {
            log.warn("Performance flush failed: \(error.localizedDescription)")
            onError?(error, SDKEndpoints.perfIngest)
            // 402 (daily cap) and 429 say "not now": drop this batch and stop sending until the
            // window resets, instead of re-buffering into a flush-on-full loop.
            if let until = Self.suspension(for: error, now: now()) {
                suspendedUntil = until
                log.warn("Performance metrics paused until \(until) (server limit)")
                return
            }
            // Re-buffer metrics on failure (up to max batch size)
            let remaining = config.maxBatchSize - buffer.count
            if remaining > 0 {
                buffer.insert(contentsOf: metrics.prefix(remaining), at: 0)
            }
        }
    }

    // MARK: - Custom Spans

    /// Start a named span for custom performance measurement.
    func startSpan(_ name: String, attributes: [String: String] = [:]) -> SheepitSpan {
        let span = SheepitSpan(name: name, startTime: Date(), attributes: attributes)
        spans[name] = span
        return span
    }

    /// End a named span and record its duration as a metric.
    func endSpan(_ name: String) -> SheepitSpan? {
        guard let span = spans.removeValue(forKey: name) else { return nil }
        let endTime = Date()
        let completed = SheepitSpan(
            name: span.name,
            startTime: span.startTime,
            endTime: endTime,
            attributes: span.attributes
        )

        let durationMs = endTime.timeIntervalSince(span.startTime) * 1000
        let metric = PerformanceMetric(
            metricType: "span",
            metricName: name,
            valueMs: durationMs,
            statusCode: nil,
            isError: false,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
        buffer.append(metric)

        if buffer.count >= config.maxBatchSize {
            Task { await flush() }
        }

        return completed
    }

    // MARK: - Public Summary

    /// Get a snapshot of current performance data.
    func performanceSummary() -> SheepitPerformanceSummary {
        SheepitPerformanceSummary(
            coldStartMs: startupTracker?.coldStartMs,
            warmStartMs: startupTracker?.warmStartMs,
            slowFrameCount: frameTracker?.slowFrameCount ?? 0,
            frozenFrameCount: frameTracker?.frozenFrameCount ?? 0,
            totalFrameCount: frameTracker?.totalFrameCount ?? 0,
            memoryPeakMb: memoryTracker?.peakMemoryMb ?? 0,
            anrCount: anrWatchdog?.anrCount ?? 0
        )
    }

    /// Mark the first frame rendered (for startup tracking).
    func markFirstFrame() {
        startupTracker?.markFirstFrame()
    }

    /// True while a 402/429 suspension is in force; clears it once the time has passed.
    private func isSuspended() -> Bool {
        guard let until = suspendedUntil else { return false }
        if now() < until { return true }
        suspendedUntil = nil
        return false
    }

    /// When sending may resume after `error`: the next 00:00 UTC for the daily cap (402), the
    /// `Retry-After` (default 60 s) for a 429; nil for anything else.
    static func suspension(for error: Error, now: Date) -> Date? {
        guard let sdkError = error as? SDKError else { return nil }
        switch sdkError {
        case .httpError(402):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
            return calendar.nextDate(
                after: now, matching: DateComponents(hour: 0, minute: 0, second: 0),
                matchingPolicy: .nextTime
            )
        case .rateLimited(let retryAfter):
            return now.addingTimeInterval(max(1, retryAfter ?? 60))
        default:
            return nil
        }
    }
}
