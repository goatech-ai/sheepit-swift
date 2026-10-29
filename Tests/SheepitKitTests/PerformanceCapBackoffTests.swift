import XCTest
@testable import SheepitKit

/// A 402 (daily cap) or 429 on `POST /v1/performance/ingest` must drop the batch and stop sending
/// until the window resets. Before, `flush()` re-buffered every failure and `addMetric` flushed on
/// every new metric once the buffer was full, so a capped project re-posted continuously.
final class PerformanceCapBackoffTests: XCTestCase {
    private func makeMonitor(now: @escaping @Sendable () -> Date) -> PerformanceMonitor {
        let http = HTTPClient(
            config: SheepitConfig(
                apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))", apiUrl: "https://stub.invalid"
            ),
            log: Logger(debug: false),
            urlProtocolClasses: [StubURLProtocol.self]
        )
        return PerformanceMonitor(
            http: http,
            context: ContextManager(storage: InMemoryStorage()),
            config: PerformanceConfig(
                enabled: true,
                startupTrackingEnabled: false,
                frameTrackingEnabled: false,
                networkTrackingEnabled: false,
                memoryTrackingEnabled: false
            ),
            appVersionOverride: nil,
            log: Logger(debug: false),
            now: now
        )
    }

    private func metric() -> PerformanceMetric {
        PerformanceMetric(
            metricType: "startup", metricName: "cold_start", valueMs: 1, statusCode: nil, isError: false,
            timestamp: "2026-10-21T00:00:00Z"
        )
    }

    func testA402DropsTheBatchAndStopsSendingUntilTheNextUTCMidnight() async {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        let clock = Clock(Date(timeIntervalSince1970: 1_793_000_000))
        let monitor = makeMonitor(now: { clock.value })
        StubURLProtocol.stub = .status(402, body: "{\"error\":{\"code\":\"PREVIEW_LIMIT_EXCEEDED\"}}")

        await monitor.addMetric(metric())
        await monitor.flush()
        XCTAssertEqual(StubURLProtocol.requestCount, 1, "the capped batch is posted once")

        // Many more metrics and flushes while capped: nothing is sent.
        for _ in 0..<200 { await monitor.addMetric(metric()) }
        await monitor.flush()
        XCTAssertEqual(StubURLProtocol.requestCount, 1, "a capped project must not re-post")

        // After the UTC day rolls over, sending resumes.
        StubURLProtocol.stub = .status(200, body: "{}")
        clock.value = clock.value.addingTimeInterval(86_400 + 1)
        await monitor.addMetric(metric())
        await monitor.flush()
        XCTAssertEqual(StubURLProtocol.requestCount, 2)
    }

    func testA429SuspendsForRetryAfterAndDropsTheBatch() async {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        let clock = Clock(Date(timeIntervalSince1970: 1_793_000_000))
        let monitor = makeMonitor(now: { clock.value })
        StubURLProtocol.stub = .status(429, body: "{}", headers: ["Retry-After": "30"])

        await monitor.addMetric(metric())
        await monitor.flush()
        let afterFirst = StubURLProtocol.requestCount
        XCTAssertGreaterThanOrEqual(afterFirst, 1)

        await monitor.addMetric(metric())
        await monitor.flush()
        XCTAssertEqual(StubURLProtocol.requestCount, afterFirst, "suspended for Retry-After")

        StubURLProtocol.stub = .status(200, body: "{}")
        clock.value = clock.value.addingTimeInterval(31)
        await monitor.addMetric(metric())
        await monitor.flush()
        XCTAssertEqual(StubURLProtocol.requestCount, afterFirst + 1)
    }

    /// Metrics that arrive during the round trip trigger a flush-on-full; it must not start a second
    /// concurrent POST. They stay buffered for the next flush.
    func testOnlyOnePostIsInFlightAtATime() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        StubURLProtocol.responseDelay = 0.4
        let monitor = makeMonitor(now: { Date() })

        await monitor.addMetric(metric())
        let first = Task { await monitor.flush() }
        try await Task.sleep(nanoseconds: 100_000_000)
        for _ in 0..<60 { await monitor.addMetric(metric()) }  // fills the batch: flush-on-full
        try await Task.sleep(nanoseconds: 100_000_000)
        await first.value
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertEqual(StubURLProtocol.requestCount, 1, "a second POST must not start while one is in flight")
    }

    func testAServerErrorStillRebuffers() async {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        let monitor = makeMonitor(now: { Date() })
        StubURLProtocol.stub = .status(500, body: "{}")
        await monitor.addMetric(metric())
        await monitor.flush()
        let afterFirst = StubURLProtocol.requestCount

        // Unlike a cap, a 5xx is transient: the metric is kept and the next flush retries it.
        StubURLProtocol.stub = .status(200, body: "{}")
        await monitor.flush()
        XCTAssertGreaterThan(StubURLProtocol.requestCount, afterFirst)
    }
}

/// A mutable clock the `@Sendable` closure can read.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ date: Date) { current = date }
    var value: Date {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set { lock.lock(); current = newValue; lock.unlock() }
    }
}
