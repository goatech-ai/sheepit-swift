import XCTest
@testable import SheepitKit

/// S3c — request sizing, ingest-response handling and retry classes
/// (`Docs/Technical/PILOT_CORRECTNESS_DESIGN.md` §2.2). Each test asserts on the HTTP bodies a
/// real `Transport` + `HTTPClient` produced, or on the persisted queue, and each one failed
/// against the pre-S3c `Transport.swift`.
final class IngestResponseAndRetryTests: XCTestCase {
    override func setUp() {
        super.setUp()
        S3cScriptedProtocol.reset()
    }

    private struct Harness {
        let transport: Transport
        let queue: EventQueue
        let offline: OfflineQueue
        let bus: DiagnosticBus
    }

    private func makeHarness(
        storage: InMemoryStorage = InMemoryStorage(),
        clock: BackoffClock = BackoffClock(),
        offlineCapacity: Int = SDKDefaults.offlineQueueMax
    ) -> Harness {
        let config = SheepitConfig(
            apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))",
            apiUrl: "https://stub.invalid",
            retryAttempts: 1
        )
        let log = Logger(debug: false)
        let queue = EventQueue(maxSize: 1000)
        let bus = DiagnosticBus()
        let offline = OfflineQueue(storage: storage, maxSize: offlineCapacity, diagnostics: bus)
        let transport = Transport(
            http: HTTPClient(config: config, log: log, urlProtocolClasses: [S3cScriptedProtocol.self]),
            queue: queue,
            offlineQueue: offline,
            connectivity: ConnectivityMonitor(),
            log: log,
            diagnostics: bus,
            now: { clock.now }
        )
        return Harness(transport: transport, queue: queue, offline: offline, bus: bus)
    }

    private func event(
        _ name: String,
        properties: [String: AnyCodable]? = nil,
        userId: String? = nil,
        snapshot: TrackSnapshot? = nil
    ) -> EnrichedEvent {
        EnrichedEvent(
            eventId: UUID().uuidString,
            eventName: name,
            eventProperties: properties,
            deviceId: "device-1",
            anonymousId: "anon-1",
            sessionId: "session-1",
            userId: userId,
            platform: "ios",
            sdkVersion: SDKDefaults.sdkVersion,
            locale: "en_US",
            timezone: "UTC",
            timestamp: SheepitClient.formatEventTimestamp(Date()),
            snapshot: snapshot
        )
    }

    private func batch(_ body: Data) throws -> [[String: Any]] {
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        return try XCTUnwrap(json["batch"] as? [[String: Any]])
    }

    private func sentIds() throws -> [String?] {
        try S3cScriptedProtocol.bodies.flatMap { try batch($0) }.map { $0["event_id"] as? String }
    }

    private func diagnostics(_ harness: Harness, _ code: String) -> [DiagnosticEvent] {
        harness.bus.getRecentDiagnostics().filter { $0.code == code }
    }

    private func accepted(_ count: Int) -> S3cScriptedProtocol.Reply {
        .status(202, #"{"data":{"accepted":\#(count)}}"#, [:])
    }

    // MARK: Request sizing

    func testASessionGroupOver100IsSplitIntoRequestsOfAtMost100InOrder() async throws {
        let harness = makeHarness()
        let events = (0..<250).map { event("e\($0)") }
        events.forEach(harness.queue.add)

        await harness.transport.flush()

        XCTAssertEqual(try S3cScriptedProtocol.bodies.map { try batch($0).count }, [100, 100, 50],
                       "ingestBatchSchema.batch is max(100): one 250-event request is a 400 that drops all 250")
        XCTAssertEqual(try sentIds(), events.map { Optional($0.eventId) })
        XCTAssertEqual(harness.offline.size(), 0)
    }

    func testRequestsStayUnderTheIngestBodyLimit() async throws {
        let harness = makeHarness()
        let blob = AnyCodable(String(repeating: "x", count: 400_000))
        let events = (0..<3).map { event("e\($0)", properties: ["blob": blob]) }
        events.forEach(harness.queue.add)

        await harness.transport.flush()

        let bodies = S3cScriptedProtocol.bodies
        XCTAssertGreaterThan(bodies.count, 1)
        for body in bodies {
            XCTAssertLessThanOrEqual(body.count, 1_048_576, "Fastify's bodyLimit on /v1/ingest is a 413 for the whole request")
        }
        XCTAssertEqual(try sentIds(), events.map { Optional($0.eventId) })
    }

    // MARK: Retry classes

    func testPersistedEventsAreResentOnTheNextFlushWithoutAConnectivityChange() async throws {
        let storage = InMemoryStorage()
        let persisted = event("left_by_a_previous_process")
        OfflineQueue(storage: storage).enqueue([persisted])

        let harness = makeHarness(storage: storage)
        await harness.transport.flush()

        let wire = try batch(try XCTUnwrap(S3cScriptedProtocol.bodies.first,
                                           "ConnectivityMonitor starts online, so no offline→online callback will ever fire"))
        XCTAssertEqual(wire.first?["event_id"] as? String, persisted.eventId)
        XCTAssertEqual(wire.first?["timestamp"] as? String, persisted.timestamp)
        XCTAssertEqual(OfflineQueue(storage: storage).size(), 0)
    }

    func testServerErrorRetrySendsTheSameIdAndTimestamp() async throws {
        S3cScriptedProtocol.reset(script: [.status(500, "", [:]), accepted(1)])
        let clock = BackoffClock()
        let harness = makeHarness(clock: clock)
        let purchase = event("purchase")
        harness.queue.add(purchase)

        await harness.transport.flush()
        XCTAssertEqual(harness.offline.size(), 1, "5xx is retryable")
        clock.advance(SDKDefaults.failureBackoff(1) + 1)
        await harness.transport.flush()

        let attempts = try S3cScriptedProtocol.bodies.map { try XCTUnwrap(try batch($0).first) }
        XCTAssertEqual(attempts.count, 2)
        XCTAssertEqual(attempts.map { $0["event_id"] as? String }, [purchase.eventId, purchase.eventId])
        XCTAssertEqual(attempts.map { $0["timestamp"] as? String }, [purchase.timestamp, purchase.timestamp])
        XCTAssertEqual(harness.offline.size(), 0)
    }

    func testAServerErrorEndsTheFlushPersistsTheRestInOrderAndBacksOff() async throws {
        S3cScriptedProtocol.reset(script: [.status(500, "", [:])])
        let clock = BackoffClock()
        let harness = makeHarness(clock: clock)
        let events = (0..<250).map { event("e\($0)") }
        events.forEach(harness.queue.add)

        await harness.transport.flush()
        XCTAssertEqual(S3cScriptedProtocol.bodies.count, 1, "the other two requests would meet the same outage")
        XCTAssertEqual(harness.offline.size(), 250)

        await harness.transport.flush()
        XCTAssertEqual(S3cScriptedProtocol.bodies.count, 1, "no request inside the back-off: an outage must not be hammered")

        clock.advance(SDKDefaults.failureBackoff(1) + 1)
        await harness.transport.flush()
        let resent = try S3cScriptedProtocol.bodies.dropFirst().flatMap { try batch($0) }.map { $0["event_id"] as? String }
        XCTAssertEqual(resent, events.map { Optional($0.eventId) }, "every event, once, in order")
        XCTAssertEqual(harness.offline.size(), 0)
    }

    func testEventsTrackedDuringABackOffArePersistedByTheNextFlush() async {
        S3cScriptedProtocol.reset(script: [.status(500, "", [:])])
        let storage = InMemoryStorage()
        let harness = makeHarness(storage: storage)
        harness.queue.add(event("failed"))
        await harness.transport.flush()

        harness.queue.add(event("tracked_during_backoff_1"))
        harness.queue.add(event("tracked_during_backoff_2"))
        await harness.transport.flush() // e.g. the background flush, inside the back-off

        XCTAssertEqual(S3cScriptedProtocol.bodies.count, 1, "nothing is sent inside the back-off")
        XCTAssertEqual(OfflineQueue(storage: storage).size(), 3,
                       "an app killed during the back-off must not lose what it tracked meanwhile")
    }

    func testConcurrentFlushesAreSerializedSoTheySeeEachOthersBackOff() async {
        S3cScriptedProtocol.reset(script: [.status(500, "", [:]), .status(500, "", [:])])
        let harness = makeHarness(offlineCapacity: 3)
        (0..<5).forEach { harness.queue.add(event("e\($0)")) }

        async let first: Void = harness.transport.flush()
        async let second: Void = harness.transport.flush()
        _ = await (first, second)

        XCTAssertEqual(S3cScriptedProtocol.bodies.count, 1, "the second flush must wait and then honour the back-off")
        XCTAssertTrue(diagnostics(harness, "offline_queue.trimmed").isEmpty,
                      "interleaved flushes each counted the other's drained queue as free room")
        XCTAssertEqual(harness.offline.size() + harness.queue.size(), 5)
    }

    func testGoingOfflineWithAFullQueueDoesNotTrimPersistedEvents() async {
        let connectivity = ConnectivityMonitor()
        connectivity.setOnlineForTesting(false)
        let bus = DiagnosticBus()
        let queue = EventQueue(maxSize: 1000)
        let offline = OfflineQueue(storage: InMemoryStorage(), maxSize: 3, diagnostics: bus)
        let transport = Transport(
            http: HTTPClient(
                config: SheepitConfig(apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))", apiUrl: "https://stub.invalid"),
                log: Logger(debug: false),
                urlProtocolClasses: [S3cScriptedProtocol.self]
            ),
            queue: queue,
            offlineQueue: offline,
            connectivity: connectivity,
            log: Logger(debug: false),
            diagnostics: bus
        )
        (0..<5).forEach { queue.add(event("e\($0)")) }

        await transport.flush()

        XCTAssertEqual(offline.size(), 3)
        XCTAssertEqual(queue.size(), 2, "the rest waits in memory instead of being trimmed")
        XCTAssertFalse(bus.getRecentDiagnostics().contains { $0.code == "offline_queue.trimmed" })
        XCTAssertTrue(S3cScriptedProtocol.bodies.isEmpty)
    }

    func testAFlushNeverTakesMoreThanAFailureCouldPersist() async {
        S3cScriptedProtocol.reset(script: [.status(500, "", [:])])
        let harness = makeHarness(offlineCapacity: 3)
        (0..<5).forEach { harness.queue.add(event("e\($0)")) }

        await harness.transport.flush()

        XCTAssertEqual(harness.offline.size(), 3)
        XCTAssertEqual(harness.queue.size(), 2, "the rest waits in memory rather than being trimmed off disk")
        XCTAssertTrue(diagnostics(harness, "offline_queue.trimmed").isEmpty)
    }

    func testAnUnencodableEventIsDroppedAloneAndReported() async throws {
        let harness = makeHarness()
        let good = [event("before"), event("after")]
        harness.queue.add(good[0])
        harness.queue.add(event("broken", properties: ["value": AnyCodable(Double.nan)]))
        harness.queue.add(good[1])

        await harness.transport.flush()

        XCTAssertEqual(try sentIds(), good.map { Optional($0.eventId) })
        XCTAssertFalse(diagnostics(harness, "transport.event_unencodable").isEmpty)
        XCTAssertEqual(harness.queue.size() + harness.offline.size(), 0, "NaN can never be JSON: retrying would loop forever")
    }

    func testTheOfflineQueueStillPersistsWhenOneEventCannotBeEncoded() {
        let storage = InMemoryStorage()
        let bus = DiagnosticBus()
        let good = event("good")
        OfflineQueue(storage: storage, diagnostics: bus)
            .enqueue([event("broken", properties: ["value": AnyCodable(Double.infinity)]), good])

        XCTAssertEqual(OfflineQueue(storage: storage).drain().map(\.eventId), [good.eventId],
                       "one unencodable element used to fail the whole save silently")
        XCTAssertTrue(bus.getRecentDiagnostics().contains { $0.code == "offline_queue.unencodable_dropped" })
    }

    func testRateLimitPersistsTheEventsToDisk() async {
        S3cScriptedProtocol.reset(script: [.status(429, "", ["Retry-After": "60"])])
        let storage = InMemoryStorage()
        let harness = makeHarness(storage: storage)
        harness.queue.add(event("a"))
        harness.queue.add(event("b"))

        await harness.transport.flush()

        XCTAssertEqual(OfflineQueue(storage: storage).size(), 2,
                       "a process killed during the back-off must still have them")
        XCTAssertEqual(harness.queue.size(), 0)
    }

    func testRateLimitMidFlushPersistsTheUntriedRequestsInOrder() async throws {
        S3cScriptedProtocol.reset(script: [accepted(100), .status(429, "", ["Retry-After": "60"])])
        let storage = InMemoryStorage()
        let harness = makeHarness(storage: storage)
        let events = (0..<250).map { event("e\($0)") }
        events.forEach(harness.queue.add)

        await harness.transport.flush()

        XCTAssertEqual(S3cScriptedProtocol.bodies.count, 2, "nothing is sent after the 429")
        XCTAssertEqual(OfflineQueue(storage: storage).drain().map(\.eventId), events[100...].map(\.eventId))
        XCTAssertFalse(diagnostics(harness, "transport.rate_limited").isEmpty)
    }

    // MARK: 2xx response

    func testPartialRejectionIsReportedByEventAndNothingIsResent() async throws {
        let harness = makeHarness()
        let events = [event("a"), event("b"), event("c")]
        // The API echoes the id; compared case-insensitively since Swift mints uppercase.
        S3cScriptedProtocol.reset(script: [.status(202, """
        {"data":{"accepted":2,"rejected":[{"index":1,"event":"b","reason":"Event exceeds 32KB limit",\
        "event_id":"\(events[1].eventId.lowercased())"}]}}
        """, [:])])
        events.forEach(harness.queue.add)

        await harness.transport.flush()

        let report = try XCTUnwrap(diagnostics(harness, "transport.events_rejected").first,
                                   "rejected[] used to be discarded: silent data loss")
        XCTAssertEqual(report.data?["count"]?.value as? Int, 1)
        let rows = try XCTUnwrap(report.data?["rejections"]?.value as? [[String: Any]])
        XCTAssertEqual(rows.first?["event_id"] as? String, events[1].eventId)
        XCTAssertEqual(rows.first?["reason"] as? String, "Event exceeds 32KB limit")
        XCTAssertTrue(diagnostics(harness, "transport.rejection_unmatched").isEmpty)
        XCTAssertEqual(harness.queue.size() + harness.offline.size(), 0)

        await harness.transport.flush()
        XCTAssertEqual(S3cScriptedProtocol.bodies.count, 1, "never resend after a partial success")
    }

    func testARejectionWithoutAnEchoedIdIsMatchedByIndex() async throws {
        // An API before #995 reports index, event and reason only.
        S3cScriptedProtocol.reset(script: [.status(202, """
        {"data":{"accepted":1,"rejected":[{"index":0,"event":"a","reason":"schema"}]}}
        """, [:])])
        let harness = makeHarness()
        let events = [event("a"), event("b")]
        events.forEach(harness.queue.add)

        await harness.transport.flush()

        let report = try XCTUnwrap(diagnostics(harness, "transport.events_rejected").first)
        let rows = try XCTUnwrap(report.data?["rejections"]?.value as? [[String: Any]])
        XCTAssertEqual(rows.first?["event_id"] as? String, events[0].eventId)
        XCTAssertTrue(diagnostics(harness, "transport.rejection_unmatched").isEmpty)
    }

    func testUnmatchableRejectionsAreAcknowledgedAndReportedNotResent() async throws {
        S3cScriptedProtocol.reset(script: [.status(202, """
        {"data":{"accepted":0,"rejected":[{"index":7,"event":"a","reason":"x"},\
        {"index":0,"event":"a","reason":"x","event_id":"00000000-0000-4000-8000-000000000000"}]}}
        """, [:])])
        let harness = makeHarness()
        harness.queue.add(event("a"))
        harness.queue.add(event("b"))

        await harness.transport.flush()

        let report = try XCTUnwrap(diagnostics(harness, "transport.rejection_unmatched").first)
        XCTAssertEqual(report.data?["rejected_unmatched"]?.value as? Int, 2)
        XCTAssertTrue(diagnostics(harness, "transport.events_rejected").isEmpty,
                      "an id that disagrees with the event at that index must not be attributed to it")
        XCTAssertEqual(harness.queue.size() + harness.offline.size(), 0, "a 2xx is durable acceptance")

        await harness.transport.flush()
        XCTAssertEqual(S3cScriptedProtocol.bodies.count, 1)
    }

    func testASuccessWithAnUnreadableBodyIsTreatedAsDelivered() async {
        S3cScriptedProtocol.reset(script: [.status(200, "<html>ok</html>", [:])])
        let harness = makeHarness()
        harness.queue.add(event("a"))

        await harness.transport.flush()

        XCTAssertFalse(diagnostics(harness, "transport.ingest_response_undecodable").isEmpty)
        XCTAssertEqual(harness.queue.size() + harness.offline.size(), 0)
    }

    func testRejectionDiagnosticsAreBounded() async throws {
        let harness = makeHarness()
        let events = (0..<30).map { event("e\($0)") }
        let reason = String(repeating: "r", count: 500)
        let rejected = events.indices.map { #"{"index":\#($0),"event":"e\#($0)","reason":"\#(reason)"}"# }
        S3cScriptedProtocol.reset(script: [.status(
            202, #"{"data":{"accepted":0,"rejected":[\#(rejected.joined(separator: ","))]}}"#, [:]
        )])
        events.forEach(harness.queue.add)

        await harness.transport.flush()

        let report = try XCTUnwrap(diagnostics(harness, "transport.events_rejected").first)
        XCTAssertEqual(report.data?["count"]?.value as? Int, 30)
        XCTAssertEqual(report.data?["unreported"]?.value as? Int, 20)
        let rows = try XCTUnwrap(report.data?["rejections"]?.value as? [[String: Any]])
        XCTAssertEqual(rows.count, IngestAcknowledgement.maxReportedRejections)
        for row in rows {
            XCTAssertLessThanOrEqual((row["reason"] as? String)?.count ?? .max, IngestAcknowledgement.maxReasonLength)
        }
    }

    // MARK: Wire shape and bounds

    func testRequestsCarryNoBatchLevelContext() async throws {
        let harness = makeHarness()
        harness.queue.add(event("a"))

        await harness.transport.flush()

        let body = try XCTUnwrap(S3cScriptedProtocol.bodies.first)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(json["context"], "founder decision S3c: per-event context only")
        XCTAssertNotNil(try batch(body).first?["context"])
    }

    func testAnOverlongAppVersionIsBoundedAtCaptureAndOnTheWire() {
        let long = String(repeating: "v", count: 100)
        XCTAssertEqual(TrackSnapshot.capture(appVersion: long).appVersion?.utf16.count, 64)

        // A queue written before the capture bound existed.
        let legacy = TrackSnapshot(
            appVersion: long, appBuild: long, appNamespace: nil, buildChannel: nil,
            deviceModel: nil, osVersion: nil, osName: nil, deviceType: nil, country: nil
        )
        let app: IngestApp? = Transport.context(for: event("e", snapshot: legacy)).app
        XCTAssertEqual(app?.version?.utf16.count, 64, "ingestContextSchema.app.version is max(64)")
        XCTAssertEqual(app?.build?.utf16.count, 64)
    }

    func testAnOverlongUserIdOnAQueuedEventIsSentAnonymousNotRejected() {
        let over: IngestUser? = Transport.context(for: event("e", userId: String(repeating: "u", count: 257))).user
        XCTAssertNil(over?.id, "truncating would merge two users sharing a prefix")
        XCTAssertEqual(over?.anonymousId, "anon-1")

        let atLimit: IngestUser? = Transport.context(for: event("e", userId: String(repeating: "u", count: 256))).user
        XCTAssertEqual(atLimit?.id?.utf16.count, 256)
    }

    func testIdentifyRefusesAUserIdLongerThanTheIngestLimit() {
        let client = SheepitClient.createForTesting(
            config: SheepitConfig(
                apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))",
                apiUrl: "https://stub.invalid"
            ),
            now: { Date() },
            // The shared stub, not this suite's scripted one: the client's own background
            // requests must not land in another test's captured bodies.
            urlProtocolClasses: [StubURLProtocol.self]
        )
        defer { client.destroy() }
        let long = String(repeating: "u", count: 257)

        client.identify(userId: long)

        XCTAssertNotEqual(client.context.userId, long)
        XCTAssertTrue(client.getRecentDiagnostics().contains { $0.code == "identity.identify_rejected" })
    }

    func testRegistrationRestampReachesPersistedEvents() {
        // A 429 on the first flush now parks events on disk, out of EventQueue's restamp.
        let storage = InMemoryStorage()
        OfflineQueue(storage: storage).enqueue([event("before_registration")])

        OfflineQueue(storage: storage).restampDeviceId(from: "device-1", to: "server-device")

        XCTAssertEqual(OfflineQueue(storage: storage).drain().map(\.deviceId), ["server-device"])
    }
}

/// A settable clock for `Transport`'s back-off.
final class BackoffClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_789_000_000)

    var now: Date {
        lock.lock(); defer { lock.unlock() }; return date
    }

    func advance(_ seconds: TimeInterval) {
        lock.lock(); date = date.addingTimeInterval(seconds); lock.unlock()
    }
}

/// Records every request body and answers from a script (default: 202 accepting nothing).
final class S3cScriptedProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case status(Int, String, [String: String])
        case failure(URLError)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var script: [Reply] = []
    nonisolated(unsafe) private static var captured: [Data] = []

    static var bodies: [Data] {
        lock.lock(); defer { lock.unlock() }; return captured
    }

    static func reset(script replies: [Reply] = []) {
        lock.lock(); defer { lock.unlock() }
        script = replies
        captured = []
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "stub.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 65_536)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
        }
        Self.lock.lock()
        Self.captured.append(body)
        let reply = Self.script.isEmpty ? Reply.status(202, #"{"data":{"accepted":0}}"#, [:]) : Self.script.removeFirst()
        Self.lock.unlock()

        switch reply {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .status(let code, let responseBody, let headers):
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers)
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(responseBody.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
