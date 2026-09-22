import XCTest
@testable import SheepitKit

/// S3d — experiment attribution through the real `ConfigSync` and `SheepitClient` (ingest
/// correctness design §2.3). Every assertion reads the HTTP body a real `Transport` sent.
///
/// 🔴 Isolation: `SheepitClient` hardcodes its `UserDefaults` suite, and another suite leaving a
/// cached config there made a client apply `{"experiments":{}}` over a seeded assignment
/// mid-test. `setUp`/`tearDown` clear every key this file depends on, and seeding tests wait for
/// the start-up fetch (which follows the cache load) before seeding.
final class ExperimentAttributionClientTests: XCTestCase {
    private static let suite = "ai.goatech.sdk"
    private typealias Labelled = (identity: ConfigIdentity, epoch: UInt64)

    private static func clearAttributionStorage() {
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        for key in [StorageKeys.sdkConfig, StorageKeys.sdkConfigCachedAt,
                    StorageKeys.sdkConfigFetchedUnder, StorageKeys.serverHeldUser,
                    // A persisted identity makes every later client in the process re-POST it at
                    // launch, which keeps config work in flight into other suites' tests.
                    StorageKeys.identity] {
            defaults.removeObject(forKey: key)
        }
    }

    override func setUp() {
        super.setUp()
        Self.clearAttributionStorage()
        AttributionCaptureProtocol.reset()
    }

    override func tearDown() {
        Self.clearAttributionStorage()
        AttributionCaptureProtocol.reset()
        super.tearDown()
    }

    private static let configBody = #"""
    {"data":{"config_version":"7","etag":"\"v7\"","flags":{},"experiments":{
      "pricing_test":{"variant_key":"treatment","payload":{},"experiment_id":"11111111-1111-4111-8111-111111111111","subject_kind":"user","bucketing_version":1,"assignment_revision":"7"},
      "onboarding_test":{"variant_key":"b","payload":{},"experiment_id":"22222222-2222-4222-8222-222222222222","subject_kind":"device","bucketing_version":1,"assignment_revision":"7"}}}}
    """#

    private static func configBody(variant: String) -> String {
        #"{"data":{"config_version":"7","etag":"\"v7\"","flags":{},"experiments":{"pricing_test":"#
            + #"{"variant_key":"\#(variant)","payload":{}}}}}"#
    }

    private func sdkAssignment(_ variant: String, kind: String) throws -> SDKExperimentAssignment {
        let json = #"{"variant_key":"\#(variant)","payload":{},"experiment_id":"11111111-1111-4111-8111-111111111111","#
            + #""subject_kind":"\#(kind)","bucketing_version":1,"assignment_revision":"7"}"#
        return try JSONDecoder().decode(SDKExperimentAssignment.self, from: Data(json.utf8))
    }

    private func makeClient(retryAttempts: Int = 1) -> SheepitClient {
        SheepitClient.createForTesting(
            config: SheepitConfig(
                apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64),
                apiUrl: "https://stub.invalid",
                flushInterval: 3600,
                flushSize: 1000,
                configRefreshInterval: 3600,
                retryAttempts: retryAttempts,
                // 🔴 A client with crash reporting on installs real signal handlers into the test
                // process, which then dies with signal 11 in whichever test runs next.
                crashes: CrashConfig(enabled: false)
            ),
            now: { Date() },
            urlProtocolClasses: [AttributionCaptureProtocol.self]
        )
    }

    private func makeSync(
        storage: StorageProvider,
        identity: @escaping @Sendable () -> (identity: ConfigIdentity, epoch: UInt64),
        recorded: LockedBox<[ConfigIdentity]>,
        variants: LockedBox<[String]>? = nil
    ) -> ConfigSync {
        ConfigSync(
            http: HTTPClient(
                config: SheepitConfig(apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64),
                                      apiUrl: "https://stub.invalid", retryAttempts: 1),
                log: Logger(debug: false),
                urlProtocolClasses: [AttributionCaptureProtocol.self]),
            storage: storage,
            refreshInterval: 3600,
            log: Logger(debug: false),
            identityProvider: identity,
            onConfig: { response, identity in
                recorded.mutate { $0.append(identity) }
                if let variant = response.experiments["pricing_test"]?.variantKey {
                    variants?.mutate { $0.append(variant) }
                }
            }
        )
    }

    private func uniqueName(_ prefix: String) -> String {
        "\(prefix)_\(UUID().uuidString.prefix(8))"
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// The cache load precedes the start-up fetch, so once that fetch was seen nothing from disk
    /// can still overwrite a seeded assignment.
    private func waitForStartupFetch() async {
        let seen = await waitUntil { AttributionCaptureProtocol.configRequestCount >= 1 }
        XCTAssertTrue(seen, "precondition: the start-up config fetch ran")
    }

    private func context(of name: String) throws -> [String: Any] {
        let event = try XCTUnwrap(AttributionCaptureProtocol.event(named: name), "\(name) was never sent")
        return try XCTUnwrap(event["context"] as? [String: Any])
    }

    private func entries(_ context: [String: Any]) -> [String: [String: Any]] {
        context["experiment_assignments"] as? [String: [String: Any]] ?? [:]
    }

    private func experiments(_ context: [String: Any]) -> [String: Any] {
        context["experiments"] as? [String: Any] ?? [:]
    }

    /// The user-bucketed `pricing_test` went out unattributed, and device bucketing did not.
    private func assertUserEntryMarked(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let sent = try context(of: name)
        XCTAssertNil(experiments(sent)["pricing_test"], "\(name): must not be credited to an arm", file: file, line: line)
        XCTAssertEqual(entries(sent)["pricing_test"]?["subject_status"] as? String, "identity_changed",
                       name, file: file, line: line)
        XCTAssertEqual(experiments(sent)["onboarding_test"] as? String, "b",
                       "\(name): device bucketing is unaffected", file: file, line: line)
    }

    private func persistedLabel(_ storage: StorageProvider) -> ServerHeldUser? {
        storage.data(forKey: StorageKeys.sdkConfigFetchedUnder)
            .flatMap { try? JSONDecoder().decode(ServerHeldUser.self, from: $0) }
    }

    // MARK: - ConfigSync

    func testConfigIsLabelledWithTheIdentityAtRequestStartNotAtApply() async {
        let current = LockedBox<ConfigIdentity>(.fetchedUnder("user-a"))
        let recorded = LockedBox<[ConfigIdentity]>([])
        AttributionCaptureProtocol.serveConfig(Self.configBody)
        AttributionCaptureProtocol.onConfigRequest = { current.set(.fetchedUnder("user-b")) }
        let sync = makeSync(storage: InMemoryStorage(), identity: { (current.get(), 0) }, recorded: recorded)

        await sync.refresh(deviceId: "device-1")

        XCTAssertEqual(current.get(), .fetchedUnder("user-b"), "precondition: the identity changed mid-request")
        XCTAssertEqual(recorded.get(), [.fetchedUnder("user-a")])
    }

    /// A label decision (identify, a POST answering, a device id adopted) landing while a fetch is
    /// on the wire: the body is still applied, but as unknown, and its ETag is not kept.
    func testAResponseThatOutlivesALabelChangeIsAppliedUnknownWithoutItsETag() async {
        let epoch = LockedBox<UInt64>(0)
        let recorded = LockedBox<[ConfigIdentity]>([])
        let storage = InMemoryStorage()
        AttributionCaptureProtocol.serveConfig(Self.configBody)
        AttributionCaptureProtocol.onConfigRequest = { epoch.mutate { $0 += 1 } }
        let sync = makeSync(storage: storage, identity: { (.fetchedUnder("user-a"), epoch.get()) }, recorded: recorded)

        await sync.refresh(deviceId: "device-1")

        XCTAssertEqual(recorded.get(), [.unknown])
        XCTAssertEqual(persistedLabel(storage), .unknown, "the cached body must not be relabelled on relaunch")

        AttributionCaptureProtocol.onConfigRequest = nil
        await sync.refresh(deviceId: "device-1")
        XCTAssertEqual(AttributionCaptureProtocol.configIfNoneMatch, [nil, nil],
                       "a kept ETag would 304 every later poll and latch the unknown label")
        XCTAssertEqual(recorded.get(), [.unknown, .fetchedUnder("user-a")])
    }

    /// DESIGN GUARD: passes on the old two-call shape too, which only a concurrent fetch landing
    /// between its two actor entries can break.
    func testUnconditionalRefetchSendsNoIfNoneMatchWhateverValidatorIsHeld() async {
        AttributionCaptureProtocol.serveConfig(Self.configBody)
        let sync = makeSync(storage: InMemoryStorage(), identity: { (.fetchedUnder("user-a"), 0) }, recorded: LockedBox([]))

        await sync.refresh(deviceId: "device-1")
        await sync.refresh(deviceId: "device-1")
        await sync.refetchUnconditionally(deviceId: "device-1")

        XCTAssertEqual(AttributionCaptureProtocol.configIfNoneMatch, [nil, "\"v7\"", nil])
    }

    /// A failed unconditional refetch must not hand the next poll back its old validator; the
    /// flag holds until an unconditional body is applied, and only then do polls go conditional.
    func testUnconditionalFetchingHoldsUntilAnUnconditionalBodyIsApplied() async {
        AttributionCaptureProtocol.serveConfig(Self.configBody)
        let sync = makeSync(storage: InMemoryStorage(), identity: { (.fetchedUnder("user-a"), 0) }, recorded: LockedBox([]))

        await sync.refresh(deviceId: "device-1")
        AttributionCaptureProtocol.failNextConfigRequests(1)
        await sync.refetchUnconditionally(deviceId: "device-1")
        await sync.refresh(deviceId: "device-1")
        await sync.refresh(deviceId: "device-1")

        XCTAssertEqual(AttributionCaptureProtocol.configIfNoneMatch, [nil, nil, nil, "\"v7\""])
    }

    /// A cached body whose stored label matches what the row is known to hold now is applied under
    /// that label.
    func testCachedConfigIsAppliedUnderTheIdentityItWasFetchedUnder() async {
        let storage = InMemoryStorage()
        AttributionCaptureProtocol.serveConfig(Self.configBody)
        let first = makeSync(storage: storage, identity: { (.fetchedUnder("user-a"), 0) }, recorded: LockedBox([]))
        await first.refresh(deviceId: "device-1")

        AttributionCaptureProtocol.reset() // the relaunch fetch answers 304 and applies nothing
        let recorded = LockedBox<[ConfigIdentity]>([])
        let relaunched = makeSync(storage: storage, identity: { (.fetchedUnder("user-a"), 0) }, recorded: recorded)
        await relaunched.start(deviceIdGetter: { "device-1" })
        await relaunched.stop()

        XCTAssertEqual(recorded.get().first, .fetchedUnder("user-a"))
    }

    /// The stored label can be wrong (an identify request that committed after the fetch that
    /// wrote it), and every identified launch has set the server-held state to unknown. A cached
    /// body must not be applied under a label the current state does not confirm.
    func testACachedLabelTheServerHeldStateDoesNotConfirmIsAppliedAsUnknown() async throws {
        let storage = InMemoryStorage()
        storage.set(Data(Self.configBody.utf8), forKey: StorageKeys.sdkConfig)
        storage.set(String(Date().timeIntervalSince1970), forKey: StorageKeys.sdkConfigCachedAt)
        storage.set(try JSONEncoder().encode(ServerHeldUser.known("user-b")), forKey: StorageKeys.sdkConfigFetchedUnder)
        let recorded = LockedBox<[ConfigIdentity]>([])
        let sync = makeSync(storage: storage, identity: { (.unknown, 0) }, recorded: recorded)

        await sync.start(deviceIdGetter: { "device-1" })
        await sync.stop()

        XCTAssertEqual(recorded.get().first, .unknown)
    }

    /// "Session expired" at launch: a `reset()` landing between the cache read and its apply must
    /// leave nothing applied.
    func testAResetBetweenTheCacheReadAndItsApplyAppliesNothing() async throws {
        let storage = ReadHookStorage()
        storage.set(Data(Self.configBody.utf8), forKey: StorageKeys.sdkConfig)
        storage.set(String(Date().timeIntervalSince1970), forKey: StorageKeys.sdkConfigCachedAt)
        storage.set(try JSONEncoder().encode(ServerHeldUser.known("user-a")), forKey: StorageKeys.sdkConfigFetchedUnder)
        let gate = ConfigResetGate()
        let applied = LockedBox<ConfigIdentity?>(nil)
        let resetDone = LockedBox(false)
        // The label is read after the body and before the apply: fire the reset from another
        // thread there, as a host would, and give it time to run before the read returns.
        storage.onFirstRead(of: StorageKeys.sdkConfigFetchedUnder) {
            DispatchQueue.global().async {
                gate.reset { // what `SheepitClient.reset()` does: clear memory and disk in the gate
                    applied.set(nil)
                    storage.removeObject(forKey: StorageKeys.sdkConfig)
                }
                resetDone.set(true)
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        let sync = ConfigSync(
            http: HTTPClient(
                config: SheepitConfig(apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64),
                                      apiUrl: "https://stub.invalid", retryAttempts: 1),
                log: Logger(debug: false),
                urlProtocolClasses: [AttributionCaptureProtocol.self]),
            storage: storage,
            refreshInterval: 3600,
            log: Logger(debug: false),
            resetGate: gate,
            identityProvider: { (.fetchedUnder("user-a"), 0) },
            onConfig: { _, identity in applied.set(identity) }
        )

        await sync.start(deviceIdGetter: { "device-1" })
        await sync.stop()
        let finished = await waitUntil { resetDone.get() }

        XCTAssertTrue(finished, "precondition: the reset ran")
        XCTAssertNil(applied.get(), "the logged-out user's cached config was applied after reset()")
    }

    /// The upgrade path: a body cached before the label existed matches no user.
    func testCachedConfigWithoutALabelIsAppliedAsUnknown() async {
        let storage = InMemoryStorage()
        storage.set(Data(Self.configBody.utf8), forKey: StorageKeys.sdkConfig)
        storage.set(String(Date().timeIntervalSince1970), forKey: StorageKeys.sdkConfigCachedAt)
        let recorded = LockedBox<[ConfigIdentity]>([])
        let sync = makeSync(storage: storage, identity: { (.fetchedUnder("user-a"), 0) }, recorded: recorded)

        await sync.start(deviceIdGetter: { "device-1" })
        await sync.stop()

        XCTAssertEqual(recorded.get().first, .unknown)
    }

    /// Two fetches in flight; the one that started first answers last. Its older body must not
    /// replace the newer one.
    func testAnOlderResponseLandingLastIsNotApplied() async {
        let variants = LockedBox<[String]>([])
        AttributionCaptureProtocol.scriptConfig([
            (Self.configBody(variant: "old"), 0.5),
            (Self.configBody(variant: "new"), 0),
        ])
        let sync = makeSync(storage: InMemoryStorage(), identity: { (.fetchedUnder("user-a"), 0) },
                            recorded: LockedBox([]), variants: variants)

        let slow = Task { await sync.refresh(deviceId: "device-1") }
        let started = await waitUntil { AttributionCaptureProtocol.configRequestCount >= 1 }
        XCTAssertTrue(started, "precondition: the slow fetch is on the wire first")
        await sync.refresh(deviceId: "device-1")
        await slow.value

        XCTAssertEqual(variants.get(), ["new"])
    }

    // MARK: - Through the client

    func testAssignmentsAreFrozenAtTrackTimeNotAtFlush() async throws {
        let client = makeClient()
        defer { client.destroy() }
        await waitForStartupFetch()
        await client.awaitIdentityPostForTesting()
        let name = uniqueName("s3d_frozen")

        client.seedAssignmentsForTesting(["pricing_test": try sdkAssignment("treatment", kind: "device")])
        client.track(name)
        client.seedAssignmentsForTesting(["pricing_test": try sdkAssignment("control", kind: "device")])
        await client.flush()

        let sent = try context(of: name)
        XCTAssertEqual(experiments(sent)["pricing_test"] as? String, "treatment")
        XCTAssertEqual(entries(sent)["pricing_test"]?["variant_key"] as? String, "treatment")
    }

    /// The identify 304 latch: the ETag carries no user, so a conditional fetch after identify
    /// answers 304 forever. The mark must clear once the POST succeeds, and not before.
    func testIdentifyMarksUserEntriesUntilItsPostSucceedsThenRefetchesPastThe304() async throws {
        let client = makeClient()
        defer { client.destroy() }
        await waitForStartupFetch()
        AttributionCaptureProtocol.serveConfig(Self.configBody)
        let (before, whileUnanswered, afterPeriodicRefresh, afterAnswer) = (
            uniqueName("s3d_before"), uniqueName("s3d_unanswered"),
            uniqueName("s3d_periodic_304"), uniqueName("s3d_answered"))

        client.identify(userId: "user-a-\(UUID().uuidString)")
        await client.awaitIdentityPostForTesting()
        client.track(before)

        let userB = "user-b-\(UUID().uuidString)"
        AttributionCaptureProtocol.setIdentifyReply(.hold, for: userB)
        client.identify(userId: userB)
        client.track(whileUnanswered)
        await client.refreshConfigForTesting() // the periodic refresh: If-None-Match "v7" → 304
        client.track(afterPeriodicRefresh)
        AttributionCaptureProtocol.releaseHeldIdentify()
        await client.awaitIdentityPostForTesting()
        client.track(afterAnswer)
        await client.flush()

        XCTAssertEqual(experiments(try context(of: before))["pricing_test"] as? String, "treatment",
                       "precondition: the config fetched for user A attributes A's event")
        XCTAssertEqual(AttributionCaptureProtocol.configIfNoneMatch.dropLast().last ?? nil, "\"v7\"",
                       "precondition: the periodic refresh was conditional and answered 304")
        try assertUserEntryMarked(whileUnanswered)
        try assertUserEntryMarked(afterPeriodicRefresh)

        XCTAssertEqual(client.context.serverHeldUser.user, .known(userB))
        XCTAssertEqual(AttributionCaptureProtocol.configIfNoneMatch.last ?? "unset", nil,
                       "the refetch after a successful identify POST must be unconditional")
        let answered = try context(of: afterAnswer)
        XCTAssertEqual(experiments(answered)["pricing_test"] as? String, "treatment")
        XCTAssertNil(entries(answered)["pricing_test"]?["subject_status"])
        XCTAssertEqual(
            client.getRecentDiagnostics().filter { $0.code == "experiment.identity_changed" }.count, 1)
    }

    /// Identify POST 2xx, then its unconditional refetch fails. The next periodic poll must not
    /// 304 against the previous row's validator: it must fetch B's body and apply it as B's.
    func testAFailedRefetchAfterIdentifyDoesNotReLatchThe304() async throws {
        let client = makeClient()
        defer { client.destroy() }
        await waitForStartupFetch()
        AttributionCaptureProtocol.serveConfig(Self.configBody)
        let userB = "user-b-\(UUID().uuidString)"
        let name = uniqueName("s3d_after_failed_refetch")

        client.identify(userId: "user-a-\(UUID().uuidString)")
        await client.awaitIdentityPostForTesting()
        let requestsBeforeB = AttributionCaptureProtocol.configRequestCount
        AttributionCaptureProtocol.failNextConfigRequests(1)
        client.identify(userId: userB)
        await client.awaitIdentityPostForTesting()
        XCTAssertEqual(AttributionCaptureProtocol.configRequestCount, requestsBeforeB + 1,
                       "precondition: the refetch after the identify POST was sent, and failed")
        XCTAssertEqual(client.context.serverHeldUser.user, .known(userB), "precondition: the POST succeeded")

        await client.refreshConfigForTesting() // the next periodic poll
        client.track(name)
        await client.flush()

        XCTAssertEqual(AttributionCaptureProtocol.configIfNoneMatch.last ?? "unset", nil,
                       "a conditional poll 304s against the previous row's ETag and keeps its config")
        let sent = try context(of: name)
        XCTAssertEqual(experiments(sent)["pricing_test"] as? String, "treatment")
        XCTAssertNil(entries(sent)["pricing_test"]?["subject_status"])
    }

    /// identify(B); identify(C); POST B answers; POST C goes out. From the moment C is sent the server
    /// may commit it before evaluating a fetch, so a fetch in flight then must not be labelled B:
    /// if it were, a later identify(B) would credit B's events to C's arms.
    func testTheLabelIsUnknownWhileAQueuedIdentifyPostIsOnTheWire() async throws {
        let client = makeClient()
        defer { client.destroy() }
        await waitForStartupFetch()
        AttributionCaptureProtocol.serveConfig(Self.configBody)
        AttributionCaptureProtocol.honorIfNoneMatch = false
        let (userB, userC) = ("user-b-\(UUID().uuidString)", "user-c-\(UUID().uuidString)")
        let name = uniqueName("s3d_while_c_on_wire")

        client.identify(userId: "user-a-\(UUID().uuidString)")
        await client.awaitIdentityPostForTesting()
        AttributionCaptureProtocol.setIdentifyReply(.hold, for: userC)
        client.identify(userId: userB)
        client.identify(userId: userC)
        let cSent = await waitUntil { AttributionCaptureProtocol.identifyUserIds.contains(userC) }
        XCTAssertTrue(cSent, "precondition: POST B answered and POST C is on the wire")
        XCTAssertEqual(client.context.serverHeldUser.user, .unknown, "the server may already hold C")

        await client.refreshConfigForTesting() // starts and lands while POST C is unanswered
        client.identify(userId: userB)
        client.track(name)
        AttributionCaptureProtocol.releaseHeldIdentify()
        await client.awaitIdentityPostForTesting()
        await client.flush()

        try assertUserEntryMarked(name)
    }

    /// A destroyed client's identify POST must not retry later and move the server's row after a
    /// newer client recorded what it holds.
    func testDestroyStopsAnIdentifyPostDuringItsRetryBackoff() async throws {
        let client = makeClient(retryAttempts: 3)
        await waitForStartupFetch()
        let user = "user-retry-\(UUID().uuidString)"
        AttributionCaptureProtocol.setIdentifyReply(.status(500), for: user)
        let attempts = { AttributionCaptureProtocol.identifyUserIds.filter { $0 == user }.count }

        client.identify(userId: user)
        let firstAttempt = await waitUntil { attempts() == 1 }
        XCTAssertTrue(firstAttempt, "precondition: the first attempt failed and a retry is backing off")
        client.destroy()
        try await Task.sleep(for: .seconds(SDKDefaults.retryBackoff[0] + 1))

        XCTAssertEqual(attempts(), 1, "no attempt may be sent after destroy()")
    }

    /// DESIGN GUARD: the previous model marked these entries too (it kept the last confirmed
    /// user); this pins that a failed POST keeps doing so under the server-held label.
    func testFailedIdentifyPostLeavesTheLabelUnknownAndEntriesMarked() async throws {
        let client = makeClient()
        defer { client.destroy() }
        await waitForStartupFetch()
        AttributionCaptureProtocol.serveConfig(Self.configBody)
        AttributionCaptureProtocol.honorIfNoneMatch = false
        let userB = "user-b-\(UUID().uuidString)"
        let name = uniqueName("s3d_failed_post")

        client.identify(userId: "user-a-\(UUID().uuidString)")
        await client.awaitIdentityPostForTesting()
        AttributionCaptureProtocol.setIdentifyReply(.status(500), for: userB)
        client.identify(userId: userB)
        await client.awaitIdentityPostForTesting()
        await client.refreshConfigForTesting()
        client.track(name)
        await client.flush()

        XCTAssertEqual(client.context.serverHeldUser.user, .unknown)
        try assertUserEntryMarked(name)
    }

    /// The reviewer's hole: A confirmed; identify(B); identify(A); POST B stored; POST A fails.
    /// The row holds B while the app says A, so every fetch carries B's bucketing. Labelling it A
    /// credited A's events to B's arms.
    func testIdentifyBounceWhoseLastPostFailsNeverLabelsTheRowWithTheAppsUser() async throws {
        let client = makeClient()
        defer { client.destroy() }
        await waitForStartupFetch()
        AttributionCaptureProtocol.serveConfig(Self.configBody)
        AttributionCaptureProtocol.honorIfNoneMatch = false
        let (userA, userB) = ("user-a-\(UUID().uuidString)", "user-b-\(UUID().uuidString)")
        let (beforeRefetch, bounced) = (uniqueName("s3d_before_refetch"), uniqueName("s3d_bounced"))

        client.identify(userId: userA)
        await client.awaitIdentityPostForTesting()
        AttributionCaptureProtocol.setIdentifyReply(.hold, for: userB)
        client.identify(userId: userB)
        client.track(beforeRefetch)
        AttributionCaptureProtocol.setIdentifyReply(.status(500), for: userA)
        client.identify(userId: userA)
        AttributionCaptureProtocol.releaseHeldIdentify()
        await client.awaitIdentityPostForTesting()
        await client.refreshConfigForTesting() // the server now buckets for B
        client.track(bounced)
        await client.flush()

        XCTAssertEqual(Array(AttributionCaptureProtocol.identifyUserIds.suffix(2)), [userB, userA],
                       "precondition: POST B was stored before POST A was attempted")
        try assertUserEntryMarked(beforeRefetch)
        XCTAssertEqual(client.context.serverHeldUser.user, .unknown)
        try assertUserEntryMarked(bounced)
    }

    /// POST B's response is lost (the server may hold B), then the app identifies A again.
    func testLostIdentifyResponseThenIdentifyingBackKeepsEntriesMarkedUntilAPostAnswers() async throws {
        let client = makeClient()
        defer { client.destroy() }
        await waitForStartupFetch()
        AttributionCaptureProtocol.serveConfig(Self.configBody)
        AttributionCaptureProtocol.honorIfNoneMatch = false
        let (userA, userB) = ("user-a-\(UUID().uuidString)", "user-b-\(UUID().uuidString)")
        let (whileHeld, answered) = (uniqueName("s3d_back_held"), uniqueName("s3d_back_answered"))

        client.identify(userId: userA)
        await client.awaitIdentityPostForTesting()
        AttributionCaptureProtocol.setIdentifyReply(.lost, for: userB)
        client.identify(userId: userB)
        await client.awaitIdentityPostForTesting()
        AttributionCaptureProtocol.setIdentifyReply(.hold, for: userA)
        client.identify(userId: userA)
        await client.refreshConfigForTesting()
        client.track(whileHeld)
        AttributionCaptureProtocol.releaseHeldIdentify()
        await client.awaitIdentityPostForTesting()
        client.track(answered)
        await client.flush()

        try assertUserEntryMarked(whileHeld)
        XCTAssertEqual(client.context.serverHeldUser.user, .known(userA))
        let sent = try context(of: answered)
        XCTAssertEqual(experiments(sent)["pricing_test"] as? String, "treatment")
        XCTAssertNil(entries(sent)["pricing_test"]?["subject_status"])
    }

    /// Logout on a device bound to a user switches to a fresh device (`DeviceRotation`), whose row
    /// holds nobody: the label becomes `.known(nil)`, so an anonymous event is attributed to the
    /// arm the anonymous config bucketed it into. Before the rotation existed the row kept the
    /// previous user, the next config was bucketed for them, and these events had to be marked.
    func testResetRotatesToAFreshDeviceWhoseAnonymousEventsAreAttributed() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suite))
        defaults.set("1", forKey: StorageKeys.deviceRegistered)
        defer {
            defaults.removeObject(forKey: StorageKeys.deviceRegistered)
            defaults.removeObject(forKey: StorageKeys.deviceId)
        }
        let minted = "dev_\(UUID().uuidString)"
        AttributionCaptureProtocol.registerDeviceId = minted
        let client = makeClient()
        defer { client.destroy() }
        await waitForStartupFetch()
        AttributionCaptureProtocol.serveConfig(Self.configBody)
        AttributionCaptureProtocol.honorIfNoneMatch = false
        let userA = "user-a-\(UUID().uuidString)"
        let (rightAfterReset, afterRefetch) = (uniqueName("s3d_logged_out"), uniqueName("s3d_logged_out_refetched"))

        client.identify(userId: userA)
        await client.awaitIdentityPostForTesting()
        client.reset()
        client.track(rightAfterReset)
        let rotated = await waitUntil { client.context.deviceId == minted }
        XCTAssertTrue(rotated, "precondition: the fresh device was adopted")
        for _ in 0..<50 where client.status().experimentCount == 0 {
            await client.refreshConfigForTesting()
        }
        client.track(afterRefetch)
        await client.flush()

        XCTAssertEqual(client.context.serverHeldUser.user, .known(nil))
        let loggedOut = try context(of: rightAfterReset)
        XCTAssertNil(loggedOut["experiments"])
        XCTAssertNil(loggedOut["experiment_assignments"])
        let sent = try context(of: afterRefetch)
        XCTAssertEqual(experiments(sent)["pricing_test"] as? String, "treatment")
        XCTAssertNil(entries(sent)["pricing_test"]?["subject_status"])
    }

    func testAdoptingANewlyMintedDeviceIdRecordsThatTheRowHoldsNoUser() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suite))
        for key in [StorageKeys.deviceId, StorageKeys.deviceRegistered,
                    StorageKeys.deviceRegistrationBackoffUntil, StorageKeys.identity] {
            defaults.removeObject(forKey: key)
        }
        defaults.set(try JSONEncoder().encode(ServerHeldUser.known("previous-row-user")), forKey: StorageKeys.serverHeldUser)
        let minted = "dev_\(UUID().uuidString)"
        AttributionCaptureProtocol.registerDeviceId = minted

        let client = makeClient()
        defer { client.destroy() }
        let adopted = await waitUntil { client.context.deviceId == minted }

        XCTAssertTrue(adopted, "precondition: the server-minted id was adopted")
        XCTAssertEqual(client.context.serverHeldUser.user, .known(nil))
    }

    /// An identity the row is not known to hold (an SDK upgrade, or a POST that failed or went
    /// unanswered before the app was killed) is re-sent once at launch; no identity at all is not.
    func testIdentityTheRowIsNotKnownToHoldIsPostedAgainAtLaunch() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suite))
        let userB = "user-b-\(UUID().uuidString)"
        let previous = makeClient()
        previous.identify(userId: userB)
        await previous.awaitIdentityPostForTesting()
        previous.destroy()
        defaults.set(try JSONEncoder().encode(ServerHeldUser.unknown), forKey: StorageKeys.serverHeldUser)
        AttributionCaptureProtocol.reset()

        let relaunched = makeClient()
        await relaunched.awaitIdentityPostForTesting()
        relaunched.destroy()
        XCTAssertEqual(AttributionCaptureProtocol.identifyUserIds, [userB])
        XCTAssertEqual(relaunched.context.serverHeldUser.user, .known(userB))

        defaults.removeObject(forKey: StorageKeys.identity)
        defaults.set(try JSONEncoder().encode(ServerHeldUser.unknown), forKey: StorageKeys.serverHeldUser)
        AttributionCaptureProtocol.reset()
        let anonymous = makeClient()
        defer { anonymous.destroy() }
        await anonymous.awaitIdentityPostForTesting()
        XCTAssertEqual(AttributionCaptureProtocol.identifyUserIds, [], "no identity, no POST")
    }

    /// The late-commit stopgap: even a row last known to hold this user is re-sent once per
    /// identified launch, because a POST the previous session stopped waiting for may have
    /// committed after it and moved the row. That bounds the residual to one session.
    func testAnIdentifiedLaunchPostsOnceEvenWhenTheRowIsKnownToHoldTheUser() async throws {
        let userB = "user-b-\(UUID().uuidString)"
        let previous = makeClient()
        previous.identify(userId: userB)
        await previous.awaitIdentityPostForTesting()
        previous.destroy()
        XCTAssertEqual(previous.context.serverHeldUser.user, .known(userB), "precondition: the row is known to hold the user")
        AttributionCaptureProtocol.reset()

        let relaunched = makeClient()
        defer { relaunched.destroy() }
        await relaunched.awaitIdentityPostForTesting()

        XCTAssertEqual(AttributionCaptureProtocol.identifyUserIds, [userB], "exactly one POST per identified launch")
        XCTAssertEqual(relaunched.context.serverHeldUser.user, .known(userB))
    }

    /// An offline relaunch after the late-commit residual: the cache was written labelled B, but the
    /// launch has not confirmed the row, so B's events must not be attributed from that cache.
    func testAnIdentifiedLaunchAppliesItsCachedConfigAsUnknownUntilItsIdentifyPostAnswers() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suite))
        let userB = "user-b-\(UUID().uuidString)"
        let name = uniqueName("s3d_offline_relaunch")
        AttributionCaptureProtocol.serveConfig(Self.configBody)
        let previous = makeClient()
        previous.identify(userId: userB)
        await previous.awaitIdentityPostForTesting()
        previous.destroy()
        let label = defaults.data(forKey: StorageKeys.sdkConfigFetchedUnder)
            .flatMap { try? JSONDecoder().decode(ServerHeldUser.self, from: $0) }
        XCTAssertEqual(label, .known(userB), "precondition: the cached body is labelled B")

        AttributionCaptureProtocol.reset() // offline-like: config answers 304, the identify POST hangs
        AttributionCaptureProtocol.setIdentifyReply(.hold, for: userB)
        let relaunched = makeClient()
        defer {
            AttributionCaptureProtocol.releaseHeldIdentify()
            relaunched.destroy()
        }
        let loaded = await waitUntil { relaunched.status().experimentCount > 0 }
        XCTAssertTrue(loaded, "precondition: the cached config was applied")
        relaunched.track(name)
        await relaunched.flush()

        try assertUserEntryMarked(name)
    }

    /// A launch identify POST that fails (offline at launch) is re-sent on a later refresh tick, and
    /// once it succeeds the refetch is applied under the confirmed user.
    func testAFailedLaunchIdentifyPostIsRetriedOnALaterRefreshTick() async throws {
        let userB = "user-b-\(UUID().uuidString)"
        let name = uniqueName("s3d_retried_launch_post")
        AttributionCaptureProtocol.serveConfig(Self.configBody)
        let previous = makeClient()
        previous.identify(userId: userB)
        await previous.awaitIdentityPostForTesting()
        previous.destroy()

        AttributionCaptureProtocol.reset()
        AttributionCaptureProtocol.serveConfig(Self.configBody)
        AttributionCaptureProtocol.honorIfNoneMatch = false
        AttributionCaptureProtocol.setIdentifyReply(.lost, for: userB)
        let relaunched = makeClient()
        defer { relaunched.destroy() }
        await relaunched.awaitIdentityPostForTesting()
        XCTAssertEqual(relaunched.context.serverHeldUser.user, .unknown, "precondition: the launch POST failed")

        AttributionCaptureProtocol.setIdentifyReply(.status(200), for: userB)
        relaunched.configRefreshTickForTesting()
        await relaunched.awaitIdentityPostForTesting()
        relaunched.track(name)
        await relaunched.flush()

        XCTAssertEqual(AttributionCaptureProtocol.identifyUserIds.filter { $0 == userB }.count, 2,
                       "one launch POST and one retry")
        XCTAssertEqual(relaunched.context.serverHeldUser.user, .known(userB))
        let sent = try context(of: name)
        XCTAssertEqual(experiments(sent)["pricing_test"] as? String, "treatment")
        XCTAssertNil(entries(sent)["pricing_test"]?["subject_status"])
    }

    /// Never identified: the server resolves the subject and records the missing identity itself.
    func testAnonymousEventSendsAUserEntryWithoutStatusAndWithoutAnySubjectValue() async throws {
        UserDefaults(suiteName: Self.suite)?.removeObject(forKey: StorageKeys.identity)
        let client = makeClient()
        defer { client.destroy() }
        await waitForStartupFetch()
        XCTAssertNil(client.context.userId, "precondition: never identified")
        let name = uniqueName("s3d_anonymous")

        client.seedAssignmentsForTesting(["pricing_test": try sdkAssignment("treatment", kind: "user")],
                                         appliedUnderUserId: nil)
        client.track(name)
        await client.flush()

        let sent = try context(of: name)
        let entry = try XCTUnwrap(entries(sent)["pricing_test"])
        XCTAssertEqual(entry["subject_kind"] as? String, "user")
        XCTAssertNil(entry["subject_status"])
        XCTAssertNil(entry["subject"])
        for value in entry.values.compactMap({ $0 as? String }) {
            XCTAssertFalse(value.hasPrefix("d:") || value.hasPrefix("u:"), "no subject value, never a d: fallback")
        }
        XCTAssertEqual(experiments(sent)["pricing_test"] as? String, "treatment")
    }
}
