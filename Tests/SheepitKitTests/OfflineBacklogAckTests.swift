import XCTest
@testable import SheepitKit

/// In-flight crash window, the follow-up to S3c (#1016). Before this fix `Transport.flush()`
/// drained the offline queue, which also wrote it to disk empty, before sending anything. A
/// process killed mid-request therefore lost every persisted event that flush had taken, up to
/// 500. Persisted events now stay on disk until their request is answered, and are then removed
/// by event id (founder decision: at-least-once; `event_id` dedup collapses a resend).
///
/// `DiskProbeProtocol` reads the offline queue FROM STORAGE, through a fresh `OfflineQueue`,
/// at the moment each request starts. That is what a process killed at that instant would
/// find on relaunch.
final class OfflineBacklogAckTests: XCTestCase {
    override func setUp() {
        super.setUp()
        DiskProbeProtocol.reset()
    }

    private func event(_ name: String) -> EnrichedEvent {
        EnrichedEvent(
            eventId: UUID().uuidString, eventName: name, eventProperties: nil,
            deviceId: "device-1", anonymousId: "anon-1", sessionId: "session-1", userId: nil,
            platform: "ios", sdkVersion: SDKDefaults.sdkVersion, locale: "en_US", timezone: "UTC",
            timestamp: SheepitClient.formatEventTimestamp(Date()), snapshot: nil
        )
    }

    private func makeTransport(storage: InMemoryStorage, queue: EventQueue = EventQueue(maxSize: 1000)) -> (Transport, OfflineQueue) {
        let offline = OfflineQueue(storage: storage)
        let config = SheepitConfig(
            apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))",
            apiUrl: "https://stub.invalid",
            retryAttempts: 1
        )
        let log = Logger(debug: false)
        let transport = Transport(
            http: HTTPClient(config: config, log: log, urlProtocolClasses: [DiskProbeProtocol.self]),
            queue: queue,
            offlineQueue: offline,
            connectivity: ConnectivityMonitor(),
            log: log
        )
        return (transport, offline)
    }

    private func persist(_ events: [EnrichedEvent], in storage: InMemoryStorage) {
        OfflineQueue(storage: storage).enqueue(events)
    }

    private func onDisk(_ storage: InMemoryStorage) -> [String] {
        OfflineQueue(storage: storage).drain().map(\.eventId)
    }

    // Regression fence: fails against #1016, where the disk read [0] mid-request.
    func testPersistedEventsStayOnDiskUntilTheirRequestIsAnswered() async {
        let storage = InMemoryStorage()
        persist([event("a"), event("b")], in: storage)
        DiskProbeProtocol.arm(storage: storage, script: [.status(202, #"{"data":{"accepted":2}}"#)])
        let (transport, _) = makeTransport(storage: storage)

        await transport.flush()

        XCTAssertEqual(DiskProbeProtocol.diskSizesAtRequestStart, [2],
                       "a process killed while the request is in flight must find both on relaunch")
        XCTAssertEqual(onDisk(storage), [], "answered, so removed")
    }

    // Regression fence: fails against #1016 ([0, 0]). Also guards the new design: only the
    // answered request's events are removed, so the unanswered 50 stay, in order.
    func testOnlyEventsWhoseRequestWasAnsweredAreRemoved() async {
        let storage = InMemoryStorage()
        let backlog = (0..<150).map { event("e\($0)") }
        persist(backlog, in: storage)
        DiskProbeProtocol.arm(storage: storage, script: [
            .status(202, #"{"data":{"accepted":100}}"#),
            .status(500, ""),
        ])
        let (transport, _) = makeTransport(storage: storage)

        await transport.flush()

        XCTAssertEqual(DiskProbeProtocol.diskSizesAtRequestStart, [150, 50])
        XCTAssertEqual(onDisk(storage), backlog[100...].map(\.eventId))
    }

    // New-design guard: persisted events are already on disk, so a retryable failure must not
    // enqueue them a second time. Live events are persisted behind them, preserving FIFO.
    func testARetryableFailureDoesNotDuplicatePersistedEvents() async {
        let storage = InMemoryStorage()
        let backlog = [event("old_1"), event("old_2")]
        persist(backlog, in: storage)
        DiskProbeProtocol.arm(storage: storage, script: [.status(500, "")])
        let queue = EventQueue(maxSize: 1000)
        let live = event("live")
        queue.add(live)
        let (transport, _) = makeTransport(storage: storage, queue: queue)

        await transport.flush()

        XCTAssertEqual(onDisk(storage), backlog.map(\.eventId) + [live.eventId])
    }

    // New-design guard: a permanently refused request must leave disk, or it would be resent
    // on every flush forever.
    func testAPermanentlyRefusedRequestIsRemovedFromDisk() async {
        let storage = InMemoryStorage()
        persist([event("rejected_whole")], in: storage)
        DiskProbeProtocol.arm(storage: storage, script: [.status(400, #"{"error":{"code":"VALIDATION_ERROR"}}"#)])
        let (transport, _) = makeTransport(storage: storage)

        await transport.flush()
        await transport.flush()

        XCTAssertEqual(DiskProbeProtocol.diskSizesAtRequestStart.count, 1, "never resent")
        XCTAssertEqual(onDisk(storage), [])
    }

    // New-design guard: a 2xx acknowledges the whole request, including an event it rejects and
    // a request that mixes persisted and live events. The persisted one leaves disk; nothing is
    // resent.
    func testAPartiallyRejectedMixedRequestRemovesItsPersistedEventAndIsNotResent() async {
        let storage = InMemoryStorage()
        persist([event("old")], in: storage)
        DiskProbeProtocol.arm(storage: storage, script: [
            .status(202, #"{"data":{"accepted":1,"rejected":[{"index":0,"event":"old","reason":"schema"}]}}"#),
        ])
        let queue = EventQueue(maxSize: 1000)
        queue.add(event("new"))
        let (transport, _) = makeTransport(storage: storage, queue: queue)

        await transport.flush()
        await transport.flush()

        XCTAssertEqual(DiskProbeProtocol.diskSizesAtRequestStart, [1], "one request, never resent")
        XCTAssertEqual(onDisk(storage), [])
        XCTAssertEqual(queue.size(), 0)
    }
}

/// Answers from a script and, at the start of each request, records how many events a FRESH
/// `OfflineQueue` decodes from storage.
final class DiskProbeProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case status(Int, String)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var storage: InMemoryStorage?
    nonisolated(unsafe) private static var script: [Reply] = []
    nonisolated(unsafe) private static var sizes: [Int] = []

    static var diskSizesAtRequestStart: [Int] {
        lock.lock(); defer { lock.unlock() }; return sizes
    }

    static func arm(storage probed: InMemoryStorage, script replies: [Reply]) {
        lock.lock(); defer { lock.unlock() }
        storage = probed
        script = replies
        sizes = []
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        storage = nil
        script = []
        sizes = []
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "stub.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let probed = Self.storage
        let reply = Self.script.isEmpty ? Reply.status(202, #"{"data":{"accepted":0}}"#) : Self.script.removeFirst()
        Self.lock.unlock()

        let size = probed.map { OfflineQueue(storage: $0).size() } ?? -1
        Self.lock.lock()
        Self.sizes.append(size)
        Self.lock.unlock()

        switch reply {
        case .status(let code, let body):
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
