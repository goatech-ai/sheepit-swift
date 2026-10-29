import XCTest
@testable import SheepitKit

/// `submitFeedback` through a STARTED client: what the payload carries from the client, an inert
/// or destroyed client, `reset()` clearing the queue, delivery on the next launch, and the per-scope
/// queue. Also the single-slash `redactingUserinfo` fix. Network: `FeedbackStubProtocol`.
final class FeedbackClientTests: XCTestCase {
    private var directory: URL!
    private static let keyA = "lp_pub_tst_" + String(repeating: "a", count: 64)
    private static let keyB = "lp_pub_tst_" + String(repeating: "b", count: 64)

    override func setUp() {
        super.setUp()
        SharedSDKStorage.clear()
        FeedbackStubProtocol.reset()
        TeardownFlushes.install()
        directory = makeTempDirectory()
    }

    override func tearDown() async throws {
        await TeardownFlushes.drain(context: name)
        SharedSDKStorage.clear()
        FeedbackStubProtocol.reset()
        try? FileManager.default.removeItem(at: directory)
        try await super.tearDown()
    }

    private let clock = LockedBox(Date())

    private func makeClient(apiKey: String = keyA) -> SheepitClient {
        SheepitClient.createForTesting(
            config: SheepitConfig(
                apiKey: apiKey,
                apiUrl: FeedbackStubProtocol.apiUrl,
                flushInterval: 3600,
                flushSize: 1000,
                configRefreshInterval: 3600,
                retryAttempts: 1,
                performance: PerformanceConfig(enabled: false),
                // 🔴 Real signal handlers in the test process kill whichever test runs next.
                crashes: CrashConfig(enabled: false)
            ),
            now: { [clock] in clock.get() },
            urlProtocolClasses: [FeedbackStubProtocol.self],
            feedbackDirectory: directory
        )
    }

    private func scopeDirectory(_ apiKey: String) -> URL {
        let config = SheepitConfig(apiKey: apiKey, apiUrl: FeedbackStubProtocol.apiUrl)
        return directory.appendingPathComponent(StorageScope.hash(for: config), isDirectory: true)
    }

    private func queuedCount(_ apiKey: String) -> Int {
        PendingFeedbackStore(directory: scopeDirectory(apiKey)).entries().count
    }

    func testThePayloadCarriesTheClientsContext() async throws {
        let client = makeClient()
        defer { client.destroy() }
        client.identify(userId: "user-7")
        client.screen("Checkout")

        let result = await client.submitFeedback(message: "Export does nothing", type: .feature, attributes: ["plan": "pro"])
        XCTAssertEqual(result, .sent(id: "fb-1"))
        let json = try feedbackPayload(in: try XCTUnwrap(FeedbackStubProtocol.feedbackRequests.first).body)
        XCTAssertEqual(json["message"] as? String, "Export does nothing")
        XCTAssertEqual(json["type"] as? String, "feature")
        XCTAssertEqual(json["user_id"] as? String, "user-7")
        XCTAssertEqual(json["device_id"] as? String, client.status().deviceId)
        XCTAssertEqual(json["session_id"] as? String, client.context.sessionId)
        XCTAssertNil(json["email"], "the SDK never fills in an email")
        XCTAssertEqual((json["attributes"] as? [String: String])?["plan"], "pro")
        let context = try XCTUnwrap(json["context"] as? [String: String])
        XCTAssertEqual(context["screen"], "Checkout")
        XCTAssertEqual(context["sdk_name"], SDKDefaults.sdkName)
        XCTAssertEqual(context["sdk_version"], SDKDefaults.sdkVersion)
        XCTAssertEqual(context["platform"], DeviceProfile.platform)
        XCTAssertNotNil(context["os_version"])
        XCTAssertNotNil(context["device_model"])
    }

    func testAValidationFailureSendsNothing() async {
        let client = makeClient()
        defer { client.destroy() }
        let result = await client.submitFeedback(message: " ")
        XCTAssertEqual(result, .rejected(.emptyMessage))
        XCTAssertTrue(FeedbackStubProtocol.feedbackRequests.isEmpty)
        XCTAssertTrue(client.getRecentDiagnostics().contains {
            $0.code == "transport.feedback_upload" && $0.data?["outcome"]?.value as? String == "invalid"
        })
    }

    func testAnInertOrDestroyedClientRejectsAndWritesNothing() async {
        let inert = SheepitClient.createForTesting(
            config: SheepitConfig(apiKey: "lp_dev_tst_" + String(repeating: "a", count: 64), apiUrl: FeedbackStubProtocol.apiUrl,
                                  crashes: CrashConfig(enabled: false)),
            now: { Date() },
            urlProtocolClasses: [FeedbackStubProtocol.self],
            feedbackDirectory: directory
        )
        let inertResult = await inert.submitFeedback(message: "hello")
        XCTAssertEqual(inertResult, .rejected(.clientUnavailable))

        let client = makeClient()
        client.destroy()
        let destroyedResult = await client.submitFeedback(message: "hello")
        XCTAssertEqual(destroyedResult, .rejected(.clientUnavailable))
        XCTAssertTrue(FeedbackStubProtocol.feedbackRequests.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path), "no queue directory was created")
    }

    func testResetDeletesQueuedFeedbackAtOnce() async {
        let client = makeClient()
        defer { client.destroy() }
        FeedbackStubProtocol.enqueue(.status(503, headers: ["Retry-After": "3600"]))
        let result = await client.submitFeedback(message: "written before logout", email: "jane@example.com")
        XCTAssertEqual(result, .queued)
        XCTAssertEqual(queuedCount(Self.keyA), 1)

        client.reset()
        XCTAssertEqual(queuedCount(Self.keyA), 0, "synchronous: a kill right after logout leaves nothing behind")
    }

    func testQueuedFeedbackIsSentByTheNextClient() async throws {
        let first = makeClient()
        FeedbackStubProtocol.enqueue(.status(503, headers: ["Retry-After": "3600"]))
        let queued = await first.submitFeedback(message: "from the last launch")
        XCTAssertEqual(queued, .queued)
        first.destroy()
        XCTAssertEqual(queuedCount(Self.keyA), 1, "destroy() keeps the queue")

        // Inside the saved Retry-After window, the next launch sends nothing.
        let early = makeClient()
        await early.feedbackSender.drain()
        early.destroy()
        XCTAssertEqual(FeedbackStubProtocol.feedbackRequests.count, 1, "Retry-After survives a relaunch")
        XCTAssertEqual(queuedCount(Self.keyA), 1)

        clock.mutate { $0 = $0.addingTimeInterval(3601) }
        let second = makeClient()
        defer { second.destroy() }
        // `start()` drains in the background; this waits for that drain (or runs it if it has not).
        await second.feedbackSender.drain()
        let deadline = Date().addingTimeInterval(5)
        while queuedCount(Self.keyA) > 0, Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(queuedCount(Self.keyA), 0)
        XCTAssertEqual(try feedbackPayload(in: try XCTUnwrap(FeedbackStubProtocol.feedbackRequests.last).body)["message"] as? String,
                       "from the last launch")
    }

    func testResetForgetsEveryKeysQueue() async {
        let clientA = makeClient(apiKey: Self.keyA)
        FeedbackStubProtocol.enqueue(.status(503, headers: ["Retry-After": "3600"]))
        _ = await clientA.submitFeedback(message: "under key A")
        clientA.destroy()
        XCTAssertEqual(queuedCount(Self.keyA), 1)

        let clientB = makeClient(apiKey: Self.keyB)
        defer { clientB.destroy() }
        clientB.reset()
        XCTAssertEqual(queuedCount(Self.keyA), 0, "reset() under key B deletes key A's queue too")
    }

    func testAStrandedScopeIsDeletedAtStartOnceItIsOlderThanSevenDays() async throws {
        let clientA = makeClient(apiKey: Self.keyA)
        FeedbackStubProtocol.enqueue(.status(503, headers: ["Retry-After": "3600"]))
        _ = await clientA.submitFeedback(message: "under a key that is rotated away")
        clientA.destroy()

        let fresh = makeClient(apiKey: Self.keyB)
        await fresh.feedbackSender.drain()
        fresh.destroy()
        XCTAssertEqual(queuedCount(Self.keyA), 1, "not yet 7 days old: kept")

        clock.mutate { $0 = $0.addingTimeInterval(FeedbackSender.maxAge + 60) }
        let later = makeClient(apiKey: Self.keyB)
        defer { later.destroy() }
        let deadline = Date().addingTimeInterval(5)
        while FileManager.default.fileExists(atPath: scopeDirectory(Self.keyA).path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: scopeDirectory(Self.keyA).path))
    }

    func testTheValidationDiagnosticNamesTheRuleNotTheKey() async {
        let client = makeClient()
        defer { client.destroy() }
        let result = await client.submitFeedback(message: "hi", attributes: ["bad key": true])
        XCTAssertEqual(result, .rejected(.invalidAttribute(key: "bad key")))
        let reasons = client.getRecentDiagnostics()
            .filter { $0.code == "transport.feedback_upload" }
            .compactMap { $0.data?["reason"]?.value as? String }
        XCTAssertEqual(reasons, ["invalid_attribute"])
    }

    func testAnotherKeysClientNeverSendsThisKeysQueue() async {
        let clientA = makeClient(apiKey: Self.keyA)
        FeedbackStubProtocol.enqueue(.status(503, headers: ["Retry-After": "3600"]))
        _ = await clientA.submitFeedback(message: "for key A")
        clientA.destroy()

        let clientB = makeClient(apiKey: Self.keyB)
        defer { clientB.destroy() }
        await clientB.feedbackSender.drain()
        XCTAssertEqual(FeedbackStubProtocol.feedbackRequests.count, 1, "only key A's own attempt")
        XCTAssertEqual(queuedCount(Self.keyA), 1)
        XCTAssertEqual(queuedCount(Self.keyB), 0)
        XCTAssertNotEqual(scopeDirectory(Self.keyA), scopeDirectory(Self.keyB))
    }

    // MARK: - redactingUserinfo, single-slash form (PENDING_WORK 2026-09-29, found in the #1163 review)

    func testTheSingleSlashFormHasItsUserinfoRedacted() throws {
        let reason = try XCTUnwrap(SheepitClient.apiURLRejectionReason(for: "https:/admin:s3cret@gw.internal.corp"),
                                   "a single-slash URL has no host, so it is rejected")
        XCTAssertFalse(reason.contains("s3cret"), reason)
        XCTAssertFalse(reason.contains("admin"), reason)
        XCTAssertTrue(reason.contains("https:/gw.internal.corp"), reason)
    }

    func testRedactionLeavesPathsAloneAndStillCoversTheOtherForms() {
        XCTAssertEqual(SheepitClient.redactingUserinfo(from: "https://user:p@ss@host"), "https://host")
        XCTAssertEqual(SheepitClient.redactingUserinfo(from: "user:sup3rs3cret@api.example.com"), "api.example.com")
        XCTAssertEqual(SheepitClient.redactingUserinfo(from: "https://host/users/jane@example.com"),
                       "https://host/users/jane@example.com", "an @ in a path is not userinfo")
        XCTAssertEqual(SheepitClient.redactingUserinfo(from: "https:/host/a@b"), "https:/host/a@b")
    }
}
