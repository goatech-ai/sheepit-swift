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
    private nonisolated let appVersionOverride: String?
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
    private nonisolated let captureContext: @Sendable () -> PerfBatchContext
    private var spanContexts: [String: PerfBatchContext] = [:]
    /// The identity epoch each open span was captured under; a span ended under a newer one is
    /// unattributed (see `identityDidChange()`).
    private var spanEpochs: [String: UInt64] = [:]
    private nonisolated let identityEpoch = IdentityEpoch()

    init(
        http: HTTPClient,
        context: ContextManager,
        config: PerformanceConfig,
        appVersionOverride: String?,
        log: Logger,
        now: @escaping @Sendable () -> Date = { Date() },
        captureContext: (@Sendable () -> PerfBatchContext)? = nil
    ) {
        self.captureContext = captureContext ?? {
            context.tryEventContext().map {
                PerfBatchContext.capture($0, appVersion: appVersionOverride, receipt: AssignmentReceipt())
            } ?? PerfBatchContext.unattributed(appVersion: appVersionOverride)
        }
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
    nonisolated func start() async {
        let captured = contextSnapshot()
        await start(capturedContext: captured)
    }

    private func start(capturedContext: PerfBatchContext) {
        guard !isRunning else { return }
        isRunning = true

        // Create metric callback that buffers into this actor
        let capture = captureContext
        let metricCallback: @Sendable (PerformanceMetric) -> Void = { [weak self] metric in
            guard let monitor = self else { return }
            var captured = metric
            if captured.context == nil { captured.context = capture() }
            let frozen = captured
            Task { await monitor.addMetric(frozen) }
        }

        // Initialize trackers based on config
        if config.startupTrackingEnabled {
            let tracker = StartupTracker(captureContext: capture, initialContext: capturedContext,
                                         epoch: identityEpoch, onMetric: metricCallback)
            self.startupTracker = tracker
            tracker.markFirstFrame()
        }

        if config.frameTrackingEnabled {
            let tracker = FrameTracker(
                slowFrameThresholdMs: config.slowFrameThresholdMs,
                frozenFrameThresholdMs: config.frozenFrameThresholdMs,
                captureContext: capture,
                initialContext: capturedContext,
                epoch: identityEpoch,
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

        let appVersion = appVersionOverride
        let watchdog = ANRWatchdog(thresholdMs: config.anrThresholdMs, captureContext: capture, epoch: identityEpoch,
            unattributedContext: { PerfBatchContext.unattributed(appVersion: appVersion) }, onMetric: metricCallback)
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
    nonisolated func addMetric(_ metric: PerformanceMetric) async {
        var captured = metric
        if captured.context == nil { captured.context = contextSnapshot() }
        await appendMetric(captured)
    }

    private func appendMetric(_ metric: PerformanceMetric) {
        if isSuspended() { return }
        buffer.append(metric)
        if buffer.count >= config.maxBatchSize {
            Task { await flush() }
        }
    }

    // MARK: - Flush

    /// Flush buffered metrics to POST /v1/performance.
    nonisolated func flush() async {
        // Epoch first, then the sample (the `spanSnapshot()` order): a reset during the actor hop
        // ends the identity the sample was taken under.
        let epoch = identityEpoch.current
        let captured = contextSnapshot()
        await flush(capturedContext: captured, epoch: epoch)
    }

    private func flush(capturedContext: PerfBatchContext, epoch: UInt64) async {
        if isSuspended() {
            buffer.removeAll()
            return
        }
        guard !buffer.isEmpty, !isFlushing else { return }
        isFlushing = true
        defer { isFlushing = false }

        // Report periodic summaries before flush
        frameTracker?.reportSummary()
        memoryTracker?.reportMetric(context: epoch == identityEpoch.current ? capturedContext : capturedContext.anonymized())

        let metrics = buffer
        buffer.removeAll()

        let payload = PerfBatchRequest(
            batch: metrics,
            // Fail closed: the envelope names nobody. Every metric carries its own captured context,
            // which the server reads in preference to this one.
            context: PerfBatchContext.unattributed(appVersion: appVersionOverride),
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
    nonisolated func contextSnapshot() -> PerfBatchContext { captureContext() }

    /// A span's start context and the identity epoch it was captured under. The epoch is read
    /// FIRST: `identityDidChange()` runs after the identity is cleared, so a context that still
    /// names the old identity was necessarily read under an epoch that is already stale.
    struct SpanSnapshot: Sendable {
        let epoch: UInt64
        let context: PerfBatchContext
    }

    nonisolated func spanSnapshot() -> SpanSnapshot {
        let epoch = identityEpoch.current
        return SpanSnapshot(epoch: epoch, context: contextSnapshot())
    }

    /// The identity this monitor's captures belong to is gone (`reset()`; not an identify, which keeps
    /// spans attributed to the identity they started under). Synchronous and lock-only, so it is complete before the caller returns: spans
    /// open across it end `unattributed` (the duration is kept, the identity and receipt are not),
    /// the frame window and any pending warm start are discarded on their next touch.
    nonisolated func identityDidChange() { identityEpoch.advance() }

    /// A different user identified on the same device: spans keep the identity they started under,
    /// but the cumulative frame window and a pending warm start restart.
    nonisolated func identitySwitched() { identityEpoch.advanceWindow() }

    nonisolated func startSpan(_ name: String, attributes: [String: String] = [:],
                              snapshot: SpanSnapshot? = nil) async -> SheepitSpan {
        let captured = snapshot ?? spanSnapshot()
        return await beginSpan(name, attributes: attributes, snapshot: captured)
    }

    private func beginSpan(_ name: String, attributes: [String: String], snapshot: SpanSnapshot) -> SheepitSpan {
        let span = SheepitSpan(name: name, startTime: Date(), attributes: attributes)
        spans[name] = span
        spanContexts[name] = snapshot.context
        spanEpochs[name] = snapshot.epoch
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
        var metric = PerformanceMetric(
            metricType: "span",
            metricName: name,
            valueMs: durationMs,
            statusCode: nil,
            isError: false,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
        let startedContext = spanContexts.removeValue(forKey: name)
        let startedEpoch = spanEpochs.removeValue(forKey: name)
        // Read at end time on the actor, after `identityDidChange()` returned: no stale read.
        let sameIdentity = startedEpoch == identityEpoch.current
        metric.context = (sameIdentity ? startedContext : nil) ?? PerfBatchContext.unattributed(appVersion: appVersionOverride)
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

    /// Test-only: the live trackers, to drive frames and foreground transitions without a display.
    func trackersForTesting() -> (frame: FrameTracker?, startup: StartupTracker?) { (frameTracker, startupTracker) }

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
