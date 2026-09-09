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
    private var networkCollector: NetworkMetricsCollector?

    private var buffer: [PerformanceMetric] = []
    private var spans: [String: SheepitSpan] = [:]
    private var flushTask: Task<Void, Never>?
    private var isRunning = false

    init(
        http: HTTPClient,
        context: ContextManager,
        config: PerformanceConfig,
        log: Logger
    ) {
        self.http = http
        self.context = context
        self.config = config
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

        if config.networkTrackingEnabled {
            self.networkCollector = NetworkMetricsCollector(onMetric: metricCallback)
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
                try? await Task.sleep(for: .seconds(config.flushInterval))
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
        buffer.append(metric)
        if buffer.count >= config.maxBatchSize {
            Task { await flush() }
        }
    }

    // MARK: - Flush

    /// Flush buffered metrics to POST /v1/performance.
    func flush() async {
        guard !buffer.isEmpty else { return }

        // Report periodic summaries before flush
        frameTracker?.reportSummary()
        memoryTracker?.reportMetric()

        let metrics = buffer
        buffer.removeAll()

        let ctx = context.eventContext()
        let payload = PerfBatchRequest(
            batch: metrics,
            context: PerfBatchContext(
                platform: "ios",
                appVersion: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
                buildNumber: Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
                osVersion: osVersion(),
                deviceModel: deviceModel(),
                userId: ctx.userId,
                sessionId: ctx.sessionId,
                deviceId: ctx.deviceId,
                country: Locale.current.region?.identifier,
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

    // MARK: - Private

    private func deviceModel() -> String {
        #if canImport(UIKit)
        return UIDevice.current.model
        #else
        return "Mac"
        #endif
    }

    private func osVersion() -> String {
        #if canImport(UIKit)
        return UIDevice.current.systemVersion
        #else
        return ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }
}
