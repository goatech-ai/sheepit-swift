import XCTest
@testable import SheepitKit

/// The identify POSTs the SDK sends on its own (the launch re-POST and the periodic retry) against
/// `reset()`, a POST that keeps failing, and a POST the API rejects. Every assertion reads what the
/// real `SheepitClient` sent through `AttributionCaptureProtocol`.
///
/// Shares the `ai.goatech.sdk` suite with every other client suite, so `setUp`/`tearDown` clear
/// every key these tests depend on (see `ExperimentAttributionClientTests` for why).
final class IdentifyRetryTests: XCTestCase {
    private static let suite = "ai.goatech.sdk"

    private static func clearStorage() {
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        for key in [StorageKeys.sdkConfig, StorageKeys.sdkConfigCachedAt,
                    StorageKeys.sdkConfigFetchedUnder, StorageKeys.serverHeldUser,
                    StorageKeys.identity, StorageKeys.deviceRegistrationBackoffUntil,
                    StorageKeys.deviceRegistrationBackoffSDKVersion, StorageKeys.deviceBindAttempted] {
            defaults.removeObject(forKey: key)
        }
    }

    override func setUp() {
        super.setUp()
        Self.clearStorage()
        AttributionCaptureProtocol.reset()
        // A `reset()` after an identify now registers a fresh device (`DeviceRotation`); answer it.
        AttributionCaptureProtocol.registerDeviceId = "dev_rotated_\(UUID().uuidString)"
    }

    override func tearDown() {
        Self.clearStorage()
        AttributionCaptureProtocol.reset()
        super.tearDown()
    }

    private static let configBody = #"""
    {"data":{"config_version":"7","etag":"\"v7\"","flags":{},"experiments":{
      "pricing_test":{"variant_key":"treatment","payload":{},"experiment_id":"11111111-1111-4111-8111-111111111111","subject_kind":"user","bucketing_version":1,"assignment_revision":"7"},
      "onboarding_test":{"variant_key":"b","payload":{},"experiment_id":"22222222-2222-4222-8222-222222222222","subject_kind":"device","bucketing_version":1,"assignment_revision":"7"}}}}
    """#

    private func makeClient(retryAttempts: Int = 1) -> SheepitClient {
        let client = SheepitClient.createForTesting(
            config: SheepitConfig(
                apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64),
                apiUrl: "https://stub.invalid",
                flushInterval: 3600,
                flushSize: 1000,
                configRefreshInterval: 3600,
                retryAttempts: retryAttempts,
                // A client with crash reporting on installs real signal handlers into the test process.
                crashes: CrashConfig(enabled: false)
            ),
            now: { Date() },
            urlProtocolClasses: [AttributionCaptureProtocol.self]
        )
        client.deviceRotationRetryDelayForTesting = { _ in .milliseconds(20) }
        return client
    }

    private func uniqueUser(_ prefix: String) -> String {
        "\(prefix)-\(UUID().uuidString)"
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private func waitForStartupFetch() async {
        let seen = await waitUntil { AttributionCaptureProtocol.configRequestCount >= 1 }
        XCTAssertTrue(seen, "precondition: the start-up config fetch ran")
    }

    private func posts(for userId: String) -> Int {
        AttributionCaptureProtocol.identifyUserIds.filter { $0 == userId }.count
    }

    /// Identifies `userId` with a POST that fails, leaving the label unknown so a tick retries.
    private func identifyWithFailedPost(_ client: SheepitClient, _ userId: String,
                                        reply: AttributionCaptureProtocol.IdentifyReply = .lost) async {
        AttributionCaptureProtocol.setIdentifyReply(reply, for: userId)
        client.identify(userId: userId)
        await client.awaitIdentityPostForTesting()
        XCTAssertEqual(client.context.serverHeldUser.user, .unknown, "precondition: the identify POST failed")
    }

    // MARK: - reset()

    /// A retry already on the wire when `reset()` runs cannot be unsent, and its 2xx means the OLD
    /// row holds that user. The logout switched to a fresh device (`DeviceRotation`), so that answer
    /// describes an abandoned row: it must not label the new one, and events after the logout are
    /// attributed under the new, anonymous row's config.
    func testARetryAnsweredAfterResetDescribesTheAbandonedRowNotTheNewOne() async throws {
        let client = makeClient()
        defer { client.destroy() }
        await waitForStartupFetch()
        AttributionCaptureProtocol.serveConfig(Self.configBody)
        AttributionCaptureProtocol.honorIfNoneMatch = false
        let userA = uniqueUser("user-a")
        let name = "retry_after_reset_\(UUID().uuidString.prefix(8))"

        await identifyWithFailedPost(client, userA)
        AttributionCaptureProtocol.setIdentifyReply(.hold, for: userA)
        client.configRefreshTickForTesting()
        let onWire = await waitUntil { posts(for: userA) == 2 }
        XCTAssertTrue(onWire, "precondition: the retry is on the wire")
        let oldDevice = client.context.deviceId
        client.reset()
        AttributionCaptureProtocol.releaseHeldIdentify()
        await client.awaitIdentityPostForTesting()
        let rotated = await waitUntil { client.context.deviceId.hasPrefix("dev_rotated_") }
        XCTAssertTrue(rotated, "precondition: the logout switched devices")
        await client.refreshConfigForTesting()
        client.track(name)
        await client.flush()
        client.configRefreshTickForTesting()
        await client.awaitIdentityPostForTesting()

        XCTAssertNotEqual(client.context.deviceId, oldDevice)
        XCTAssertEqual(client.context.serverHeldUser.user, .known(nil), "the new row holds nobody")
        let event = try XCTUnwrap(AttributionCaptureProtocol.event(named: name))
        let context = try XCTUnwrap(event["context"] as? [String: Any])
        let experiments = context["experiments"] as? [String: Any] ?? [:]
        let entries = context["experiment_assignments"] as? [String: [String: Any]] ?? [:]
        XCTAssertNil(entries["pricing_test"]?["subject_status"], "bucketed for the anonymous row it is sent from")
        XCTAssertEqual(experiments["onboarding_test"] as? String, "b", "precondition: the refetch was applied")
        XCTAssertEqual(posts(for: userA), 2, "nothing is re-sent for a logged-out user")
    }

    /// A retry queued by a tick, with `reset()` landing before it is sent, must not bind the
    /// logged-out user to the device row again.
    func testAnIdentifyRetryIsNotSentWhenResetRunsBeforeItGoesOut() async throws {
        let client = makeClient()
        defer { client.destroy() }
        await waitForStartupFetch()
        let userA = uniqueUser("user-a")

        await identifyWithFailedPost(client, userA)
        AttributionCaptureProtocol.setIdentifyReply(.status(200), for: userA)
        client.configRefreshTickForTesting(beforeSend: { [client] in client.reset() })
        await client.awaitIdentityPostForTesting()

        XCTAssertEqual(posts(for: userA), 1, "only the original POST; the retry was for a logged-out user")
        XCTAssertEqual(
            client.context.serverHeldUser.user, .known(nil),
            "the original POST may have bound the row, so the logout switched to a fresh device")
    }

    /// The same, when the app identifies the same user again inside that window: the retry is still
    /// not sent (the reset token moved), and the new `identify()` sends its own POST.
    func testAnIdentifyRetryQueuedBeforeResetIsNotSentEvenIfTheSameUserIsIdentifiedAgain() async throws {
        let client = makeClient()
        defer { client.destroy() }
        await waitForStartupFetch()
        let userA = uniqueUser("user-a")

        await identifyWithFailedPost(client, userA)
        AttributionCaptureProtocol.setIdentifyReply(.status(200), for: userA)
        client.configRefreshTickForTesting(beforeSend: { [client] in
            client.reset()
            client.identify(userId: userA)
        })
        await client.awaitIdentityPostForTesting() // the retry, which queued identify()'s POST behind it
        await client.awaitIdentityPostForTesting() // that POST

        XCTAssertEqual(posts(for: userA), 2, "the original POST and the new identify()'s, not the stale retry")
        XCTAssertEqual(client.context.serverHeldUser.user, .known(userA))
    }

    /// `HTTPClient` retries a 5xx after a backoff. A `reset()` during that backoff must stop the next
    /// attempt: the first attempt did not store the user, so a later one would be a new bind of a
    /// logged-out user to a row that did not hold them.
    func testAResetDuringTheHTTPRetryBackoffStopsTheNextIdentifyAttempt() async throws {
        let client = makeClient(retryAttempts: 2)
        defer { client.destroy() }
        await waitForStartupFetch()
        let userA = uniqueUser("user-a")

        await identifyWithFailedPost(client, userA, reply: .status(500))
        XCTAssertEqual(posts(for: userA), 2, "precondition: the identify POST and its HTTP retry both failed")
        client.configRefreshTickForTesting()
        let firstAttempt = await waitUntil { posts(for: userA) == 3 }
        XCTAssertTrue(firstAttempt, "precondition: the retry's first attempt failed and is backing off")
        AttributionCaptureProtocol.setIdentifyReply(.status(200), for: userA)
        client.reset()
        await client.awaitIdentityPostForTesting()

        XCTAssertEqual(posts(for: userA), 3, "no attempt may reach the server after reset()")
        XCTAssertNotEqual(client.context.serverHeldUser.user, .known(userA))
    }

    /// The launch re-POST waits for registration. A `reset()` in that window ("session expired" at
    /// launch) must not bind the logged-out user to the device row again.
    func testTheLaunchIdentifyPostIsNotSentWhenResetRunsBeforeRegistrationSettles() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suite))
        let userA = uniqueUser("user-a")
        let previous = makeClient()
        previous.identify(userId: userA)
        await previous.awaitIdentityPostForTesting()
        previous.destroy()

        AttributionCaptureProtocol.reset()
        let registered = defaults.string(forKey: StorageKeys.deviceRegistered)
        defaults.removeObject(forKey: StorageKeys.deviceRegistered)
        defer { defaults.set(registered, forKey: StorageKeys.deviceRegistered) }
        AttributionCaptureProtocol.holdRegister = true
        let relaunched = makeClient()
        defer {
            AttributionCaptureProtocol.releaseHeldRegister()
            relaunched.destroy()
        }
        let registering = await waitUntil { AttributionCaptureProtocol.registerRequestCount == 1 }
        XCTAssertTrue(registering, "precondition: registration is in flight, so the launch POST is waiting on it")

        relaunched.reset()
        AttributionCaptureProtocol.releaseHeldRegister()
        await relaunched.awaitIdentityPostForTesting()

        XCTAssertEqual(AttributionCaptureProtocol.identifyUserIds, [], "no POST for a user logged out before it was sent")
    }

    // MARK: - A POST that keeps failing

    /// A retry that fails on every tick used to move the server-held epoch while that tick's config
    /// fetch was on the wire, so the fetch's ETag was dropped and every later poll was a full 200 and
    /// a disk write, across relaunches.
    func testAPersistentlyFailingIdentifyRetryKeepsTheNextPollConditional() async throws {
        let client = makeClient()
        defer { client.destroy() }
        await waitForStartupFetch()
        let userA = uniqueUser("user-a")

        await identifyWithFailedPost(client, userA, reply: .status(500))
        let requestsBefore = AttributionCaptureProtocol.configRequestCount
        AttributionCaptureProtocol.scriptConfig([(Self.configBody, 1.0)])
        let poll = Task { await client.refreshConfigForTesting() }
        let pollOnWire = await waitUntil { AttributionCaptureProtocol.configRequestCount == requestsBefore + 1 }
        XCTAssertTrue(pollOnWire, "precondition: the tick's config fetch is on the wire")
        client.configRefreshTickForTesting()
        await client.awaitIdentityPostForTesting()
        XCTAssertEqual(posts(for: userA), 2, "precondition: the retry was sent and failed")
        XCTAssertEqual(client.status().experimentCount, 0, "precondition: the fetch had not landed yet")
        await poll.value

        AttributionCaptureProtocol.serveConfig(Self.configBody)
        await client.refreshConfigForTesting()

        XCTAssertEqual(AttributionCaptureProtocol.configIfNoneMatch.last ?? "unset", "\"v7\"",
                       "the next poll must revalidate the body it holds, not download it again")
    }

    /// A 4xx the API will give every time (here 404, the answer for a device the server does not
    /// know) is not re-sent on each tick.
    func testAnIdentifyPostRejectedWithANonRetryable4xxIsNotRetried() async throws {
        let client = makeClient()
        defer { client.destroy() }
        await waitForStartupFetch()
        let userA = uniqueUser("user-a")

        await identifyWithFailedPost(client, userA, reply: .status(404))
        client.configRefreshTickForTesting()
        await client.awaitIdentityPostForTesting()

        XCTAssertEqual(posts(for: userA), 1)
        XCTAssertEqual(client.getRecentDiagnostics().filter { $0.code == "identity.identify_post_rejected" }.count, 1)
    }

    /// D-SDK4: no identify POST carries an `attributes` body, ever.
    ///
    /// The `traits` parameter was REMOVED in 0.7.0, so the strongest guard is the compiler —
    /// `client.identify(userId:traits:)` no longer exists and a call site passing traits does
    /// not build. This test guards the half the compiler cannot: that the request body the SDK
    /// constructs carries no `attributes` key, whatever route it takes to the wire. It fails
    /// against the pre-D-SDK4 code, where `postIdentity` mapped traits into the body.
    func testNoIdentifyPostCarriesAttributes() async throws {
        let client = makeClient()
        defer { client.destroy() }
        await waitForStartupFetch()
        let userC = uniqueUser("user-c")

        client.identify(userId: userC)
        await client.awaitIdentityPostForTesting()

        let attributes = AttributionCaptureProtocol.identifyAttributes
        XCTAssertEqual(attributes.count, 1, "one POST, and no traits-rejected resend to make")
        XCTAssertNil(attributes.first ?? nil, "the wire body must carry no attributes")
        XCTAssertEqual(client.context.serverHeldUser.user, .known(userC))
    }

    /// Re-identifying the same user is still a no-op — the removal of `traits` must not have
    /// turned the same-user path into a POST, which is the regression a careless deletion of the
    /// trait-merge line would cause.
    func testReIdentifyingTheSameUserStillSendsNoPost() async throws {
        let client = makeClient()
        defer { client.destroy() }
        await waitForStartupFetch()
        let userA = uniqueUser("user-a")

        client.identify(userId: userA)
        await client.awaitIdentityPostForTesting()
        client.identify(userId: userA)
        client.identify(userId: userA)

        XCTAssertEqual(posts(for: userA), 1, "three calls, one POST")
        XCTAssertEqual(
            client.getRecentDiagnostics().filter { $0.code == "identity.identify_noop" }.count,
            2,
            "the two repeats each take the no-op path"
        )
    }

    /// `reset()` during the backoff of the INITIAL POST's own HTTP retry — a different window from
    /// `testAResetDuringTheHTTPRetryBackoffStopsTheNextIdentifyAttempt`, which covers the
    /// config-tick-driven retry after the first POST and its HTTP retry have both failed. The first
    /// attempt did not store the user, so a later one would newly bind a logged-out user to a row
    /// that never held them.
    func testAResetDuringTheHTTPRetryBackoffStopsTheNextAttemptOfAnIdentifyCall() async throws {
        let client = makeClient(retryAttempts: 2)
        defer { client.destroy() }
        await waitForStartupFetch()
        let userA = uniqueUser("user-a")
        AttributionCaptureProtocol.setIdentifyReply(.status(500), for: userA)

        client.identify(userId: userA)
        let firstAttempt = await waitUntil { posts(for: userA) == 1 }
        XCTAssertTrue(firstAttempt, "precondition: the first attempt is failing and will back off")
        AttributionCaptureProtocol.setIdentifyReply(.status(200), for: userA)
        client.reset()
        await client.awaitIdentityPostForTesting()

        XCTAssertEqual(posts(for: userA), 1, "no attempt may reach the server after reset()")
        XCTAssertNotEqual(client.context.serverHeldUser.user, .known(userA))
    }

    /// Cross-user: one person's POST, then another's whose POST fails and is retried. No request in
    /// the sequence may carry an `attributes` body — the shape that used to leak the earlier user's
    /// traits onto the later user's profile.
    func testNoRequestInACrossUserIdentifySequenceCarriesAttributes() async throws {
        let client = makeClient()
        defer { client.destroy() }
        await waitForStartupFetch()
        let (userA, userB) = (uniqueUser("user-a"), uniqueUser("user-b"))

        client.identify(userId: userA)
        await client.awaitIdentityPostForTesting()
        await identifyWithFailedPost(client, userB, reply: .status(500))
        client.configRefreshTickForTesting()
        await client.awaitIdentityPostForTesting()

        XCTAssertEqual(posts(for: userB), 2, "precondition: B's POST and one retry")
        XCTAssertTrue(
            AttributionCaptureProtocol.identifyAttributes.allSatisfy { $0 == nil },
            "no request in the sequence carries attributes"
        )
    }

    /// DESIGN GUARD (passes on the code before the fix too): a 429 is transient and stays retryable.
    func testARateLimitedIdentifyPostIsStillRetried() async throws {
        let client = makeClient()
        defer { client.destroy() }
        await waitForStartupFetch()
        let userA = uniqueUser("user-a")

        await identifyWithFailedPost(client, userA, reply: .status(429))
        AttributionCaptureProtocol.setIdentifyReply(.status(200), for: userA)
        client.configRefreshTickForTesting()
        await client.awaitIdentityPostForTesting()

        XCTAssertEqual(posts(for: userA), 2)
        XCTAssertEqual(client.context.serverHeldUser.user, .known(userA))
    }

    /// While registration is backed off after a terminal failure the device is not on the server,
    /// so a retry can only 404.
    func testNoIdentifyRetryWhileDeviceRegistrationIsBackedOff() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suite))
        let client = makeClient()
        defer { client.destroy() }
        await waitForStartupFetch()
        let userA = uniqueUser("user-a")

        await identifyWithFailedPost(client, userA)
        defaults.set(String(Date().timeIntervalSince1970 + 3600), forKey: StorageKeys.deviceRegistrationBackoffUntil)
        defaults.set(SDKDefaults.sdkVersion, forKey: StorageKeys.deviceRegistrationBackoffSDKVersion)
        client.configRefreshTickForTesting()
        await client.awaitIdentityPostForTesting()

        XCTAssertEqual(posts(for: userA), 1)
    }

    /// Neither the original POST nor its retry carries attributes (D-SDK4), and one retry stays
    /// one POST. Before that decision the first POST DID carry them and only the retry did not.
    func testNeitherAnIdentifyPostNorItsRetrySendsAttributes() async throws {
        let client = makeClient()
        defer { client.destroy() }
        await waitForStartupFetch()
        let userA = uniqueUser("user-a")

        await identifyWithFailedPost(client, userA)
        AttributionCaptureProtocol.setIdentifyReply(.status(200), for: userA)
        client.configRefreshTickForTesting()
        await client.awaitIdentityPostForTesting()

        let attributes = AttributionCaptureProtocol.identifyAttributes
        XCTAssertEqual(attributes.count, 2, "precondition: the original POST and one retry")
        let first: [String: Any]? = attributes.first ?? nil
        let retried: [String: Any]? = attributes.last ?? nil
        XCTAssertNil(first, "identify() puts no attributes on the wire")
        XCTAssertNil(retried)
    }
}
