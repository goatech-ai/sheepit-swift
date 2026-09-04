import XCTest
@testable import SheepitSDK

final class PerformanceTests: XCTestCase {

    // MARK: - PerformanceConfig

    func testDefaultConfig() {
        let config = PerformanceConfig()
        XCTAssertFalse(config.enabled)
        XCTAssertTrue(config.startupTrackingEnabled)
        XCTAssertTrue(config.frameTrackingEnabled)
        XCTAssertTrue(config.networkTrackingEnabled)
        XCTAssertTrue(config.memoryTrackingEnabled)
        XCTAssertEqual(config.anrThresholdMs, 5000)
        XCTAssertEqual(config.slowFrameThresholdMs, 16.67)
        XCTAssertEqual(config.frozenFrameThresholdMs, 700.0)
        XCTAssertEqual(config.flushInterval, 30.0)
        XCTAssertEqual(config.maxBatchSize, 50)
    }

    func testCustomConfig() {
        let config = PerformanceConfig(
            enabled: true,
            startupTrackingEnabled: false,
            frameTrackingEnabled: false,
            anrThresholdMs: 3000,
            flushInterval: 10.0,
            maxBatchSize: 25
        )
        XCTAssertTrue(config.enabled)
        XCTAssertFalse(config.startupTrackingEnabled)
        XCTAssertFalse(config.frameTrackingEnabled)
        XCTAssertEqual(config.anrThresholdMs, 3000)
        XCTAssertEqual(config.flushInterval, 10.0)
        XCTAssertEqual(config.maxBatchSize, 25)
    }

    // MARK: - SheepitConfig Integration

    func testSheepitConfigIncludesPerformance() {
        let config = SheepitConfig(
            apiKey: "lp_pub_test_0000000000000000000000000000000000000000000000000000000000000000",
            performance: PerformanceConfig(enabled: true)
        )
        XCTAssertTrue(config.performance.enabled)
    }

    func testSheepitConfigDefaultPerformanceDisabled() {
        let config = SheepitConfig(
            apiKey: "lp_pub_test_0000000000000000000000000000000000000000000000000000000000000000"
        )
        XCTAssertFalse(config.performance.enabled)
    }

    // MARK: - StartupTracker

    func testColdStartTracking() {
        let receivedMetrics = MetricSink()
        let tracker = StartupTracker { metric in
            receivedMetrics.append(metric)
        }

        tracker.markFirstFrame()

        XCTAssertEqual(receivedMetrics.count, 1)
        XCTAssertEqual(receivedMetrics[0].metricType, "startup")
        XCTAssertEqual(receivedMetrics[0].metricName, "cold_start")
        // `>= 0`, NOT `> 0`. StartupTracker samples `systemUptime` in `init` and
        // again in `markFirstFrame()`; in this test those are adjacent statements,
        // so the elapsed time is legitimately ~0 and whether it rounds above zero
        // is a property of the CLOCK, not of the code. Asserting `> 0` blocked the
        // swift-v1.0.1 release twice (run 33896279530) while passing 14/14 locally
        // on the same commit and the same machine.
        //
        // Testing the duration for real needs an injectable clock in
        // StartupTracker — queued in PENDING_WORK. Until then, assert what this
        // test can actually establish: a cold_start metric is emitted exactly
        // once, non-negative, not an error, and mirrored onto `coldStartMs`.
        XCTAssertGreaterThanOrEqual(receivedMetrics[0].valueMs, 0)
        XCTAssertFalse(receivedMetrics[0].isError)
        XCTAssertNotNil(tracker.coldStartMs)
        XCTAssertEqual(tracker.coldStartMs, receivedMetrics[0].valueMs)
    }

    func testColdStartOnlyRecordedOnce() {
        let receivedMetrics = MetricSink()
        let tracker = StartupTracker { metric in
            receivedMetrics.append(metric)
        }

        tracker.markFirstFrame()
        tracker.markFirstFrame()

        XCTAssertEqual(receivedMetrics.count, 1)
    }

    func testWarmStartTracking() {
        let receivedMetrics = MetricSink()
        let tracker = StartupTracker { metric in
            receivedMetrics.append(metric)
        }

        // First cold start
        tracker.markFirstFrame()
        XCTAssertEqual(receivedMetrics.count, 1)

        // Warm start cycle
        tracker.markWarmStart()
        tracker.markFirstFrame()

        XCTAssertEqual(receivedMetrics.count, 2)
        XCTAssertEqual(receivedMetrics[1].metricType, "startup")
        XCTAssertEqual(receivedMetrics[1].metricName, "warm_start")
        XCTAssertNotNil(tracker.warmStartMs)
    }

    // MARK: - MemoryTracker

    func testMemorySampling() {
        let receivedMetrics = MetricSink()
        let tracker = MemoryTracker { metric in
            receivedMetrics.append(metric)
        }

        tracker.sample()

        XCTAssertGreaterThan(tracker.currentMemoryBytes, 0)
        XCTAssertGreaterThan(tracker.peakMemoryBytes, 0)
        XCTAssertEqual(tracker.peakMemoryBytes, tracker.currentMemoryBytes)
    }

    func testMemoryPeakTracking() {
        let tracker = MemoryTracker { _ in }

        tracker.sample()
        let firstSample = tracker.peakMemoryBytes

        // Peak should be at least what we've seen
        XCTAssertGreaterThanOrEqual(tracker.peakMemoryBytes, firstSample)
    }

    func testMemoryReportMetric() {
        let receivedMetrics = MetricSink()
        let tracker = MemoryTracker { metric in
            receivedMetrics.append(metric)
        }

        tracker.reportMetric()

        XCTAssertEqual(receivedMetrics.count, 1)
        XCTAssertEqual(receivedMetrics[0].metricType, "memory")
        XCTAssertEqual(receivedMetrics[0].metricName, "memory_usage")
        XCTAssertGreaterThan(receivedMetrics[0].valueMs, 0) // valueMs holds MB for memory
        XCTAssertFalse(receivedMetrics[0].isError)
    }

    // MARK: - PerformanceMetric Encoding

    func testPerformanceMetricEncoding() throws {
        let metric = PerformanceMetric(
            metricType: "startup",
            metricName: "cold_start",
            valueMs: 1234.5,
            statusCode: nil,
            isError: false,
            timestamp: "2026-01-01T00:00:00Z"
        )

        let data = try JSONEncoder().encode(metric)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(dict["metric_type"] as? String, "startup")
        XCTAssertEqual(dict["metric_name"] as? String, "cold_start")
        XCTAssertEqual(dict["value_ms"] as? Double, 1234.5)
        XCTAssertEqual(dict["is_error"] as? Bool, false)
        XCTAssertEqual(dict["timestamp"] as? String, "2026-01-01T00:00:00Z")
        // status_code should be null or absent when nil
        let statusCode = dict["status_code"]
        XCTAssertTrue(statusCode == nil || statusCode is NSNull)
    }

    func testPerformanceMetricWithStatusCode() throws {
        let metric = PerformanceMetric(
            metricType: "network",
            metricName: "https://api.example.com/data",
            valueMs: 350.0,
            statusCode: 200,
            isError: false,
            timestamp: "2026-01-01T00:00:00Z"
        )

        let data = try JSONEncoder().encode(metric)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(dict["status_code"] as? Int, 200)
        XCTAssertEqual(dict["metric_type"] as? String, "network")
    }

    // MARK: - PerfBatchRequest Encoding

    func testBatchRequestEncoding() throws {
        let metric = PerformanceMetric(
            metricType: "startup",
            metricName: "cold_start",
            valueMs: 500.0,
            statusCode: nil,
            isError: false,
            timestamp: "2026-01-01T00:00:00Z"
        )

        let context = PerfBatchContext(
            platform: "ios",
            appVersion: "1.0.0",
            buildNumber: "42",
            osVersion: "17.0",
            deviceModel: "iPhone",
            userId: "user_123",
            sessionId: "sess_abc",
            deviceId: "dev_xyz",
            country: "US",
            networkType: nil,
            activeFlags: nil,
            activeExperiments: nil
        )

        let request = PerfBatchRequest(
            batch: [metric],
            context: context,
            sentAt: "2026-01-01T00:00:00Z"
        )

        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertNotNil(dict["batch"])
        XCTAssertEqual(dict["sent_at"] as? String, "2026-01-01T00:00:00Z")

        let ctx = dict["context"] as! [String: Any]
        XCTAssertEqual(ctx["platform"] as? String, "ios")
        XCTAssertEqual(ctx["app_version"] as? String, "1.0.0")
        XCTAssertEqual(ctx["build_number"] as? String, "42")
        XCTAssertEqual(ctx["os_version"] as? String, "17.0")
        XCTAssertEqual(ctx["device_model"] as? String, "iPhone")
        XCTAssertEqual(ctx["user_id"] as? String, "user_123")
        XCTAssertEqual(ctx["session_id"] as? String, "sess_abc")
        XCTAssertEqual(ctx["device_id"] as? String, "dev_xyz")
        XCTAssertEqual(ctx["country"] as? String, "US")
    }

    // MARK: - SheepitSpan

    func testSpanCreation() {
        let span = SheepitSpan(
            name: "checkout_flow",
            attributes: ["screen": "cart"]
        )

        XCTAssertEqual(span.name, "checkout_flow")
        XCTAssertNil(span.endTime)
        XCTAssertEqual(span.attributes["screen"], "cart")
    }

    func testSpanCompletion() {
        let start = Date()
        let span = SheepitSpan(
            name: "image_load",
            startTime: start,
            endTime: Date(),
            attributes: [:]
        )

        XCTAssertNotNil(span.endTime)
        XCTAssertGreaterThanOrEqual(span.endTime!.timeIntervalSince(span.startTime), 0)
    }

    // MARK: - SheepitPerformanceSummary

    func testPerformanceSummaryDefaults() {
        let summary = SheepitPerformanceSummary(
            coldStartMs: nil,
            warmStartMs: nil,
            slowFrameCount: 0,
            frozenFrameCount: 0,
            totalFrameCount: 0,
            memoryPeakMb: 0,
            anrCount: 0
        )

        XCTAssertNil(summary.coldStartMs)
        XCTAssertNil(summary.warmStartMs)
        XCTAssertEqual(summary.slowFrameCount, 0)
        XCTAssertEqual(summary.frozenFrameCount, 0)
        XCTAssertEqual(summary.totalFrameCount, 0)
        XCTAssertEqual(summary.memoryPeakMb, 0)
        XCTAssertEqual(summary.anrCount, 0)
    }

    // MARK: - NetworkMetricsCollector

    func testNetworkCollectorInit() {
        let collector = NetworkMetricsCollector { _ in }
        XCTAssertNotNil(collector)
    }

    // MARK: - ANRWatchdog

    func testANRWatchdogInit() {
        let watchdog = ANRWatchdog(thresholdMs: 5000) { _ in }
        XCTAssertEqual(watchdog.anrCount, 0)
    }

    // Audit R-004: state machine for the watchdog. The bug-fix split
    // the tick logic into a pure transition function so we can prove
    // its correctness without freezing the main thread or calling
    // DispatchQueue.main.sync (which was the deadlock).

    func testANRWatchdogStateNoEventOnHealthyMainThread() {
        let s = ANRWatchdogState(freezeStartedAt: nil)
        let (next, tick) = ANRWatchdogState.transition(
            previous: s, responded: true, now: Date(), thresholdMs: 5000
        )
        XCTAssertEqual(tick, .none)
        XCTAssertNil(next.freezeStartedAt)
    }

    func testANRWatchdogStateEmitsDetectedOnFirstNonResponsiveTick() {
        let s = ANRWatchdogState(freezeStartedAt: nil)
        let now = Date()
        let (next, tick) = ANRWatchdogState.transition(
            previous: s, responded: false, now: now, thresholdMs: 5000
        )
        XCTAssertEqual(tick, .detected(thresholdMs: 5000))
        XCTAssertEqual(next.freezeStartedAt, now)
    }

    func testANRWatchdogStateEmitsDetectedOnlyOncePerContiguousFreeze() {
        let start = Date()
        let s = ANRWatchdogState(freezeStartedAt: start)
        let later = start.addingTimeInterval(10)
        let (next, tick) = ANRWatchdogState.transition(
            previous: s, responded: false, now: later, thresholdMs: 5000
        )
        XCTAssertEqual(tick, .none)
        // freezeStartedAt is preserved — still the first failed ping.
        XCTAssertEqual(next.freezeStartedAt, start)
    }

    func testANRWatchdogStateEmitsRecoveredWithMeasuredDuration() {
        let start = Date()
        let s = ANRWatchdogState(freezeStartedAt: start)
        let recovered = start.addingTimeInterval(7.5)
        let (next, tick) = ANRWatchdogState.transition(
            previous: s, responded: true, now: recovered, thresholdMs: 5000
        )
        XCTAssertEqual(tick, .recovered(durationMs: 7500))
        XCTAssertNil(next.freezeStartedAt)
    }

    func testANRWatchdogStateRecoveryWithoutPriorFreezeIsNoop() {
        let s = ANRWatchdogState(freezeStartedAt: nil)
        let (next, tick) = ANRWatchdogState.transition(
            previous: s, responded: true, now: Date(), thresholdMs: 5000
        )
        XCTAssertEqual(tick, .none)
        XCTAssertNil(next.freezeStartedAt)
    }

    // MARK: - FrameTracker

    func testFrameTrackerInit() {
        let tracker = FrameTracker(
            slowFrameThresholdMs: 16.67,
            frozenFrameThresholdMs: 700.0
        ) { _ in }

        XCTAssertEqual(tracker.slowFrameCount, 0)
        XCTAssertEqual(tracker.frozenFrameCount, 0)
        XCTAssertEqual(tracker.totalFrameCount, 0)
    }

    func testFrameTrackerReportSummary() {
        let receivedMetrics = MetricSink()
        let tracker = FrameTracker(
            slowFrameThresholdMs: 16.67,
            frozenFrameThresholdMs: 700.0
        ) { metric in
            receivedMetrics.append(metric)
        }

        tracker.reportSummary()

        XCTAssertEqual(receivedMetrics.count, 1)
        XCTAssertEqual(receivedMetrics[0].metricType, "frames")
        XCTAssertEqual(receivedMetrics[0].metricName, "frame_summary")
    }
}

/// Thread-safe accumulator for the performance trackers' `onMetric` callbacks.
/// Those are typed `@escaping @Sendable`, so a captured `var` array can't be
/// mutated from the closure under Swift 6 concurrency checking (and in production
/// these callbacks can fire from concurrent delegate queues). Mirrors the
/// `[PerformanceMetric]` reads the tests rely on (`count`, subscript).
private final class MetricSink: @unchecked Sendable {
    private let lock = NSLock()
    // SAFETY: all reads and writes to `storage` go through `lock`.
    private var storage: [PerformanceMetric] = []

    func append(_ metric: PerformanceMetric) {
        lock.lock(); defer { lock.unlock() }
        storage.append(metric)
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return storage.count
    }

    subscript(_ index: Int) -> PerformanceMetric {
        lock.lock(); defer { lock.unlock() }
        return storage[index]
    }
}
