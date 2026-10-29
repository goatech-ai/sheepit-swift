import XCTest
@testable import SheepitKit

/// `FeedbackSender` + `PendingFeedbackStore` against `FeedbackStubProtocol`: which answers send,
/// queue or reject, `Retry-After`, the queue cap and age, and persistence across instances. The
/// clock is injected and the scheduled retry never wakes on its own (`sleep` parks until
/// cancelled), so each test drives `drain()` itself.
final class FeedbackSenderTests: XCTestCase {
    private var directory: URL!
    private var clock: LockedBox<Date>!
    private var diagnostics: DiagnosticBus!
    private var senders: [FeedbackSender] = []

    override func setUp() {
        super.setUp()
        FeedbackStubProtocol.reset()
        directory = makeTempDirectory()
        clock = LockedBox(Date(timeIntervalSince1970: 1_800_000_000))
        diagnostics = DiagnosticBus()
    }

    override func tearDown() async throws {
        for sender in senders { await sender.stop() }
        senders = []
        try? FileManager.default.removeItem(at: directory)
        FeedbackStubProtocol.reset()
        try await super.tearDown()
    }

    private func makeSender(directory: URL? = nil) -> FeedbackSender {
        let config = SheepitConfig(apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64), apiUrl: FeedbackStubProtocol.apiUrl)
        let log = Logger(debug: false)
        let clock = self.clock!
        let sender = FeedbackSender(
            http: HTTPClient(config: config, log: log, urlProtocolClasses: [FeedbackStubProtocol.self]),
            store: PendingFeedbackStore(directory: directory ?? self.directory),
            diagnostics: diagnostics,
            log: log,
            appVersionOverride: nil,
            now: { clock.get() },
            sleep: { _ in try? await Task.sleep(for: .seconds(3600)) }
        )
        senders.append(sender)
        return sender
    }

    private func submission(_ message: String = "It broke", screenshots: [SheepitFeedbackScreenshot] = []) throws -> FeedbackSubmission {
        try FeedbackValidator.build(
            message: message, type: .bug, email: nil, attributes: [:], screenshots: screenshots,
            context: FeedbackContext(deviceId: "device-1")
        ).get()
    }

    private func advance(_ seconds: TimeInterval) {
        clock.mutate { $0 = $0.addingTimeInterval(seconds) }
    }

    private func outcomes() -> [String] {
        diagnostics.getRecentDiagnostics()
            .filter { $0.code == "transport.feedback_upload" }
            .compactMap { $0.data?["outcome"]?.value as? String }
    }

    // MARK: - Answers

    func test201IsSentWithTheServerIdAndAMultipartRequest() async throws {
        let sender = makeSender()
        let png = try XCTUnwrap(SheepitFeedbackScreenshot(data: FeedbackImages.png()))
        let result = await sender.submit(try submission(screenshots: [png]))
        XCTAssertEqual(result, .sent(id: "fb-1"))
        let request = try XCTUnwrap(FeedbackStubProtocol.feedbackRequests.first)
        XCTAssertTrue(request.headers["Content-Type"]?.hasPrefix("multipart/form-data; boundary=SheepitBoundary-") == true)
        XCTAssertEqual(request.headers["Authorization"], "Bearer lp_pub_tst_" + String(repeating: "a", count: 64))
        XCTAssertEqual(try feedbackPayload(in: request.body)["message"] as? String, "It broke")
        XCTAssertNotNil(request.body.range(of: png.data), "the screenshot bytes are in the body")
        XCTAssertTrue(sender.store.entries().isEmpty)
        XCTAssertEqual(outcomes(), ["sent"])
    }

    func testNonRetryable4xxIsRejectedWithItsCodeAndNotQueued() async throws {
        let sender = makeSender()
        for status in [400, 401, 403, 404, 413, 415, 422] {
            FeedbackStubProtocol.enqueue(.status(status, body: #"{"error":{"code":"CODE_\#(status)","message":"x"}}"#))
            let result = await sender.submit(try submission())
            XCTAssertEqual(result, .rejected(.server(statusCode: status, code: "CODE_\(status)")), "\(status)")
        }
        FeedbackStubProtocol.enqueue(.status(400, body: "not json"))
        let unreadable = await sender.submit(try submission())
        XCTAssertEqual(unreadable, .rejected(.server(statusCode: 400, code: nil)))
        XCTAssertTrue(sender.store.entries().isEmpty, "a refusal is never queued")
        let notBefore = await sender.notBeforeForTesting
        XCTAssertNil(notBefore, "a refusal does not back off")
    }

    func test429WithRetryAfterQueuesAndIsRetriedOnlyAfterTheWindow() async throws {
        let sender = makeSender()
        let start = clock.get()
        FeedbackStubProtocol.enqueue(.status(429, body: #"{"error":{"code":"RATE_LIMIT_EXCEEDED"}}"#, headers: ["Retry-After": "30"]))
        let first = await sender.submit(try submission("first"))
        XCTAssertEqual(first, .queued)
        let notBefore = await sender.notBeforeForTesting
        XCTAssertEqual(notBefore, start.addingTimeInterval(30))

        // Inside the window: saved without a request, and a drain sends nothing.
        let second = await sender.submit(try submission("second"))
        XCTAssertEqual(second, .queued)
        await sender.drain()
        XCTAssertEqual(FeedbackStubProtocol.feedbackRequests.count, 1)
        XCTAssertEqual(sender.store.entries().count, 2)

        advance(31)
        await sender.drain()
        let requests = FeedbackStubProtocol.feedbackRequests
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(try requests.dropFirst().map { try feedbackPayload(in: $0.body)["message"] as? String }, ["first", "second"],
                       "oldest first")
        XCTAssertTrue(sender.store.entries().isEmpty)
        XCTAssertEqual(outcomes(), ["queued", "queued", "sent_from_queue", "sent_from_queue"])
    }

    func testRetryAfterIsClampedAndA5xxWithoutOneBacksOffFiveSeconds() async throws {
        let sender = makeSender()
        let start = clock.get()
        FeedbackStubProtocol.enqueue(.status(503, headers: ["Retry-After": "999999"]))
        _ = await sender.submit(try submission())
        let clamped = await sender.notBeforeForTesting
        XCTAssertEqual(clamped, start.addingTimeInterval(FeedbackSender.retryAfterCeiling))

        // Another scope: the first sender's floor is saved in its own directory and would apply here.
        let fresh = makeSender(directory: directory.appendingPathComponent("other", isDirectory: true))
        FeedbackStubProtocol.enqueue(.status(500))
        let result = await fresh.submit(try submission())
        XCTAssertEqual(result, .queued)
        let backoff = await fresh.notBeforeForTesting
        XCTAssertEqual(backoff, start.addingTimeInterval(SDKDefaults.failureBackoff(1)))
    }

    func testANetworkErrorQueuesAndA408Queues() async throws {
        let sender = makeSender()
        FeedbackStubProtocol.enqueue(.failure(URLError(.notConnectedToInternet)))
        let offline = await sender.submit(try submission())
        XCTAssertEqual(offline, .queued)
        advance(3600)
        FeedbackStubProtocol.enqueue(.status(408))
        await sender.drain()
        XCTAssertEqual(sender.store.entries().count, 1, "a 408 keeps the item")
    }

    // MARK: - Queue

    func testTheQueueKeepsTheNewestTenItems() async throws {
        let sender = makeSender()
        FeedbackStubProtocol.enqueue(.status(503, headers: ["Retry-After": "3600"]))
        for index in 0..<12 {
            advance(1)
            let result = await sender.submit(try submission("m\(index)"))
            XCTAssertEqual(result, .queued)
        }
        let entries = sender.store.entries()
        XCTAssertEqual(entries.count, FeedbackSender.maxItems)
        let messages = try entries.map { entry -> String? in
            let loaded = try XCTUnwrap(sender.store.load(entry))
            let json = try JSONSerialization.jsonObject(with: loaded.payload) as? [String: Any]
            return json?["message"] as? String
        }
        XCTAssertEqual(messages, (2..<12).map { "m\($0)" })
        XCTAssertEqual(outcomes().filter { $0 == "dropped_queue_full" }.count, 2)
    }

    func testQueuedFeedbackSurvivesANewSenderWithItsScreenshots() async throws {
        let png = try XCTUnwrap(SheepitFeedbackScreenshot(data: FeedbackImages.png()))
        let jpeg = try XCTUnwrap(SheepitFeedbackScreenshot(data: FeedbackImages.jpeg()))
        let first = makeSender()
        FeedbackStubProtocol.enqueue(.status(503, headers: ["Retry-After": "60"]))
        let queued = await first.submit(try submission("persisted", screenshots: [png, jpeg]))
        XCTAssertEqual(queued, .queued)
        await first.stop()

        // The retry floor is on disk: a new sender inside the window sends nothing.
        let second = makeSender()
        await second.drain()
        XCTAssertEqual(FeedbackStubProtocol.feedbackRequests.count, 1, "Retry-After survives a relaunch")
        let floor = await second.notBeforeForTesting
        XCTAssertEqual(floor, clock.get().addingTimeInterval(60))

        advance(61)
        await second.drain()
        let request = try XCTUnwrap(FeedbackStubProtocol.feedbackRequests.last)
        XCTAssertEqual(FeedbackStubProtocol.feedbackRequests.count, 2)
        XCTAssertEqual(try feedbackPayload(in: request.body)["message"] as? String, "persisted")
        let pngRange = try XCTUnwrap(request.body.range(of: png.data))
        let jpegRange = try XCTUnwrap(request.body.range(of: jpeg.data))
        XCTAssertLessThan(pngRange.lowerBound, jpegRange.lowerBound, "screenshot order is kept")
        XCTAssertTrue(second.store.entries().isEmpty)
    }

    func testDrainDropsExpiredItemsAndItemsTheServerRefuses() async throws {
        let sender = makeSender()
        FeedbackStubProtocol.enqueue(.status(503, headers: ["Retry-After": "1"]))
        _ = await sender.submit(try submission("old"))
        advance(FeedbackSender.maxAge + 1)
        FeedbackStubProtocol.enqueue(.status(503, headers: ["Retry-After": "1"]))
        let queued = await sender.submit(try submission("refused"))
        XCTAssertEqual(queued, .queued)
        advance(2)
        FeedbackStubProtocol.enqueue(.status(400))
        await sender.drain()
        XCTAssertEqual(FeedbackStubProtocol.feedbackRequests.count, 3, "the expired item is dropped without a request")
        XCTAssertTrue(sender.store.entries().isEmpty)
        XCTAssertTrue(outcomes().contains("dropped_expired"))
        XCTAssertTrue(outcomes().contains("dropped_rejected"))
    }

    func testClearDeletesTheQueueAndAWriteStartedBeforeItIsDropped() throws {
        let store = PendingFeedbackStore(directory: directory)
        let generation = store.generation
        XCTAssertNotNil(store.enqueue(try submission(), now: clock.get(), ifGeneration: generation, maxItems: 10).entry)
        store.clear()
        XCTAssertTrue(store.entries().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertNil(store.enqueue(try submission(), now: clock.get(), ifGeneration: generation, maxItems: 10).entry,
                     "a write that read the generation before clear() is not written")
        XCTAssertNotNil(store.enqueue(try submission(), now: clock.get(), ifGeneration: store.generation, maxItems: 10).entry)
    }

    func testASuccessClearsTheSavedFloor() async throws {
        let sender = makeSender()
        FeedbackStubProtocol.enqueue(.status(429, headers: ["Retry-After": "5"]))
        _ = await sender.submit(try submission())
        XCTAssertNotNil(sender.store.loadNotBefore())
        advance(6)
        await sender.drain()
        XCTAssertNil(sender.store.loadNotBefore())
        let floor = await makeSender().notBeforeForTesting
        XCTAssertNil(floor)
    }

    func testDroppingTheLastQueuedItemClearsAnOld429Floor() async throws {
        let sender = makeSender()
        FeedbackStubProtocol.enqueue(.status(429, headers: ["Retry-After": "5"]))
        _ = await sender.submit(try submission("refused later"))
        advance(6)
        FeedbackStubProtocol.enqueue(.status(400))
        await sender.drain()
        XCTAssertTrue(sender.store.entries().isEmpty)
        XCTAssertNil(sender.store.loadNotBefore(), "the saved floor goes with the last item")

        // The failure count is reset too: the next 5xx waits the first step, not the second.
        let start = clock.get()
        FeedbackStubProtocol.enqueue(.status(503))
        _ = await sender.submit(try submission("fresh"))
        let floor = await sender.notBeforeForTesting
        XCTAssertEqual(floor, start.addingTimeInterval(SDKDefaults.failureBackoff(1)))
    }

    func testOnlyOneRequestIsEverInFlight() async throws {
        let sender = makeSender()
        // One item waiting in the queue, so a drain and new submissions compete for the gate.
        FeedbackStubProtocol.enqueue(.status(503, headers: ["Retry-After": "1"]))
        _ = await sender.submit(try submission("queued"))
        advance(2)
        FeedbackStubProtocol.responseDelay = 0.15

        let (first, second, third) = (try submission("a"), try submission("b"), try submission("c"))
        async let drained: Void = sender.drain()
        async let a = sender.submit(first)
        async let b = sender.submit(second)
        async let c = sender.submit(third)
        let results = await [a, b, c]
        await drained
        // A submission that found the gate busy was saved, not parked; a last drain sends any the
        // first one finished before.
        await sender.drain()

        XCTAssertTrue(results.allSatisfy { result in
            if case .rejected = result { return false } else { return true }
        }, "\(results)")
        XCTAssertEqual(FeedbackStubProtocol.feedbackRequests.count, 5, "each item sent exactly once")
        XCTAssertEqual(FeedbackStubProtocol.maxInFlight, 1, "submit and drain share one send gate")
        XCTAssertTrue(sender.store.entries().isEmpty)
    }

    func testStrandedScopesAreReapedOnlyWhenNothingInThemCanStillBeSent() throws {
        let base = directory.appendingPathComponent("base", isDirectory: true)
        let now = clock.get()
        func scope(_ name: String, itemAge: TimeInterval?) throws -> URL {
            let store = PendingFeedbackStore(directory: base.appendingPathComponent(name, isDirectory: true))
            try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
            if let itemAge {
                XCTAssertNotNil(store.enqueue(try submission(), now: now.addingTimeInterval(-itemAge),
                                              ifGeneration: store.generation, maxItems: 10).entry)
            }
            return store.directory
        }
        let stale = try scope("stale", itemAge: FeedbackSender.maxAge + 60)
        let empty = try scope("empty", itemAge: nil)
        let fresh = try scope("fresh", itemAge: 60)
        let writing = try scope("writing", itemAge: FeedbackSender.maxAge + 60)
        try FileManager.default.createDirectory(at: writing.appendingPathComponent(".tmp-x"), withIntermediateDirectories: true)
        let own = try scope("own", itemAge: FeedbackSender.maxAge + 60)

        let store = PendingFeedbackStore(directory: own, baseDirectory: base)
        XCTAssertEqual(Set(store.reapStrandedScopes(now: now, maxAge: FeedbackSender.maxAge)), ["stale", "empty"])
        let exists = { (url: URL) in FileManager.default.fileExists(atPath: url.path) }
        XCTAssertFalse(exists(stale))
        XCTAssertFalse(exists(empty))
        XCTAssertTrue(exists(fresh), "an item another key can still send is kept")
        XCTAssertTrue(exists(writing), "a write in progress is left alone")
        XCTAssertTrue(exists(own), "the active scope ages its own items in drain()")

        store.clear()
        XCTAssertFalse(exists(base), "clear() with a base directory forgets every scope")
    }

    func testAStoppedSenderRejectsAndAStrayFileIsCleanedUp() async throws {
        try FileManager.default.createDirectory(at: directory.appendingPathComponent(".tmp-stale"), withIntermediateDirectories: true)
        let sender = makeSender()
        XCTAssertTrue(sender.store.entries().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".tmp-stale").path))
        await sender.stop()
        let result = await sender.submit(try submission())
        XCTAssertEqual(result, .rejected(.clientUnavailable))
    }
}
