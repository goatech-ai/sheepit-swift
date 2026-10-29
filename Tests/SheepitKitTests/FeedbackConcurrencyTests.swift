import XCTest
@testable import SheepitKit

/// Races between two clients' feedback queues in one process (each client builds its own
/// `PendingFeedbackStore`): `reset()` against another client's write, the start-time reaper
/// against a live client's enqueue, and submissions while a send is stalled.
final class FeedbackConcurrencyTests: XCTestCase {
    private var base: URL!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUp() {
        super.setUp()
        FeedbackStubProtocol.reset()
        base = makeTempDirectory()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: base)
        FeedbackStubProtocol.reset()
        try await super.tearDown()
    }

    private func store(_ scope: String) -> PendingFeedbackStore {
        PendingFeedbackStore(directory: base.appendingPathComponent(scope, isDirectory: true), baseDirectory: base)
    }

    private func submission(_ message: String = "It broke") throws -> FeedbackSubmission {
        try FeedbackValidator.build(
            message: message, type: .bug, email: nil, attributes: [:], screenshots: [], context: FeedbackContext()
        ).get()
    }

    // (a) Client B's reset() must stop client A's write that began before it.

    func testAnotherClientsResetStopsThisClientsPendingWrite() throws {
        let storeA = store("a")
        let storeB = store("b")
        let generation = storeA.generation   // A reads it, then its request goes out
        storeB.clear()                       // B logs out meanwhile
        XCTAssertNil(storeA.enqueue(try submission(), now: now, ifGeneration: generation, maxItems: 10).entry,
                     "A's late retry must not resurrect the logged-out user's feedback")
        storeA.saveNotBefore(now.addingTimeInterval(60), ifGeneration: generation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path), "nothing was recreated")
    }

    func testResetsRacingWritesNeverLeaveAnItemWrittenBeforeTheLastReset() throws {
        let storeA = store("a")
        let storeB = store("b")
        let payload = try submission()
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            for _ in 0..<300 {
                let generation = storeA.generation
                _ = storeA.enqueue(payload, now: self.now, ifGeneration: generation, maxItems: 10)
            }
        }
        DispatchQueue.global().async(group: group) {
            for _ in 0..<300 { storeB.clear() }
        }
        group.wait()
        let afterLastReset = storeA.generation
        storeB.clear()
        XCTAssertNil(storeA.enqueue(payload, now: now, ifGeneration: afterLastReset, maxItems: 10).entry)
        XCTAssertTrue(storeA.entries().isEmpty)
    }

    // (b) + (c) The reaper must never delete a live scope between its createDirectory and rename,
    // nor between the reaper's own listing and its delete.

    func testTheReaperNeverBreaksOrLosesALiveClientsWrite() throws {
        let live = store("live")
        let reaper = store("reaper")
        let payload = try submission()
        let failures = LockedBox(0)
        let lost = LockedBox(0)
        let done = LockedBox(false)
        let group = DispatchGroup()
        DispatchQueue.global().async(group: group) {
            for _ in 0..<1500 {
                guard let entry = live.enqueue(payload, now: self.now, ifGeneration: live.generation, maxItems: 10).entry else {
                    failures.mutate { $0 += 1 }
                    continue
                }
                if !FileManager.default.fileExists(atPath: entry.url.path) { lost.mutate { $0 += 1 } }
                // Leave the directory empty again, the state the reaper deletes.
                live.remove(entry)
            }
            done.set(true)
        }
        DispatchQueue.global().async(group: group) {
            while !done.get() { reaper.reapStrandedScopes(now: self.now, maxAge: FeedbackSender.maxAge) }
        }
        group.wait()
        XCTAssertEqual(failures.get(), 0, "an enqueue failed: its directory was deleted mid-write")
        XCTAssertEqual(lost.get(), 0, "an item reported written was deleted by the reaper")
    }

    // Submissions while a send is stalled are saved at once, never parked.

    func testSubmissionsDuringAStalledSendAreQueuedAtOnceUnderTheCap() async throws {
        let config = SheepitConfig(apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64), apiUrl: FeedbackStubProtocol.apiUrl)
        let log = Logger(debug: false)
        let sender = FeedbackSender(
            http: HTTPClient(config: config, log: log, urlProtocolClasses: [FeedbackStubProtocol.self]),
            store: PendingFeedbackStore(directory: base.appendingPathComponent("s", isDirectory: true)),
            diagnostics: DiagnosticBus(),
            log: log,
            appVersionOverride: nil,
            sleep: { _ in try? await Task.sleep(for: .seconds(3600)) }
        )
        FeedbackStubProtocol.responseDelay = 1.0
        let stalled = Task { await sender.submit(try submission("stalled")) }
        let deadline = Date().addingTimeInterval(5)
        while FeedbackStubProtocol.feedbackRequests.isEmpty, Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(FeedbackStubProtocol.feedbackRequests.count, 1)

        let started = Date()
        for index in 0..<20 {
            let result = await sender.submit(try submission("m\(index)"))
            XCTAssertEqual(result, .queued)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.8, "no caller waited for the stalled request")
        XCTAssertEqual(sender.store.entries().count, FeedbackSender.maxItems)
        XCTAssertEqual(FeedbackStubProtocol.feedbackRequests.count, 1, "nothing else went out meanwhile")

        let first = try await stalled.value
        XCTAssertEqual(first, .sent(id: "fb-1"))
        FeedbackStubProtocol.responseDelay = 0
        await sender.drain()
        XCTAssertEqual(FeedbackStubProtocol.maxInFlight, 1)
        XCTAssertTrue(sender.store.entries().isEmpty)
        await sender.stop()
    }
}
