import XCTest
@testable import SheepitKit

/// Server state is kept per (apiUrl, environment, apiKey) (`StorageScope`). The bug: 0.7.0 kept it
/// under fixed keys, so a build on environment B read `gt_device_registered` written for A, skipped
/// registration, and its identify POST 404'd (the device row is per environment). Recorded as a
/// rejection, that install stayed anonymous. `AttributionCaptureProtocol.modelEnvironmentRows` gives
/// the stub the real per-environment rows, so a skipped registration shows up as a 404 here too.
final class IdentityScopeTests: XCTestCase {
    private static let configA = makeConfig(environment: "staging", key: "lp_pub_aaa_" + String(repeating: "a", count: 64))
    private static let configB = makeConfig(environment: "production", key: "lp_pub_bbb_" + String(repeating: "b", count: 64))

    private static func makeConfig(environment: String, key: String) -> SheepitConfig {
        SheepitConfig(
            apiKey: key,
            environment: environment,
            apiUrl: "https://stub.invalid",
            flushInterval: 3600,
            flushSize: 1000,
            configRefreshInterval: 3600,
            retryAttempts: 1,
            crashes: CrashConfig(enabled: false)
        )
    }

    override func setUp() {
        super.setUp()
        SharedSDKStorage.clear()
        AttributionCaptureProtocol.reset()
        AttributionCaptureProtocol.modelEnvironmentRows = true
        AttributionCaptureProtocol.echoRegisteredDeviceId = true
        AttributionCaptureProtocol.registerDeviceId = "dev_minted_\(UUID().uuidString)"
    }

    override func tearDown() {
        SharedSDKStorage.clear()
        AttributionCaptureProtocol.reset()
        super.tearDown()
    }

    private func makeClient(_ config: SheepitConfig) -> SheepitClient {
        SheepitClient.createForTesting(
            config: config,
            now: { Date() },
            urlProtocolClasses: [AttributionCaptureProtocol.self],
            identifyRetryDelays: []
        )
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private func posts(for userId: String) -> Int {
        AttributionCaptureProtocol.identifyUserIds.filter { $0 == userId }.count
    }

    /// A client on `configA` that registered and bound `userId`, destroyed.
    private func bindInScopeA(_ userId: String) async throws -> String {
        let client = makeClient(Self.configA)
        client.identify(userId: userId)
        await client.awaitIdentityPostForTesting()
        XCTAssertEqual(client.context.serverHeldUser.user, .known(userId), "precondition: bound in A")
        let deviceId = client.context.deviceId
        client.destroy()
        return deviceId
    }

    // MARK: - (a) a new scope registers and binds, with no 404

    func testANewScopeRegistersTheSharedDeviceAndBindsTheStoredUserWithoutA404() async throws {
        let user = "user-\(UUID().uuidString)"
        let deviceId = try await bindInScopeA(user)
        let registersBefore = AttributionCaptureProtocol.registerBodies.count
        let identifiesBefore = AttributionCaptureProtocol.identifyDeviceIds.count
        let configsBefore = AttributionCaptureProtocol.configDeviceIds.count

        // Nothing but construction: the launch identify POST is the SDK's own.
        let client = makeClient(Self.configB)
        defer { client.destroy() }
        await client.awaitIdentityPostForTesting()

        let registers = Array(AttributionCaptureProtocol.registerBodies.dropFirst(registersBefore))
        XCTAssertEqual(registers.count, 1, "B's slot holds no registration, so B registers")
        XCTAssertEqual(registers.first?["device_id"] as? String, deviceId, "the shared device id, not a fresh one")
        XCTAssertEqual(AttributionCaptureProtocol.registerEnvironments.last, "production")
        XCTAssertEqual(Array(AttributionCaptureProtocol.identifyDeviceIds.dropFirst(identifiesBefore)), [deviceId])
        XCTAssertEqual(AttributionCaptureProtocol.identifyNotFoundCount, 0, "0.7.0 answered this launch with a 404")
        XCTAssertEqual(client.context.deviceId, deviceId)
        XCTAssertEqual(client.context.serverHeldUser.user, .known(user))
        // The bind's refetch: config for this device, labelled with the user.
        let seen = await waitUntil {
            AttributionCaptureProtocol.configDeviceIds.dropFirst(configsBefore).contains(deviceId)
        }
        XCTAssertTrue(seen, "B's config is fetched for the shared device")
        XCTAssertEqual(client.status().identity?.serverUser, .user(user))
    }

    // MARK: - (d) returning to a scope finds its slots intact

    func testReturningToAScopeDoesNotRegisterAgain() async throws {
        let user = "user-\(UUID().uuidString)"
        _ = try await bindInScopeA(user)
        let clientB = makeClient(Self.configB)
        await clientB.awaitIdentityPostForTesting()
        XCTAssertEqual(clientB.context.serverHeldUser.user, .known(user), "precondition: bound in B")
        clientB.destroy()
        let registersBefore = AttributionCaptureProtocol.registerBodies.count

        let clientA = makeClient(Self.configA)
        defer { clientA.destroy() }
        await clientA.awaitIdentityPostForTesting()

        XCTAssertEqual(AttributionCaptureProtocol.registerBodies.count, registersBefore, "A's registration is still in A's slot")
        XCTAssertEqual(AttributionCaptureProtocol.identifyNotFoundCount, 0)
        XCTAssertEqual(clientA.context.serverHeldUser.user, .known(user))
    }

    // MARK: - (b, c) identify() with the current user

    func testIdentifyingTheCurrentUserSendsAPostWhileTheServerLabelDoesNotNameThem() async throws {
        let client = makeClient(Self.configA)
        defer { client.destroy() }
        let user = "user-\(UUID().uuidString)"
        client.identify(userId: user)
        await client.awaitIdentityPostForTesting()
        // What a relaunch whose last POST went unanswered starts from: the app names the user, and
        // the SDK cannot say what the row holds. (A failed ladder in THIS session waits for the next
        // retry trigger instead: see the exhausted test below.)
        client.context.setServerHeldUser(.unknown)

        client.identify(userId: user)
        await client.awaitIdentityPostForTesting()

        XCTAssertEqual(posts(for: user), 2, "the same app user, but the server row was never bound to them")
        XCTAssertEqual(client.context.serverHeldUser.user, .known(user))
    }

    /// End to end: a POST that fails leaves the label unknown on disk, and the next launch in the same
    /// scope sends it again and binds.
    func testAFailedIdentifyIsSentAgainByTheNextLaunchInTheSameScope() async throws {
        let user = "user-\(UUID().uuidString)"
        AttributionCaptureProtocol.setIdentifyReply(.sequence([.status(500), .status(200)]), for: user)
        let first = makeClient(Self.configA)
        first.identify(userId: user)
        await first.awaitIdentityPostForTesting()
        XCTAssertEqual(first.context.serverHeldUser.user, .unknown, "precondition: the POST failed")
        first.destroy()

        let relaunched = makeClient(Self.configA)
        defer { relaunched.destroy() }
        await relaunched.awaitIdentityPostForTesting()

        XCTAssertEqual(posts(for: user), 2)
        XCTAssertEqual(relaunched.context.serverHeldUser.user, .known(user))
    }

    func testIdentifyingTheCurrentUserSendsNothingWhileTheServerHoldsThem() async throws {
        let client = makeClient(Self.configA)
        defer { client.destroy() }
        let user = "user-\(UUID().uuidString)"
        client.identify(userId: user)
        await client.awaitIdentityPostForTesting()
        XCTAssertEqual(client.context.serverHeldUser.user, .known(user))

        client.identify(userId: user)
        await client.awaitIdentityPostForTesting()

        XCTAssertEqual(posts(for: user), 1)
        XCTAssertEqual(client.getRecentDiagnostics().filter { $0.code == "identity.identify_noop" }.count, 1)
    }

    func testIdentifyingTheCurrentUserAfterARejectionSendsNothingAndSaysWhy() async throws {
        let client = makeClient(Self.configA)
        defer { client.destroy() }
        let user = "user-\(UUID().uuidString)"
        AttributionCaptureProtocol.setIdentifyReply(.status(400), for: user)
        client.identify(userId: user)
        await client.awaitIdentityPostForTesting()

        client.identify(userId: user)
        await client.awaitIdentityPostForTesting()

        XCTAssertEqual(posts(for: user), 1, "a rejected user gets the same answer again")
        let noop = try XCTUnwrap(client.getRecentDiagnostics().last { $0.code == "identity.identify_noop" })
        XCTAssertEqual(noop.data?["reason"]?.value as? String, "rejected")
    }

    // MARK: - (e) upgrade from unscoped storage

    func testAnUpgradeDiscardsUnscopedServerStateReRegistersAndAdoptsTheOfflineQueue() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: SharedSDKStorage.suite))
        let user = "user-\(UUID().uuidString)"
        let deviceId = "legacy-device-\(UUID().uuidString)"
        let held = try JSONEncoder().encode(ServerHeldUser.known(user))
        defaults.set(deviceId, forKey: StorageKeys.deviceId)
        defaults.set(Data(#"{"userId":"\#(user)"}"#.utf8), forKey: StorageKeys.identity)
        defaults.set("1", forKey: StorageKeys.deviceRegistered)
        defaults.set(deviceId, forKey: StorageKeys.deviceBindAttempted)
        defaults.set(held, forKey: StorageKeys.serverHeldUser)
        defaults.set(Data(#"{"data":{"flags":{},"experiments":{}}}"#.utf8), forKey: StorageKeys.sdkConfig)
        defaults.set(String(Date().timeIntervalSince1970), forKey: StorageKeys.sdkConfigCachedAt)
        defaults.set(held, forKey: StorageKeys.sdkConfigFetchedUnder)
        // An active backoff: on 0.7.0 it also kept registration from running.
        defaults.set(String(Date().timeIntervalSince1970 + 3600), forKey: StorageKeys.deviceRegistrationBackoffUntil)
        defaults.set(SDKDefaults.sdkVersion, forKey: StorageKeys.deviceRegistrationBackoffSDKVersion)
        let queued = (0..<3).map { index in
            #"{"eventId":"legacy-\#(index)-\#(UUID().uuidString)","eventName":"legacy_queued_\#(index)","#
                + #""deviceId":"\#(deviceId)","anonymousId":"a","sessionId":"s","platform":"ios","#
                + #""sdkVersion":"0.7.0","locale":"en_US","timezone":"UTC","timestamp":"2026-10-01T10:00:00.000Z"}"#
        }
        defaults.set(Data("[\(queued.joined(separator: ","))]".utf8), forKey: StorageKeys.offlineQueue)

        let client = makeClient(Self.configA)
        defer { client.destroy() }

        for key in StorageScope.scopedKeys {
            XCTAssertNil(defaults.object(forKey: key), "\(key): the unscoped copy is gone once work begins")
        }
        XCTAssertEqual(SharedSDKStorage.bindAttempted(), [deviceId], "the bind marker is shared, not discarded")
        let adopted = try XCTUnwrap(client.getRecentDiagnostics().last { $0.code == "identity.scope_adopted" })
        XCTAssertEqual(adopted.data?["legacy_server_state_discarded"]?.value as? Bool, true)
        XCTAssertEqual(adopted.data?["legacy_queue_events_adopted"]?.value as? Int, 3)

        await client.awaitIdentityPostForTesting()
        XCTAssertEqual(AttributionCaptureProtocol.registerBodies.map { $0["device_id"] as? String }, [deviceId],
                       "re-registered in this scope under the existing id")
        XCTAssertEqual(AttributionCaptureProtocol.identifyDeviceIds, [deviceId])
        XCTAssertEqual(AttributionCaptureProtocol.identifyNotFoundCount, 0)
        XCTAssertEqual(client.context.userId, user, "gt_identity, the app's own label, is kept")
        XCTAssertEqual(client.context.serverHeldUser.user, .known(user))

        await client.flush()
        for index in 0..<3 {
            XCTAssertNotNil(AttributionCaptureProtocol.event(named: "legacy_queued_\(index)"), "adopted event \(index) was sent")
        }
    }

    /// A process killed after the scoped queue was saved but before the legacy key was removed adopts
    /// the same events again; they must not be sent twice.
    func testAdoptingAQueueTwiceKeepsOneCopyOfEachEvent() throws {
        let storage = InMemoryStorage()
        let queue = OfflineQueue(storage: storage)
        let data = Data(#"[{"eventId":"e1","eventName":"a","deviceId":"d","anonymousId":"a","platform":"ios","sdkVersion":"0.7.0","locale":"en_US","timezone":"UTC","timestamp":"2026-10-01T10:00:00.000Z"}]"#.utf8)

        XCTAssertEqual(queue.adoptPersisted(data).kept, 1)
        XCTAssertEqual(queue.adoptPersisted(data).kept, 0)

        XCTAssertEqual(queue.peek().map(\.eventId), ["e1"])
    }

    func testADestroyedClientReportsNoIdentity() {
        let client = makeClient(Self.configA)
        client.destroy()
        XCTAssertNil(client.status().identity)
    }

    /// The upgrade runs once: a second launch finds nothing to adopt.
    func testASecondLaunchAfterTheUpgradeAdoptsNothing() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: SharedSDKStorage.suite))
        defaults.set("1", forKey: StorageKeys.deviceRegistered)
        let first = makeClient(Self.configA)
        XCTAssertNotNil(first.getRecentDiagnostics().last { $0.code == "identity.scope_adopted" })
        first.destroy()

        let second = makeClient(Self.configA)
        defer { second.destroy() }
        XCTAssertNil(second.getRecentDiagnostics().last { $0.code == "identity.scope_adopted" })
    }

    // MARK: - The bind marker is shared (review M2)

    /// An upgraded install that identified under 0.7.0 keeps its bind marker, so a logout before this
    /// launch sends any identify POST still moves to a fresh device. Discarding it left the user's row
    /// in use by the next, anonymous person.
    func testAnUpgradeKeepsTheBindMarkerSoAResetBeforeAnyIdentifyRotates() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: SharedSDKStorage.suite))
        let deviceId = "legacy-device-\(UUID().uuidString)"
        defaults.set(deviceId, forKey: StorageKeys.deviceId)
        defaults.set("1", forKey: StorageKeys.deviceRegistered)
        defaults.set(deviceId, forKey: StorageKeys.deviceBindAttempted)
        let client = makeClient(Self.configA)
        defer { client.destroy() }
        let registered = await waitUntil { client.status().identity?.deviceRegistered == true }
        XCTAssertTrue(registered, "precondition: re-registered in this scope")

        client.reset()

        XCTAssertNotEqual(client.context.deviceId, deviceId, "reset() must rotate a device a user may be bound to")
    }

    /// A bind in scope A, then a logout in scope B before B's own identify POST went out: B must still
    /// rotate, since the shared device's row in A holds the user.
    func testABindInOneScopeMakesAResetInAnotherRotate() async throws {
        let deviceId = try await bindInScopeA("user-\(UUID().uuidString)")
        AttributionCaptureProtocol.holdRegister = true
        let client = makeClient(Self.configB)
        defer {
            AttributionCaptureProtocol.releaseHeldRegister()
            client.destroy()
        }

        client.reset()

        XCTAssertNotEqual(client.context.deviceId, deviceId)
    }

    /// Two live clients on different keys share the device. B's identify POST goes out and is never
    /// answered; A logs out first and rotates. B's logout must still rotate: B's device may hold the
    /// user. A rotation used to delete the shared marker, so B kept the device.
    func testAResetInOneLiveClientDoesNotStopAnotherFromRotating() async throws {
        let deviceId = "device-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: SharedSDKStorage.suite))
        defaults.set(deviceId, forKey: StorageKeys.deviceId)
        for config in [Self.configA, Self.configB] {
            defaults.set(deviceId, forKey: SharedSDKStorage.key(StorageKeys.deviceRegistered, for: config))
        }
        AttributionCaptureProtocol.modelEnvironmentRows = false
        let clientA = makeClient(Self.configA)
        let clientB = makeClient(Self.configB)
        defer {
            AttributionCaptureProtocol.releaseHeldIdentify()
            clientA.destroy()
            clientB.destroy()
        }
        let user = "user-\(UUID().uuidString)"
        AttributionCaptureProtocol.setIdentifyReply(.hold, for: user)
        clientB.identify(userId: user)
        let sent = await waitUntil { AttributionCaptureProtocol.identifyUserIds.contains(user) }
        XCTAssertTrue(sent, "precondition: B's identify POST is on the wire")

        clientA.reset()
        XCTAssertNotEqual(clientA.context.deviceId, deviceId, "precondition: A rotated")
        clientB.reset()

        XCTAssertNotEqual(clientB.context.deviceId, deviceId, "B's unanswered POST may have bound the user")
    }

    /// The same, when the other client's bind lands on a replacement: A's identify gets a 404 and binds
    /// a fresh device, which rewrites the shared marker. B's own unanswered POST must still count.
    func testAReplacementInOneLiveClientDoesNotStopAnotherFromRotating() async throws {
        let deviceId = "device-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: SharedSDKStorage.suite))
        defaults.set(deviceId, forKey: StorageKeys.deviceId)
        for config in [Self.configA, Self.configB] {
            defaults.set(deviceId, forKey: SharedSDKStorage.key(StorageKeys.deviceRegistered, for: config))
        }
        AttributionCaptureProtocol.modelEnvironmentRows = false
        AttributionCaptureProtocol.echoRegisteredDeviceId = false
        let clientA = makeClient(Self.configA)
        let clientB = makeClient(Self.configB)
        defer {
            AttributionCaptureProtocol.releaseHeldIdentify()
            clientA.destroy()
            clientB.destroy()
        }
        let userB = "user-\(UUID().uuidString)"
        AttributionCaptureProtocol.setIdentifyReply(.hold, for: userB)
        clientB.identify(userId: userB)
        let sent = await waitUntil { AttributionCaptureProtocol.identifyUserIds.contains(userB) }
        XCTAssertTrue(sent, "precondition: B's identify POST is on the wire")
        let userA = "user-\(UUID().uuidString)"
        AttributionCaptureProtocol.setIdentifyReply(.sequence([.notFound, .status(200)]), for: userA)
        clientA.identify(userId: userA)
        await clientA.awaitIdentityPostForTesting()
        XCTAssertNotEqual(clientA.context.deviceId, deviceId, "precondition: A moved to a replacement")

        clientB.reset()

        XCTAssertNotEqual(clientB.context.deviceId, deviceId, "B's unanswered POST may have bound the user")
    }

    /// The same across launches, where no client remembers its own POST: launch 1, B's identify for
    /// device D is lost. Launch 2, B's launch identify is parked behind B's registration, which has
    /// not settled, and A takes a 404 and binds a replacement. The marker held one id, so A's bind
    /// overwrote D and B's logout kept a device that may hold the user.
    func testAReplacementInAnotherScopeDoesNotHideABindFromAnEarlierLaunch() async throws {
        let deviceId = "device-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: SharedSDKStorage.suite))
        defaults.set(deviceId, forKey: StorageKeys.deviceId)
        for config in [Self.configA, Self.configB] {
            defaults.set(deviceId, forKey: SharedSDKStorage.key(StorageKeys.deviceRegistered, for: config))
        }
        AttributionCaptureProtocol.modelEnvironmentRows = false
        AttributionCaptureProtocol.echoRegisteredDeviceId = false
        let user = "user-\(UUID().uuidString)"
        AttributionCaptureProtocol.setIdentifyReply(.lost, for: user)
        let launch1 = makeClient(Self.configB)
        launch1.identify(userId: user)
        await launch1.awaitIdentityPostForTesting()
        XCTAssertEqual(posts(for: user), 1, "precondition: B's POST went out in launch 1")
        launch1.destroy()

        defaults.removeObject(forKey: SharedSDKStorage.key(StorageKeys.deviceRegistered, for: Self.configB))
        AttributionCaptureProtocol.holdRegister = true
        AttributionCaptureProtocol.setIdentifyReply(.sequence([.notFound, .status(200)]), for: user)
        let clientB = makeClient(Self.configB)
        defer {
            AttributionCaptureProtocol.releaseHeldRegister()
            clientB.destroy()
        }
        let parked = await waitUntil { AttributionCaptureProtocol.registerRequestCount == 1 }
        XCTAssertTrue(parked, "precondition: B's launch registration is in flight")
        let clientA = makeClient(Self.configA)
        defer { clientA.destroy() }
        let replacing = await waitUntil { AttributionCaptureProtocol.registerRequestCount == 2 }
        XCTAssertTrue(replacing, "precondition: A's identify got a 404 and is registering a replacement")
        AttributionCaptureProtocol.releaseHeldRegister(index: 1)
        let replaced = await waitUntil {
            clientA.context.deviceId != deviceId && clientA.context.serverHeldUser.user == .known(user)
        }
        XCTAssertTrue(replaced, "precondition: A bound the replacement")
        XCTAssertEqual(posts(for: user), 3, "precondition: B sent nothing in launch 2")

        clientB.reset()

        XCTAssertNotEqual(clientB.context.deviceId, deviceId, "B's lost POST in launch 1 may have bound the user")
        XCTAssertEqual(SharedSDKStorage.bindAttempted(), [deviceId, clientA.context.deviceId])
    }

    /// 0.5.x had no bind marker: its persisted label was the only record that the device holds a user.
    /// Upgrading must keep that, so a logout before this launch's identify POST goes out still rotates.
    func testAnUpgradeFrom05KeepsItsBoundLabelSoAResetBeforeAnyIdentifyRotates() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: SharedSDKStorage.suite))
        let user = "user-\(UUID().uuidString)"
        let deviceId = "legacy-device-\(UUID().uuidString)"
        defaults.set(deviceId, forKey: StorageKeys.deviceId)
        defaults.set("1", forKey: StorageKeys.deviceRegistered)
        defaults.set(try JSONEncoder().encode(ServerHeldUser.known(user)), forKey: StorageKeys.serverHeldUser)
        defaults.set(Data(#"{"userId":"\#(user)"}"#.utf8), forKey: StorageKeys.identity)
        AttributionCaptureProtocol.holdRegister = true // the launch identify waits behind registration
        let client = makeClient(Self.configA)
        defer {
            AttributionCaptureProtocol.releaseHeldRegister()
            client.destroy()
        }
        XCTAssertTrue(AttributionCaptureProtocol.identifyUserIds.isEmpty, "precondition: no identify POST yet")

        client.reset()

        XCTAssertNotEqual(client.context.deviceId, deviceId)
    }

    // MARK: - The registered slot names the device (review R5)

    /// A logout in B rotates the shared id; A's slot still names the old one, so A registers the new
    /// id on its next launch, anonymously, and an identify then binds with no 404.
    func testAScopeRegistersTheDeviceAnotherScopeRotatedTo() async throws {
        _ = try await bindInScopeA("user-\(UUID().uuidString)")
        let clientB = makeClient(Self.configB)
        await clientB.awaitIdentityPostForTesting()
        let fresh = "dev_fresh_\(UUID().uuidString)"
        AttributionCaptureProtocol.registerDeviceId = fresh
        clientB.reset()
        let rotated = await waitUntil { clientB.context.deviceId == fresh }
        XCTAssertTrue(rotated, "precondition: B rotated to a fresh device")
        clientB.destroy()
        let registersBefore = AttributionCaptureProtocol.registerBodies.count

        let clientA = makeClient(Self.configA)
        defer { clientA.destroy() }
        let registered = await waitUntil { clientA.status().identity?.deviceRegistered == true }

        XCTAssertTrue(registered, "the anonymous launch registers the new id in A")
        XCTAssertEqual(AttributionCaptureProtocol.registerBodies.dropFirst(registersBefore).map { $0["device_id"] as? String }, [fresh])
        XCTAssertEqual(AttributionCaptureProtocol.registerEnvironments.last, "staging")
        let user = "user-\(UUID().uuidString)"
        clientA.identify(userId: user)
        await clientA.awaitIdentityPostForTesting()
        XCTAssertEqual(AttributionCaptureProtocol.identifyNotFoundCount, 0)
        XCTAssertEqual(AttributionCaptureProtocol.registerBodies.count, registersBefore + 1, "no replacement row")
        XCTAssertEqual(clientA.context.serverHeldUser.user, .known(user))
    }

    // MARK: - identify() with the current user does not loop (review M3)

    func testIdentifyingTheCurrentUserSendsNothingWhileRegistrationIsBackedOff() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: SharedSDKStorage.suite))
        let deviceId = "device-\(UUID().uuidString)"
        defaults.set(deviceId, forKey: StorageKeys.deviceId)
        defaults.set(deviceId, forKey: SharedSDKStorage.key(StorageKeys.deviceRegistered, for: Self.configA))
        defaults.set(String(Date().timeIntervalSince1970 + 3600),
                     forKey: SharedSDKStorage.key(StorageKeys.deviceRegistrationBackoffUntil, for: Self.configA))
        defaults.set(SDKDefaults.sdkVersion,
                     forKey: SharedSDKStorage.key(StorageKeys.deviceRegistrationBackoffSDKVersion, for: Self.configA))
        let client = makeClient(Self.configA)
        defer { client.destroy() }
        let user = "user-\(UUID().uuidString)"
        client.identify(userId: user) // no row in this environment: 404, and no replacement while backed off
        await client.awaitIdentityPostForTesting()
        let before = posts(for: user)

        for _ in 0..<3 {
            client.identify(userId: user)
            await client.awaitIdentityPostForTesting()
        }

        XCTAssertEqual(posts(for: user), before, "a POST while registration is backed off can only 404")
        XCTAssertEqual(client.getRecentDiagnostics().last { $0.code == "identity.identify_noop" }?.data?["reason"]?.value as? String, "backoff")
    }

    func testIdentifyingTheCurrentUserAfterAnExhaustedLadderWaitsForTheNextRetryTrigger() async throws {
        let client = makeClient(Self.configA)
        defer { client.destroy() }
        let user = "user-\(UUID().uuidString)"
        AttributionCaptureProtocol.setIdentifyReply(.status(500), for: user)
        client.identify(userId: user)
        await client.awaitIdentityPostForTesting()
        XCTAssertEqual(posts(for: user), 1)

        for _ in 0..<3 {
            client.identify(userId: user)
            await client.awaitIdentityPostForTesting()
        }
        XCTAssertEqual(posts(for: user), 1, "no new ladder until the next automatic retry")
        XCTAssertEqual(client.getRecentDiagnostics().last { $0.code == "identity.identify_noop" }?.data?["reason"]?.value as? String, "recently_exhausted")

        client.configRefreshTickForTesting()
        await client.awaitIdentityPostForTesting()
        XCTAssertEqual(posts(for: user), 2, "the tick retries")
    }

    // MARK: - (g) SDKStatus.identity

    func testStatusReportsWhatTheServerHolds() async throws {
        AttributionCaptureProtocol.echoRegisteredDeviceId = false
        let client = makeClient(Self.configA)
        defer { client.destroy() }
        let registered = await waitUntil { client.status().identity?.deviceRegistered == true }
        XCTAssertTrue(registered)
        XCTAssertEqual(client.status().identity?.serverUser, .anonymous, "a freshly minted row holds no user")

        let user = "user-\(UUID().uuidString)"
        client.identify(userId: user)
        await client.awaitIdentityPostForTesting()
        XCTAssertEqual(client.status().identity?.serverUser, .user(user))
        XCTAssertNil(client.status().identity?.lastIdentifyRejection)

        let refused = "user-\(UUID().uuidString)"
        AttributionCaptureProtocol.setIdentifyReply(.status(403), for: refused)
        client.identify(userId: refused)
        await client.awaitIdentityPostForTesting()
        let identity = try XCTUnwrap(client.status().identity)
        XCTAssertEqual(identity.serverUser, .unknown)
        XCTAssertEqual(client.status().userId, refused, "the app's label names the user the server refused")
        XCTAssertEqual(identity.lastIdentifyRejection, .init(userId: refused, statusCode: 403))
    }
}
