import XCTest
@testable import SheepitKit

/// `Transport.flush()` used to funnel EVERY failure into the offline
/// queue, so a batch the server permanently rejects (400) was re-sent on
/// every drain forever — a poison loop that also starved the good events
/// behind it. These tests pin the three routes:
///
///   4xx except 429 → dropped · 429 → re-queued · 5xx/network → offline queue
///
/// The API is stubbed via `StubURLProtocol` (see
/// `Support/TransportTestHarness.swift`).
final class TransportErrorClassingTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testBadRequestDropsTheBatch() async {
        StubURLProtocol.stub = .status(400, body: #"{"error":{"code":"INVALID"}}"#)
        let harness = makeTransportHarness()
        harness.queue.add(makeStubEvent(name: "a"))
        harness.queue.add(makeStubEvent(name: "b"))

        await harness.transport.flush()

        XCTAssertEqual(harness.queue.size(), 0, "400 must not be re-queued")
        XCTAssertEqual(harness.offlineQueue.size(), 0, "400 must not reach the offline queue")
        XCTAssertEqual(StubURLProtocol.requestCount, 1, "400 must not be retried")
    }

    func testOther4xxDropsTheBatch() async {
        // 401 (revoked key) / 413 (batch too large) are equally permanent.
        StubURLProtocol.stub = .status(401, body: "")
        let harness = makeTransportHarness()
        harness.queue.add(makeStubEvent(name: "a"))

        await harness.transport.flush()

        XCTAssertEqual(harness.queue.size(), 0)
        XCTAssertEqual(harness.offlineQueue.size(), 0)
    }

    func testRateLimitRequeuesRatherThanDropping() async {
        StubURLProtocol.stub = .status(429, body: "", headers: ["Retry-After": "1"])
        let harness = makeTransportHarness()
        harness.queue.add(makeStubEvent(name: "a"))
        harness.queue.add(makeStubEvent(name: "b"))

        await harness.transport.flush()

        XCTAssertEqual(harness.queue.size(), 2, "429 must return the events to the live queue")
        XCTAssertEqual(harness.offlineQueue.size(), 0)
    }

    /// Pins the BOUNDED-loss semantics of the 429 path: during a long
    /// back-off a host that keeps calling track() past maxQueueSize evicts
    /// the oldest events — but the eviction is reported, not silent.
    func testSustainedTrafficDuringBackOffEvictsButReportsIt() async {
        StubURLProtocol.reset()
        StubURLProtocol.stub = .status(429, body: "", headers: ["Retry-After": "60"])
        defer { StubURLProtocol.reset() }

        let bus = DiagnosticBus()
        let queue = EventQueue(maxSize: 3, diagnostics: bus)
        let config = SheepitConfig(
            apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))",
            apiUrl: "https://stub.invalid",
            retryAttempts: 1
        )
        let log = Logger(debug: false)
        let transport = Transport(
            http: HTTPClient(config: config, log: log, urlProtocolClasses: [StubURLProtocol.self]),
            queue: queue,
            offlineQueue: OfflineQueue(storage: InMemoryStorage()),
            connectivity: ConnectivityMonitor(),
            log: log,
            diagnostics: bus
        )

        queue.add(makeStubEvent(name: "a"))
        await transport.flush()  // 429 → re-queued, back-off armed

        // Host keeps tracking through the back-off window.
        for index in 0..<6 { queue.add(makeStubEvent(name: "during_\(index)")) }

        XCTAssertEqual(queue.size(), 3, "the bound holds")
        let evictions = bus.getRecentDiagnostics().filter { $0.code == "queue.overflow_evicted" }
        XCTAssertFalse(evictions.isEmpty, "eviction under back-off must not be silent")
    }

    func testRateLimitBacksOffBeforeTheNextFlush() async {
        StubURLProtocol.stub = .status(429, body: "", headers: ["Retry-After": "60"])
        let harness = makeTransportHarness()
        harness.queue.add(makeStubEvent(name: "a"))

        await harness.transport.flush()
        XCTAssertEqual(StubURLProtocol.requestCount, 1)

        // Within the Retry-After window the next flush must not hit the network.
        await harness.transport.flush()
        XCTAssertEqual(StubURLProtocol.requestCount, 1, "flush during back-off must be a no-op")
        XCTAssertEqual(harness.queue.size(), 1, "events stay queued through the back-off")
    }

    func testServerErrorGoesToTheOfflineQueue() async {
        StubURLProtocol.stub = .status(500, body: "")
        // retryAttempts: 1 keeps HTTPClient from sleeping through its backoff ladder.
        let harness = makeTransportHarness(retryAttempts: 1)
        harness.queue.add(makeStubEvent(name: "a"))

        await harness.transport.flush()

        XCTAssertEqual(harness.offlineQueue.size(), 1, "5xx is retryable — persist it")
        XCTAssertEqual(harness.queue.size(), 0)
    }

    func testNetworkErrorGoesToTheOfflineQueue() async {
        StubURLProtocol.stub = .failure(URLError(.notConnectedToInternet))
        let harness = makeTransportHarness(retryAttempts: 1)
        harness.queue.add(makeStubEvent(name: "a"))

        await harness.transport.flush()

        XCTAssertEqual(harness.offlineQueue.size(), 1)
        XCTAssertEqual(harness.queue.size(), 0)
    }

    func testSuccessfulFlushRecordsLastFlushAt() async {
        StubURLProtocol.stub = .status(200, body: #"{"data":{"accepted":1}}"#)
        let harness = makeTransportHarness()
        XCTAssertNil(harness.clock.date)
        harness.queue.add(makeStubEvent(name: "a"))

        await harness.transport.flush()

        XCTAssertEqual(harness.queue.size(), 0)
        XCTAssertEqual(harness.offlineQueue.size(), 0)
        XCTAssertNotNil(harness.clock.date, "status().lastFlushAt is fed from here")
    }

    func testFailuresEmitDiagnostics() async {
        StubURLProtocol.stub = .status(400, body: "nope")
        let harness = makeTransportHarness()
        harness.queue.add(makeStubEvent(name: "a"))

        await harness.transport.flush()

        let codes = harness.diagnostics.getRecentDiagnostics().map(\.code)
        XCTAssertTrue(codes.contains("transport.batch_dropped"), "got \(codes)")
    }

}
