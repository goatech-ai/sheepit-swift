import XCTest
@testable import SheepitKit

/// S3b — per-event identity on the wire (`Docs/Technical/PILOT_CORRECTNESS_DESIGN.md` §2.1–2.2).
///
/// Before this, `IngestEvent` carried only type/event/properties/timestamp. The `eventId`
/// minted at track time never left the device, so a resend after a lost response stored a
/// second row (PR #1011's ledger witness measured 2), and one batch context built from
/// `events[0]` discarded every later event's user and device. Every test below asserts on
/// the actual HTTP body a real `Transport` + `HTTPClient` produced, and each one failed
/// against the pre-S3b `Transport.swift`.
final class EventIdentityWireTests: XCTestCase {
    override func setUp() {
        super.setUp()
        ScriptedCaptureURLProtocol.reset()
    }

    private struct Harness {
        let transport: Transport
        let queue: EventQueue
        let offlineQueue: OfflineQueue
    }

    private func makeHarness(storage: InMemoryStorage = InMemoryStorage()) -> Harness {
        let config = SheepitConfig(
            apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))",
            apiUrl: "https://stub.invalid",
            retryAttempts: 1
        )
        let log = Logger(debug: false)
        let queue = EventQueue(maxSize: 100)
        let offlineQueue = OfflineQueue(storage: storage)
        let transport = Transport(
            http: HTTPClient(config: config, log: log, urlProtocolClasses: [ScriptedCaptureURLProtocol.self]),
            queue: queue,
            offlineQueue: offlineQueue,
            connectivity: ConnectivityMonitor(),
            log: log
        )
        return Harness(transport: transport, queue: queue, offlineQueue: offlineQueue)
    }

    private func event(
        name: String,
        user: String?,
        anonymous: String,
        device: String,
        session: String,
        timestamp: String,
        snapshot: TrackSnapshot? = nil
    ) -> EnrichedEvent {
        EnrichedEvent(
            eventId: UUID().uuidString,
            eventName: name,
            eventProperties: nil,
            deviceId: device,
            anonymousId: anonymous,
            sessionId: session,
            userId: user,
            platform: "ios",
            sdkVersion: SDKDefaults.sdkVersion,
            locale: "en_US",
            timezone: "UTC",
            timestamp: timestamp,
            snapshot: snapshot
        )
    }

    private func json(_ body: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private func wireEvents(_ body: Data) throws -> [[String: Any]] {
        try XCTUnwrap(json(body)["batch"] as? [[String: Any]])
    }

    // MARK: (a) event_id

    func testEverySerializedEventCarriesItsOwnPersistedEventId() async throws {
        let harness = makeHarness()
        let events = (0..<3).map { index in
            event(
                name: "e\(index)", user: "user-1", anonymous: "anon-1", device: "device-1",
                session: "session-1", timestamp: "2026-09-13T10:00:0\(index).000Z"
            )
        }
        for event in events { harness.queue.add(event) }

        await harness.transport.flush()

        let bodies = ScriptedCaptureURLProtocol.bodies
        XCTAssertEqual(bodies.count, 1, "one session is one request")
        let wire = try wireEvents(try XCTUnwrap(bodies.first))
        XCTAssertEqual(
            wire.map { $0["event_id"] as? String }, events.map { Optional($0.eventId) },
            "each event must send the id minted at track time — verbatim, in order"
        )
        XCTAssertEqual(wire.map { $0["timestamp"] as? String }, events.map { Optional($0.timestamp) })
    }

    // MARK: (b) per-event context

    func testMixedIdentityBatchSerializesEachEventsOwnUserDeviceAndSession() async throws {
        let harness = makeHarness()
        // The first three share a session, so the pre-S3b code sent them as ONE request
        // with ONE context taken from alice's event: bob's user and device-2 were simply
        // discarded. The anonymous event after an identified one is the REPLACE-not-merge
        // case — it must come out with no user, not with the head's.
        let events = [
            event(name: "a", user: "alice", anonymous: "anon-a", device: "device-1",
                  session: "session-1", timestamp: "2026-09-13T10:00:00.000Z"),
            event(name: "b", user: "bob", anonymous: "anon-b", device: "device-2",
                  session: "session-1", timestamp: "2026-09-13T10:00:01.000Z"),
            event(name: "c", user: nil, anonymous: "anon-c", device: "device-3",
                  session: "session-1", timestamp: "2026-09-13T10:00:02.000Z"),
            event(name: "d", user: "dana", anonymous: "anon-d", device: "device-4",
                  session: "session-2", timestamp: "2026-09-13T10:00:03.000Z"),
        ]
        for event in events { harness.queue.add(event) }

        await harness.transport.flush()

        let bodies = ScriptedCaptureURLProtocol.bodies
        var byId: [String: [String: Any]] = [:]
        for body in bodies {
            let request = try json(body)
            let wire = try wireEvents(body)
            // S3c dropped the old-API compatibility copy of the head's context.
            XCTAssertNil(request["context"], "no batch-level context: each event carries its own")
            for item in wire {
                let id = try XCTUnwrap(item["event_id"] as? String)
                byId[id] = try XCTUnwrap(item["context"] as? [String: Any], "event \(id) has no context")
            }
        }

        XCTAssertEqual(byId.count, events.count)
        for event in events {
            let context = try XCTUnwrap(byId[event.eventId], "event \(event.eventName) missing")
            let user = context["user"] as? [String: Any]
            let device = context["device"] as? [String: Any]
            let session = context["session"] as? [String: Any]
            XCTAssertEqual(user?["id"] as? String, event.userId, "user of \(event.eventName)")
            XCTAssertEqual(user?["anonymous_id"] as? String, event.anonymousId, "anonymous of \(event.eventName)")
            XCTAssertEqual(device?["id"] as? String, event.deviceId, "device of \(event.eventName)")
            XCTAssertEqual(session?["id"] as? String, event.sessionId, "session of \(event.eventName)")
        }
        XCTAssertNil(
            (byId[events[2].eventId]?["user"] as? [String: Any])?["id"],
            "an anonymous event must not inherit a user id from the batch head"
        )
    }

    // MARK: (c) queue written before snapshots existed

    func testQueuePersistedByAnOlderSDKDecodesWhollyAndFlushesWithoutInventedDimensions() async throws {
        // The exact key set `EnrichedEvent` encoded before S3b: no `snapshot`. `userId` is
        // absent (not null) on the second element, which is how synthesized Codable wrote nil.
        let legacy = """
        [
          {"eventId":"6F1C2A4E-0B1D-4C55-9E3A-1B2C3D4E5F60","eventName":"legacy_one",
           "eventProperties":{"plan":"pro"},"deviceId":"device-old","anonymousId":"anon-old",
           "sessionId":"session-old","userId":"user-old","platform":"ios","sdkVersion":"0.3.0",
           "locale":"en_US@calendar=japanese","timezone":"UTC","timestamp":"2026-09-10T08:00:00.000Z"},
          {"eventId":"7A2D3B5F-1C2E-4D66-8F4B-2C3D4E5F6071","eventName":"legacy_two",
           "deviceId":"device-old","anonymousId":"anon-old","sessionId":"session-old",
           "platform":"ios","sdkVersion":"0.3.0","locale":"es_419","timezone":"UTC",
           "timestamp":"2026-09-10T08:00:01.000Z"}
        ]
        """
        let storage = InMemoryStorage()
        storage.set(Data(legacy.utf8), forKey: StorageKeys.offlineQueue)

        let harness = makeHarness(storage: storage)
        XCTAssertEqual(harness.offlineQueue.size(), 2, "one undecodable element drops the WHOLE queue")
        for event in harness.offlineQueue.drain() { harness.queue.add(event) }

        await harness.transport.flush()

        let body = try XCTUnwrap(ScriptedCaptureURLProtocol.bodies.first)
        let wire = try wireEvents(body)
        XCTAssertEqual(wire.map { $0["event_id"] as? String }, [
            "6F1C2A4E-0B1D-4C55-9E3A-1B2C3D4E5F60", "7A2D3B5F-1C2E-4D66-8F4B-2C3D4E5F6071",
        ])
        let contexts = try wire.map { try XCTUnwrap($0["context"] as? [String: Any]) }
        for context in contexts {
            // Never recorded, so never sent — NOT filled from the macOS host running this test.
            XCTAssertNil(context["app"], "app version/build/namespace/channel were never recorded")
            let device = try XCTUnwrap(context["device"] as? [String: Any])
            for key in ["model", "os_version", "os_name", "type", "country"] {
                XCTAssertNil(device[key], "device.\(key) was never recorded for this event")
            }
            // What the old event DID record still goes out, bounded to the schema.
            XCTAssertEqual(device["id"] as? String, "device-old")
            XCTAssertEqual(device["timezone"] as? String, "UTC")
            let locale = try XCTUnwrap(device["locale"] as? String, "the event's own locale must still be sent")
            XCTAssertFalse(locale.isEmpty)
            XCTAssertLessThanOrEqual(locale.utf16.count, 16)
            XCTAssertEqual((context["sdk"] as? [String: Any])?["version"] as? String, "0.3.0")
        }
    }

    // MARK: (d) ambiguous failure → offline queue → restored resend

    func testTimeoutThenRestoredQueueResendsTheIdenticalIdAndTimestamp() async throws {
        let storage = InMemoryStorage()
        let harness = makeHarness(storage: storage)
        ScriptedCaptureURLProtocol.reset(script: [.failure(URLError(.timedOut)), .accepted])
        let original = event(
            name: "purchase", user: "user-1", anonymous: "anon-1", device: "device-1",
            session: "session-1", timestamp: "2026-09-13T10:02:00.123Z",
            snapshot: TrackSnapshot.capture(appVersion: "1.2.3")
        )
        harness.queue.add(original)

        await harness.transport.flush()
        XCTAssertEqual(harness.offlineQueue.size(), 1, "a timeout is ambiguous — keep the event")

        // A NEW harness over the same storage is the process-restart path: its OfflineQueue
        // decodes the bytes the first one wrote, and its first flush drains them (S3c).
        let restarted = makeHarness(storage: storage)
        XCTAssertEqual(restarted.offlineQueue.size(), 1)
        await restarted.transport.flush()

        let bodies = ScriptedCaptureURLProtocol.bodies
        XCTAssertEqual(bodies.count, 2)
        let first = try XCTUnwrap(try wireEvents(bodies[0]).first)
        let retry = try XCTUnwrap(try wireEvents(bodies[1]).first)
        XCTAssertEqual(first["event_id"] as? String, original.eventId)
        XCTAssertEqual(retry["event_id"] as? String, original.eventId)
        XCTAssertEqual(first["timestamp"] as? String, original.timestamp)
        XCTAssertEqual(retry["timestamp"] as? String, original.timestamp)
        let firstContext = try XCTUnwrap(first["context"] as? [String: Any])
        let retryContext = try XCTUnwrap(retry["context"] as? [String: Any])
        XCTAssertEqual(NSDictionary(dictionary: firstContext), NSDictionary(dictionary: retryContext))
        XCTAssertEqual((retryContext["app"] as? [String: Any])?["version"] as? String, "1.2.3",
                       "the retry must describe the app that TRACKED the event")
    }
}

final class TrackSnapshotTests: XCTestCase {
    func testEmptyInputBuildsAPayloadInsteadOfTrapping() {
        let payload = Transport.buildPayload([])
        XCTAssertTrue(payload.batch.isEmpty)
        XCTAssertNil(payload.context)
    }

    func testCountryCodeKeepsOnlyTwoLetterRegions() {
        XCTAssertEqual(TrackSnapshot.countryCode("AR"), "AR")
        XCTAssertNil(TrackSnapshot.countryCode("419"), "UN M.49 areas fail .length(2)")
        XCTAssertNil(TrackSnapshot.countryCode(nil))
    }

    /// Serialization-side guard, independent of `TrackSnapshot.capture`: a snapshot that
    /// somehow holds an M.49 area code (a regressed capture filter, or a queue written by a
    /// build that did not filter) must not reach the wire, where `.length(2)` 400s the group.
    func testSerializationDropsANonTwoLetterCountryEvenIfTheSnapshotHoldsOne() throws {
        let snapshot = TrackSnapshot(
            appVersion: "1.0", appBuild: "1", appNamespace: "com.example", buildChannel: "debug",
            deviceModel: "iPhone16,2", osVersion: "18.1", osName: "iOS", deviceType: "phone",
            country: "419"
        )
        let event = EnrichedEvent(
            eventId: UUID().uuidString, eventName: "e", eventProperties: nil, deviceId: "d",
            anonymousId: "a", sessionId: "s", userId: nil, platform: "ios", sdkVersion: "0.4.1",
            locale: "es_419", timezone: "UTC", timestamp: "2026-09-13T10:00:00.000Z",
            snapshot: snapshot
        )
        let body = try JSONEncoder().encode(Transport.buildPayload([event]))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let wire = try XCTUnwrap((json["batch"] as? [[String: Any]])?.first)
        XCTAssertNil(json["context"], "S3c: no batch-level context")
        for context in [wire["context"]] {
            let device = try XCTUnwrap((context as? [String: Any])?["device"] as? [String: Any])
            XCTAssertNil(device["country"], "\"419\" fails ingestContextSchema.device.country's .length(2)")
            XCTAssertEqual(device["model"] as? String, "iPhone16,2", "the rest of the snapshot still goes out")
        }
    }

    func testConfiguredAppVersionWinsOverTheBundle() {
        XCTAssertEqual(TrackSnapshot.capture(appVersion: "sha-abc").appVersion, "sha-abc")
    }

    func testWithDeviceIdCopiesTheSnapshotAndChangesOnlyTheDevice() {
        let snapshot = TrackSnapshot.capture(appVersion: "1.0")
        let event = EnrichedEvent(
            eventId: "id", eventName: "e", eventProperties: nil, deviceId: "local",
            anonymousId: "anon", sessionId: "session", userId: "user", platform: "ios",
            sdkVersion: "0.4.0", locale: "en_US", timezone: "UTC",
            timestamp: "2026-09-13T10:00:00.000Z", snapshot: snapshot
        )
        let restamped = event.withDeviceId("server")
        XCTAssertEqual(restamped.deviceId, "server")
        XCTAssertEqual(restamped.snapshot, snapshot)
        XCTAssertEqual(restamped.userId, "user")
        XCTAssertEqual(restamped.sessionId, "session")
    }
}

/// Records every request body and answers from a script (default: 202). Unlike
/// `BodyCapturingStubURLProtocol` (last body only, always 202) this can fail the first
/// attempt and accept the resend, which is the whole retry scenario.
private final class ScriptedCaptureURLProtocol: URLProtocol, @unchecked Sendable {
    enum Reply {
        case accepted
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
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
        }
        Self.lock.lock()
        Self.captured.append(body)
        let reply = Self.script.isEmpty ? Reply.accepted : Self.script.removeFirst()
        Self.lock.unlock()

        switch reply {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .accepted:
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: 202, httpVersion: "HTTP/1.1", headerFields: nil)
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"data":{"accepted":1}}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
