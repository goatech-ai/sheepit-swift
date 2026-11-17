import XCTest
@testable import SheepitKit

/// `identify(userId:timeout:)` and `awaitConfig(timeout:)` against the real `SheepitClient`, with
/// the API scripted by `AttributionCaptureProtocol`; plus a race stress on `IdentifyWaiters` itself.
///
/// Shares the `ai.goatech.sdk` suite with every other client suite, so `setUp`/`tearDown` clear it.
final class AwaitIdentifyTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SharedSDKStorage.clear()
        AttributionCaptureProtocol.reset()
        AttributionCaptureProtocol.registerDeviceId = "dev_await_\(UUID().uuidString)"
        // The server honours a well-formed proposal (device registration contract § 2), so the
        // launch registration changes no id. Config answers say `resolved`, as the current server
        // does, so the accepted registration refetches nothing these counts would see
        // (`ConfigSync.refetchAfterRegistration`); `startedClient()` waits for it to settle.
        AttributionCaptureProtocol.echoRegisteredDeviceId = true
        AttributionCaptureProtocol.configResolution = { _, _ in "resolved" }
    }

    override func tearDown() {
        SharedSDKStorage.clear()
        AttributionCaptureProtocol.reset()
        super.tearDown()
    }

    private static func configBody(newCheckout: Bool) -> String {
        #"{"data":{"config_version":"7","etag":"\"v\#(newCheckout)\"","flags":{"new_checkout":\#(newCheckout)},"#
            + #""experiments":{}}}"#
    }

    private func makeClient(identifyRetryDelays: [TimeInterval] = []) -> SheepitClient {
        let client = SheepitClient.createForTesting(
            config: SheepitConfig(
                apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64),
                apiUrl: "https://stub.invalid",
                flushInterval: 3600,
                flushSize: 1000,
                configRefreshInterval: 3600,
                retryAttempts: 1,
                crashes: CrashConfig(enabled: false)
            ),
            now: { Date() },
            urlProtocolClasses: [AttributionCaptureProtocol.self],
            identifyRetryDelays: identifyRetryDelays
        )
        client.deviceRotationRetryDelayForTesting = { _ in .milliseconds(20) }
        return client
    }

    private func user(_ prefix: String) -> String { "\(prefix)-\(UUID().uuidString)" }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private func startedClient() async -> SheepitClient {
        let client = makeClient()
        let started = await waitUntil { AttributionCaptureProtocol.configRequestCount >= 1 }
        XCTAssertTrue(started, "precondition: the start-up config fetch ran")
        let registered = await waitUntil {
            client.getRecentDiagnostics().contains { $0.code == "identity.device_registered" }
        }
        XCTAssertTrue(registered, "precondition: the launch registration answered")
        // The refetch decision it owes is made before a test takes its counts: skipped (a resolved
        // body already applies), or sent (registration answered before the launch fetch landed).
        let decided = await waitUntil {
            let codes = client.getRecentDiagnostics().map(\.code)
            return codes.contains("config.registration_refetch_skipped")
                || (codes.contains("config.refetch_on_registration") && AttributionCaptureProtocol.configRequestCount >= 2)
        }
        XCTAssertTrue(decided, "precondition: the registration's config refetch was decided")
        return client
    }

    /// Every await in this suite goes through here: a lost wakeup fails the test after `seconds`
    /// instead of hanging the run. Returns nil when it timed out.
    @discardableResult
    private func bounded<T: Sendable>(
        _ seconds: TimeInterval = 15,
        _ operation: @escaping @Sendable () async -> T
    ) async -> T? {
        let result = LockedBox<T?>(nil)
        let done = expectation(description: "bounded await")
        Task {
            result.set(await operation())
            done.fulfill()
        }
        await fulfillment(of: [done], timeout: seconds)
        return result.get()
    }

    private func posts(for userId: String) -> Int {
        AttributionCaptureProtocol.identifyUserIds.filter { $0 == userId }.count
    }

    private func newCheckout(_ client: SheepitClient) -> Bool? {
        client.flag("new_checkout", default: .bool(false)).boolValue
    }

    // MARK: - identify(userId:timeout:)

    func testANewUserIsReadyOnceTheConfigFetchedForThemIsApplied() async {
        let client = await startedClient()
        defer { client.destroy() }
        AttributionCaptureProtocol.serveConfig(Self.configBody(newCheckout: false))
        await bounded { await client.refreshConfigForTesting() }
        XCTAssertEqual(newCheckout(client), false, "precondition: the anonymous value is applied")
        AttributionCaptureProtocol.serveConfig(Self.configBody(newCheckout: true))
        let userA = user("a")

        let outcome = await bounded { await client.identify(userId: userA, timeout: .seconds(5)) }

        XCTAssertEqual(outcome, .ready)
        XCTAssertEqual(newCheckout(client), true, "flag() answers for the user right after .ready")
        XCTAssertEqual(client.context.serverHeldUser.user, .known(userA))
    }

    func testAFailedRefetchAfterTheBindStillEndsReadyWhenTheNextFetchApplies() async {
        let client = await startedClient()
        defer { client.destroy() }
        AttributionCaptureProtocol.serveConfig(Self.configBody(newCheckout: true))
        AttributionCaptureProtocol.failNextConfigRequests(1)
        let before = AttributionCaptureProtocol.configRequestCount
        let userA = user("a")

        let wait = Task { await client.identify(userId: userA, timeout: .seconds(5)) }
        let refetched = await waitUntil { AttributionCaptureProtocol.configRequestCount == before + 1 }
        XCTAssertTrue(refetched, "precondition: the refetch after the bind ran and failed")
        await bounded { await client.awaitIdentityPostForTesting() }
        await bounded { await client.refreshConfigForTesting() }

        let outcome = await bounded { await wait.value }
        XCTAssertEqual(outcome, .ready, "keyed on the applied config, not on the refetch returning")
        XCTAssertEqual(newCheckout(client), true)
    }

    func testAFailedRefetchTimesOutWhenNoLaterFetchLandsInTime() async {
        let client = await startedClient()
        defer { client.destroy() }
        AttributionCaptureProtocol.serveConfig(Self.configBody(newCheckout: true))
        AttributionCaptureProtocol.failNextConfigRequests(1)
        let userA = user("a")

        let outcome = await bounded { await client.identify(userId: userA, timeout: .milliseconds(500)) }

        XCTAssertEqual(outcome, .timedOut)
        XCTAssertEqual(client.context.serverHeldUser.user, .known(userA), "the bind itself succeeded")
    }

    func testARejectedIdentifyFails() async {
        let client = await startedClient()
        defer { client.destroy() }
        let userA = user("a")
        AttributionCaptureProtocol.setIdentifyReply(.status(400), for: userA)

        let outcome = await bounded { await client.identify(userId: userA, timeout: .seconds(5)) }

        XCTAssertEqual(outcome, .failed)
    }

    func testAnExhaustedRetryLadderFails() async {
        let client = makeClient(identifyRetryDelays: [0.01])
        defer { client.destroy() }
        let userA = user("a")
        AttributionCaptureProtocol.setIdentifyReply(.status(500), for: userA)

        let outcome = await bounded { await client.identify(userId: userA, timeout: .seconds(5)) }

        XCTAssertEqual(outcome, .failed)
        XCTAssertEqual(posts(for: userA), 2, "precondition: the ladder retried, then ran out")
    }

    func testATimeoutShorterThanTheIdentifyRequestLeavesTheRequestToBindAfterwards() async {
        let client = await startedClient()
        defer { client.destroy() }
        let userA = user("a")
        AttributionCaptureProtocol.setIdentifyReply(.hold, for: userA)

        let outcome = await bounded { await client.identify(userId: userA, timeout: .milliseconds(200)) }
        XCTAssertEqual(outcome, .timedOut)

        AttributionCaptureProtocol.releaseHeldIdentify()
        await bounded { await client.awaitIdentityPostForTesting() }
        XCTAssertEqual(client.context.serverHeldUser.user, .known(userA), "the POST carried on and bound")
    }

    func testResetDuringTheWaitFailsItEvenIfTheRequestThenSucceeds() async {
        let client = await startedClient()
        defer { client.destroy() }
        AttributionCaptureProtocol.serveConfig(Self.configBody(newCheckout: true))
        let userA = user("a")
        AttributionCaptureProtocol.setIdentifyReply(.hold, for: userA)

        let wait = Task { await client.identify(userId: userA, timeout: .seconds(3)) }
        let onWire = await waitUntil { posts(for: userA) == 1 }
        XCTAssertTrue(onWire, "precondition: the identify request is on the wire")
        let start = Date()
        client.reset()

        // Still on the wire: the reset itself ends the wait, not the request's answer.
        let outcome = await bounded { await wait.value }
        XCTAssertEqual(outcome, .failed)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        AttributionCaptureProtocol.releaseHeldIdentify()
        await bounded { await client.awaitIdentityPostForTesting() }
        XCTAssertNotEqual(client.context.serverHeldUser.user, .known(userA), "the answer described the abandoned row")
    }

    func testTheSameUserAlreadyBoundWithTheirConfigIsReadyWithoutARequest() async {
        let client = await startedClient()
        defer { client.destroy() }
        AttributionCaptureProtocol.serveConfig(Self.configBody(newCheckout: true))
        let userA = user("a")
        let first = await bounded { await client.identify(userId: userA, timeout: .seconds(5)) }
        XCTAssertEqual(first, .ready, "precondition")
        let configRequests = AttributionCaptureProtocol.configRequestCount
        let identifyRequests = AttributionCaptureProtocol.identifyUserIds.count

        let outcome = await bounded { await client.identify(userId: userA, timeout: .seconds(5)) }

        XCTAssertEqual(outcome, .ready)
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(AttributionCaptureProtocol.configRequestCount, configRequests, "no config request")
        XCTAssertEqual(AttributionCaptureProtocol.identifyUserIds.count, identifyRequests, "no identify request")
    }

    func testTheSameUserBoundWithoutTheirConfigWaitsForAFetchForThem() async {
        let client = await startedClient()
        defer { client.destroy() }
        AttributionCaptureProtocol.serveConfig(Self.configBody(newCheckout: true))
        AttributionCaptureProtocol.failNextConfigRequests(1)
        let userA = user("a")
        client.identify(userId: userA)
        await bounded { await client.awaitIdentityPostForTesting() }
        XCTAssertEqual(client.context.serverHeldUser.user, .known(userA), "precondition: bound")
        XCTAssertEqual(newCheckout(client), false, "precondition: the refetch for them failed")
        let configRequests = AttributionCaptureProtocol.configRequestCount

        // Two waits at once share one fetch.
        let second = Task { await client.identify(userId: userA, timeout: .seconds(5)) }
        let outcome = await bounded { await client.identify(userId: userA, timeout: .seconds(5)) }
        let secondOutcome = await bounded { await second.value }

        XCTAssertEqual(outcome, .ready)
        XCTAssertEqual(secondOutcome, .ready)
        XCTAssertEqual(newCheckout(client), true)
        XCTAssertEqual(AttributionCaptureProtocol.configRequestCount, configRequests + 1, "one fetch for them")
        XCTAssertEqual(posts(for: userA), 1, "no second identify request")
    }

    func testTheSameUserPreviouslyRejectedFailsAtOnce() async {
        let client = await startedClient()
        defer { client.destroy() }
        let userA = user("a")
        AttributionCaptureProtocol.setIdentifyReply(.status(400), for: userA)
        client.identify(userId: userA)
        await bounded { await client.awaitIdentityPostForTesting() }

        let start = Date()
        let outcome = await bounded { await client.identify(userId: userA, timeout: .seconds(10)) }

        XCTAssertEqual(outcome, .failed)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1, "never sits out the timeout")
        XCTAssertEqual(posts(for: userA), 1, "nothing re-sent")
    }

    func testCancellingTheCallerEndsTheWaitButNotTheRequest() async {
        let client = await startedClient()
        defer { client.destroy() }
        let userA = user("a")
        AttributionCaptureProtocol.setIdentifyReply(.hold, for: userA)

        let wait = Task { await client.identify(userId: userA, timeout: .seconds(30)) }
        let onWire = await waitUntil { posts(for: userA) == 1 }
        XCTAssertTrue(onWire, "precondition: the identify request is on the wire")
        let start = Date()
        wait.cancel()
        let outcome = await bounded { await wait.value }

        XCTAssertEqual(outcome, .timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
        AttributionCaptureProtocol.releaseHeldIdentify()
        await bounded { await client.awaitIdentityPostForTesting() }
        XCTAssertEqual(client.context.serverHeldUser.user, .known(userA), "the POST was not cancelled")
    }

    func testIdentifyingAnotherUserSupersedesTheWait() async {
        let client = await startedClient()
        defer { client.destroy() }
        let userA = user("a")
        let userB = user("b")
        AttributionCaptureProtocol.setIdentifyReply(.hold, for: userA)

        let wait = Task { await client.identify(userId: userA, timeout: .seconds(10)) }
        let onWire = await waitUntil { posts(for: userA) == 1 }
        XCTAssertTrue(onWire, "precondition: the identify request is on the wire")
        client.identify(userId: userB)

        let outcome = await bounded { await wait.value }
        XCTAssertEqual(outcome, .failed)
        AttributionCaptureProtocol.releaseHeldIdentify()
    }

    func testAUserIdOverTheLimitFailsAndADestroyedClientFails() async {
        let client = await startedClient()
        let tooLong = String(repeating: "x", count: SDKDefaults.userIdMaxLength + 1)
        let refused = await bounded { await client.identify(userId: tooLong, timeout: .seconds(5)) }
        XCTAssertEqual(refused, .failed)
        client.destroy()
        let userB = user("b")
        let destroyed = await bounded { await client.identify(userId: userB, timeout: .seconds(5)) }
        XCTAssertEqual(destroyed, .failed)
    }

    // MARK: - awaitConfig(timeout:)

    func testAwaitConfigIsTrueAtOnceWithACachedConfig() async {
        let first = await startedClient()
        AttributionCaptureProtocol.serveConfig(Self.configBody(newCheckout: true))
        await bounded { await first.refreshConfigForTesting() }
        first.destroy()
        let requests = AttributionCaptureProtocol.configRequestCount
        AttributionCaptureProtocol.failNextConfigRequests(1)

        let client = makeClient()
        defer { client.destroy() }
        let fetched = await waitUntil { AttributionCaptureProtocol.configRequestCount > requests }
        XCTAssertTrue(fetched, "precondition: the cache was loaded and the start-up fetch failed")

        let applied = await bounded { await client.awaitConfig(timeout: .zero) }
        XCTAssertEqual(applied, true, "applied from the cache")
    }

    func testAwaitConfigWaitsForTheFirstFetchOnAFreshInstall() async {
        let client = await startedClient()
        defer { client.destroy() }
        let wait = Task { await client.awaitConfig(timeout: .seconds(5)) }
        try? await Task.sleep(for: .milliseconds(50))
        AttributionCaptureProtocol.serveConfig(Self.configBody(newCheckout: true))
        await bounded { await client.refreshConfigForTesting() }

        let applied = await bounded { await wait.value }
        XCTAssertEqual(applied, true)
        XCTAssertEqual(newCheckout(client), true)
    }

    func testAwaitConfigIsFalseOnTimeoutAndAfterDestroy() async {
        let client = await startedClient()
        let timedOut = await bounded { await client.awaitConfig(timeout: .milliseconds(100)) }
        XCTAssertEqual(timedOut, false)

        let wait = Task { await client.awaitConfig(timeout: .seconds(30)) }
        try? await Task.sleep(for: .milliseconds(50))
        let start = Date()
        client.destroy()
        let destroyed = await bounded { await wait.value }
        XCTAssertEqual(destroyed, false)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1)
    }

    func testAwaitConfigIsFalseAgainAfterReset() async {
        let client = await startedClient()
        defer { client.destroy() }
        AttributionCaptureProtocol.serveConfig(Self.configBody(newCheckout: true))
        await bounded { await client.refreshConfigForTesting() }
        let before = await bounded { await client.awaitConfig(timeout: .zero) }
        XCTAssertEqual(before, true, "precondition")
        AttributionCaptureProtocol.failNextConfigRequests(100)

        client.reset()

        let after = await bounded { await client.awaitConfig(timeout: .zero) }
        XCTAssertEqual(after, false, "reset() cleared the config in memory")
    }

    // MARK: - IdentifyWaiters races

    /// Many waits racing their own signals, timeouts and cancellations. A double resume traps the
    /// checked continuation; a lost wakeup turns a `.ready` into a `.timedOut` after 5 s.
    func testEveryWaitResolvesExactlyOnceUnderRacingSignals() async {
        for _ in 0..<20 {
            let held = LockedBox<ServerHeldUser>(.known("u"))
            let waiters = IdentifyWaiters(serverHeldUser: { held.get() })
            // A failure before a wait is armed does not fail it, so that signal waits for every arm.
            let armedForFailure = LockedBox(0)
            let bounded = await bounded(30) {
                await withTaskGroup(of: (String, IdentifyOutcome).self) { group in
                for index in 0..<60 {
                    group.addTask {
                        switch index % 4 {
                        case 0:
                            guard let id = waiters.register(.config) else { return ("config", .failed) }
                            return ("config", await waiters.wait(id, timeout: .seconds(5)))
                        case 1:
                            guard let id = waiters.register(.identify("u")) else { return ("ready", .failed) }
                            waiters.arm(id, failingFrom: 1_000)
                            return ("ready", await waiters.wait(id, timeout: .seconds(5)))
                        case 2:
                            guard let id = waiters.register(.identify("v")) else { return ("failed", .failed) }
                            waiters.arm(id, failingFrom: 1)
                            armedForFailure.mutate { $0 += 1 }
                            return ("failed", await waiters.wait(id, timeout: .seconds(5)))
                        default:
                            let task = Task { () -> IdentifyOutcome in
                                guard let id = waiters.register(.identify("u")) else { return .timedOut }
                                return await waiters.wait(id, timeout: .milliseconds(Int.random(in: 0...5)))
                            }
                            if Bool.random() { task.cancel() }
                            return ("any", await task.value)
                        }
                    }
                }
                group.addTask {
                    try? await Task.sleep(for: .microseconds(Int.random(in: 0...500)))
                    waiters.configApplied(.fetchedUnder("u"))
                    waiters.configAppliedOutsideGate()
                    return ("signal", .ready)
                }
                group.addTask {
                    while armedForFailure.get() < 15 { await Task.yield() }
                    waiters.identifyFailed("v", sequence: 5)
                    waiters.identifyBound("u")
                    return ("signal", .ready)
                }
                var all: [(String, IdentifyOutcome)] = []
                for await outcome in group { all.append(outcome) }
                return all
                }
            }
            let outcomes = bounded ?? []
            XCTAssertEqual(outcomes.count, 62)
            for (expected, outcome) in outcomes {
                switch expected {
                case "config", "ready": XCTAssertEqual(outcome, .ready, expected)
                case "failed": XCTAssertEqual(outcome, .failed)
                default: XCTAssertTrue([.ready, .timedOut].contains(outcome))
                }
            }
        }
    }

    func testCloseEndsEveryPendingWaitAndRefusesNewOnes() async {
        let waiters = IdentifyWaiters(serverHeldUser: { .unknown })
        let results = await bounded(30) {
            await withTaskGroup(of: IdentifyOutcome.self) { group in
            for index in 0..<40 {
                group.addTask {
                    let wait: IdentifyWaiters.Wait = index.isMultiple(of: 2) ? .config : .identify("u")
                    guard let id = waiters.register(wait) else { return .failed }
                    return await waiters.wait(id, timeout: .seconds(30))
                }
            }
            group.addTask {
                try? await Task.sleep(for: .milliseconds(20))
                waiters.close()
                return .failed
            }
            var all: [IdentifyOutcome] = []
            for await result in group { all.append(result) }
            return all
            }
        }
        XCTAssertEqual(results, Array(repeating: .failed, count: 41))
        XCTAssertNil(waiters.register(.config))
    }

    /// A wait whose config was applied but not yet decided outside the reset gate is still ended by
    /// its own timeout: a decided-but-unresumed wait must never be unreachable (it hung the suite).
    func testATimeoutStillEndsAWaitWhenTheOutsideGatePassNeverRuns() async {
        let waiters = IdentifyWaiters(serverHeldUser: { .unknown })
        let id = waiters.register(.config)
        waiters.configApplied(.unknown)
        let outcome = await bounded(5) { [waiters] in
            guard let id else { return IdentifyOutcome.failed }
            return await waiters.wait(id, timeout: .milliseconds(100))
        }
        XCTAssertEqual(outcome, .timedOut)
    }

    /// The bind itself can make a wait ready: here the config for the user is already applied and
    /// the refetch after the re-bind fails, so no later apply could.
    func testARebindOfTheUserWhoseConfigIsAppliedIsReadyWithoutANewConfig() async {
        let client = await startedClient()
        defer { client.destroy() }
        AttributionCaptureProtocol.serveConfig(Self.configBody(newCheckout: true))
        let userA = user("a")
        let first = await bounded { await client.identify(userId: userA, timeout: .seconds(5)) }
        XCTAssertEqual(first, .ready, "precondition")
        client.context.markServerHeldUserUnknown()
        AttributionCaptureProtocol.failNextConfigRequests(100)

        let outcome = await bounded { await client.identify(userId: userA, timeout: .seconds(3)) }

        XCTAssertEqual(outcome, .ready)
        XCTAssertEqual(posts(for: userA), 2, "precondition: the same user was re-bound")
    }

    // MARK: - Fix round (PR #1453)

    /// A POST for the user queued while the row is already known to hold them goes out, marks the
    /// row unknown and fails: a wait armed in that window must fail, not run to its timeout.
    func testAnInFlightRePostForAnAlreadyBoundUserThatFailsFailsTheWait() async {
        let client = await startedClient()
        defer { client.destroy() }
        let userA = user("a")
        let userB = user("b")
        AttributionCaptureProtocol.setIdentifyReply(.sequence([.hold, .status(400)]), for: userA)
        client.identify(userId: userA) // POST 1, held on the wire
        let onWire = await waitUntil { posts(for: userA) == 1 }
        XCTAssertTrue(onWire, "precondition: POST 1 is on the wire")
        client.identify(userId: userB) // POST 2, queued behind it
        client.identify(userId: userA) // POST 3, queued; answered 400
        // POST 1's refetch is slow and unreadable, so the row stays known to hold A, with no config
        // for A applied, while POST 2 and 3 wait.
        AttributionCaptureProtocol.scriptConfig([("{}", 1.5)])
        AttributionCaptureProtocol.releaseHeldIdentify()
        let bound = await waitUntil { client.context.serverHeldUser.user == .known(userA) }
        XCTAssertTrue(bound, "precondition: POST 1 bound A")

        let start = Date()
        let outcome = await bounded { await client.identify(userId: userA, timeout: .seconds(8)) }

        XCTAssertEqual(outcome, .failed, "POST 3 for A failed after the wait was armed")
        XCTAssertLessThan(Date().timeIntervalSince(start), 6)
        XCTAssertEqual(posts(for: userA), 2, "precondition: POST 3 was sent")
    }

    /// The awaited-identify refetch is one at a time; a failed one must release that, or no later
    /// call could fetch the user's config again.
    func testAFailedAwaitedRefetchLetsALaterCallFetchAgain() async {
        let client = await startedClient()
        defer { client.destroy() }
        AttributionCaptureProtocol.serveConfig(Self.configBody(newCheckout: true))
        AttributionCaptureProtocol.failNextConfigRequests(1)
        let userA = user("a")
        client.identify(userId: userA)
        await bounded { await client.awaitIdentityPostForTesting() }
        XCTAssertEqual(client.context.serverHeldUser.user, .known(userA), "precondition: bound, no config")
        AttributionCaptureProtocol.failNextConfigRequests(1)
        let before = AttributionCaptureProtocol.configRequestCount

        let first = await bounded { await client.identify(userId: userA, timeout: .milliseconds(500)) }
        XCTAssertEqual(first, .timedOut, "its fetch failed")
        XCTAssertEqual(AttributionCaptureProtocol.configRequestCount, before + 1)

        let second = await bounded { await client.identify(userId: userA, timeout: .seconds(5)) }
        XCTAssertEqual(second, .ready, "a later call fetched again")
        XCTAssertEqual(AttributionCaptureProtocol.configRequestCount, before + 2)
    }

    /// An outcome decided before the caller installed its continuation is not delivered yet:
    /// `reset()` overrides an undelivered `.ready`.
    func testResetOverridesAnUndeliveredReady() async {
        let held = LockedBox<ServerHeldUser>(.known("u"))
        let waiters = IdentifyWaiters(serverHeldUser: { held.get() })
        waiters.configApplied(.fetchedUnder("u"))
        let config = waiters.register(.config)
        let identify = waiters.register(.identify("u"))
        if let identify { waiters.arm(identify, failingFrom: 1) }
        XCTAssertEqual(identify.map(waiters.isResolved), true, "precondition: decided .ready, not delivered")

        waiters.configCleared()
        waiters.resetHappened()

        let configOutcome = await bounded(5) { [waiters] in
            guard let config else { return IdentifyOutcome.failed }
            return await waiters.wait(config, timeout: .milliseconds(100))
        }
        let identifyOutcome = await bounded(5) { [waiters] in
            guard let identify else { return IdentifyOutcome.ready }
            return await waiters.wait(identify, timeout: .seconds(2))
        }
        XCTAssertEqual(configOutcome, .timedOut, "the cleared config no longer counts; it waits again")
        XCTAssertEqual(identifyOutcome, .failed)
    }

    /// A failure for another user must not hide this user's earlier failure from a wait armed later.
    func testAFailureForAnotherUserDoesNotHideThisUsersFailure() async {
        let waiters = IdentifyWaiters(serverHeldUser: { .unknown })
        waiters.identifyFailed("a", sequence: 5)
        waiters.identifyFailed("b", sequence: 6)
        let id = waiters.register(.identify("a"))
        if let id { waiters.arm(id, failingFrom: 5) }

        let outcome = await bounded(5) { [waiters] in
            guard let id else { return IdentifyOutcome.ready }
            return await waiters.wait(id, timeout: .seconds(2))
        }
        XCTAssertEqual(outcome, .failed)
    }

    func testABindClearsTheUsersRecordedFailure() async {
        let waiters = IdentifyWaiters(serverHeldUser: { .unknown })
        waiters.identifyFailed("a", sequence: 5)
        waiters.identifyBound("a")
        let id = waiters.register(.identify("a"))
        if let id { waiters.arm(id, failingFrom: 5) }

        let outcome = await bounded(5) { [waiters] in
            guard let id else { return IdentifyOutcome.ready }
            return await waiters.wait(id, timeout: .milliseconds(100))
        }
        XCTAssertEqual(outcome, .timedOut)
    }

    func testCloseLeavesNoEntryBehind() async {
        let waiters = IdentifyWaiters(serverHeldUser: { .known("u") })
        waiters.configApplied(.fetchedUnder("u"))
        let config = waiters.register(.config) // decided .ready, never installed
        let identify = waiters.register(.identify("u")) // registered, never armed
        XCTAssertEqual(waiters.countForTesting, 2, "precondition")

        waiters.close()

        XCTAssertEqual(waiters.countForTesting, 0)
        let outcomes = await bounded(5) { [waiters] in
            var all: [IdentifyOutcome] = []
            for id in [config, identify].compactMap({ $0 }) { all.append(await waiters.wait(id, timeout: .seconds(2))) }
            return all
        }
        XCTAssertEqual(outcomes, [.failed, .failed])
    }

    /// `awaitConfig(timeout: .zero)` with a config applied is decided `.ready` at registration; a
    /// `reset()` before the caller installs its continuation must end it `false`, not leave it waiting
    /// with no timeout left to end it.
    func testAResetBetweenRegistrationAndInstallEndsAZeroTimeoutAwaitConfigFalse() async {
        let client = await startedClient()
        defer { client.destroy() }
        AttributionCaptureProtocol.serveConfig(Self.configBody(newCheckout: true))
        await bounded { await client.refreshConfigForTesting() }
        AttributionCaptureProtocol.failNextConfigRequests(100)
        let resetOnce = LockedBox(false)
        client.identifyWaiters.beforeInstallHookForTesting.value = { [client] _ in
            guard !resetOnce.get() else { return }
            resetOnce.set(true)
            client.reset()
        }

        let applied = await bounded(5) { await client.awaitConfig(timeout: .zero) }

        XCTAssertEqual(applied, false, "returned, and false: the config it saw was cleared")
        XCTAssertTrue(resetOnce.get(), "precondition: the reset landed before install")
    }

    /// The same with a short timeout whose timer fires before the reset lands.
    func testAResetAfterTheTimerFiredStillEndsAnUndeliveredConfigWait() async {
        let waiters = IdentifyWaiters(serverHeldUser: { .unknown })
        waiters.configApplied(.unknown)
        let id = waiters.register(.config)
        waiters.beforeInstallHookForTesting.value = { _ in
            Thread.sleep(forTimeInterval: 0.15) // the 20 ms timer fires in here, a no-op on a decided wait
            waiters.configCleared()
        }

        let outcome = await bounded(5) { [waiters] in
            guard let id else { return IdentifyOutcome.ready }
            return await waiters.wait(id, timeout: .milliseconds(20))
        }

        XCTAssertEqual(outcome, .timedOut)
    }
}
