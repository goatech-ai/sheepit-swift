import XCTest
@testable import SheepitKit

/// 🔴 Logout on a shared device must stop the server evaluating the previous user.
///
/// `/v1/config` resolves the user from the server's device row for the request's `X-Device-ID`
/// (`apps/api/src/lib/config-evaluation-context.ts`), and only an identify POST writes that row —
/// there is no unbind. A `reset()` that kept the device id therefore had the next config fetch
/// re-deliver the logged-out user's flag values and experiment variants. `reset()` on a device a
/// user may be bound to now switches to a freshly registered device. Every assertion reads what
/// the real `SheepitClient` sent through `AttributionCaptureProtocol`.
///
/// Shares the `ai.goatech.sdk` suite with every other client suite, so `setUp`/`tearDown` clear
/// every key these tests depend on.
final class DeviceRotationOnResetTests: XCTestCase {
    private static let suite = "ai.goatech.sdk"
    private static let oldDevice = "dev_old_device"
    private static let newDevice = "dev_rotated_device"

    private static func clearStorage() {
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        for key in [StorageKeys.sdkConfig, StorageKeys.sdkConfigCachedAt,
                    StorageKeys.sdkConfigFetchedUnder, StorageKeys.serverHeldUser,
                    StorageKeys.identity, StorageKeys.deviceRegistrationBackoffUntil,
                    StorageKeys.deviceRegistrationBackoffSDKVersion,
                    StorageKeys.deviceId, StorageKeys.deviceRegistered,
                    StorageKeys.deviceBindAttempted] {
            defaults.removeObject(forKey: key)
        }
    }

    override func setUp() {
        super.setUp()
        Self.clearStorage()
        AttributionCaptureProtocol.reset()
        // A device registered on an earlier launch, so `start()` registers nothing.
        let defaults = UserDefaults(suiteName: Self.suite)
        defaults?.set(Self.oldDevice, forKey: StorageKeys.deviceId)
        defaults?.set("1", forKey: StorageKeys.deviceRegistered)
        AttributionCaptureProtocol.registerDeviceId = Self.newDevice
    }

    override func tearDown() {
        Self.clearStorage()
        AttributionCaptureProtocol.reset()
        super.tearDown()
    }

    private func makeClient() -> SheepitClient {
        let client = SheepitClient.createForTesting(
            config: SheepitConfig(
                apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64),
                apiUrl: "https://stub.invalid",
                flushInterval: 3600,
                flushSize: 1000,
                configRefreshInterval: 3600,
                retryAttempts: 1,
                // A client with crash reporting on installs real signal handlers into the test process.
                crashes: CrashConfig(enabled: false)
            ),
            now: { Date() },
            urlProtocolClasses: [AttributionCaptureProtocol.self]
        )
        client.deviceRotationRetryDelayForTesting = { _ in .milliseconds(20) }
        return client
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private func codes(_ client: SheepitClient) -> LockedBox<[String]> {
        let box = LockedBox<[String]>([])
        client.diagnostics().subscribe { event in box.mutate { $0.append(event.code) } }
        return box
    }

    /// Identifies `userId` and waits for its POST (and the refetch after it) to finish.
    private func identifyAndBind(_ client: SheepitClient, _ userId: String) async {
        let seen = await waitUntil { AttributionCaptureProtocol.configRequestCount >= 1 }
        XCTAssertTrue(seen, "precondition: the start-up config fetch ran")
        client.identify(userId: userId)
        await client.awaitIdentityPostForTesting()
        XCTAssertEqual(
            AttributionCaptureProtocol.identifyDeviceIds.last, Self.oldDevice,
            "precondition: the user is bound to the old device")
    }

    // MARK: - The leak

    func testResetAfterIdentifyFetchesConfigForANewDeviceAndNeverNamesTheOldOne() async {
        let client = makeClient()
        defer { client.destroy() }
        let diagnostics = codes(client)
        await identifyAndBind(client, "user-a-\(UUID().uuidString)")
        let configMark = AttributionCaptureProtocol.configDeviceIds.count
        let identifyMark = AttributionCaptureProtocol.identifyDeviceIds.count

        client.reset()

        let fetched = await waitUntil {
            AttributionCaptureProtocol.configDeviceIds.dropFirst(configMark).contains(Self.newDevice)
        }
        XCTAssertTrue(fetched, "config is fetched for the new device as soon as it is registered")
        let configAfter = Array(AttributionCaptureProtocol.configDeviceIds.dropFirst(configMark))
        XCTAssertFalse(
            configAfter.contains(Self.oldDevice),
            "previously every post-logout config fetch named the device still bound to the user")
        XCTAssertFalse(
            AttributionCaptureProtocol.identifyDeviceIds.dropFirst(identifyMark).contains(Self.oldDevice))
        XCTAssertEqual(client.status().deviceId, Self.newDevice)
        XCTAssertEqual(client.context.serverHeldUser.user, .known(nil), "a new row holds no user")
        XCTAssertNil(
            AttributionCaptureProtocol.registerBodies.last?["device_id"],
            "no device id is sent: the server mints one")
        XCTAssertEqual(
            AttributionCaptureProtocol.registerBodies.last?["anonymous_id"] as? String,
            client.context.anonymousId, "registered under the rotated anonymous id")
        XCTAssertTrue(diagnostics.get().contains("identity.device_rotated_on_reset"))
    }

    func testResetOfAnAnonymousDeviceKeepsItAndRegistersNothing() async {
        UserDefaults(suiteName: Self.suite)?.set(
            try? JSONEncoder().encode(ServerHeldUser.known(nil)), forKey: StorageKeys.serverHeldUser)
        let client = makeClient()
        defer { client.destroy() }
        let seen = await waitUntil { AttributionCaptureProtocol.configRequestCount >= 1 }
        XCTAssertTrue(seen)

        client.reset()
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(
            AttributionCaptureProtocol.registerRequestCount, 0,
            "every new device row is metered: an anonymous logout must not mint one")
        XCTAssertEqual(client.status().deviceId, Self.oldDevice)
    }

    /// 🔴 The bound decision follows the identify ATTEMPT, not a classified registration success.
    /// A registration that timed out client-side can still have landed, and the identify that
    /// follows then binds that row — while `deviceRegistered` was never set.
    func testAnIdentifyAfterAnUnconfirmedRegistrationStillRotatesOnReset() async {
        UserDefaults(suiteName: Self.suite)?.removeObject(forKey: StorageKeys.deviceRegistered)
        AttributionCaptureProtocol.failNextRegisterRequests(1) // launch registration: no answer
        let client = makeClient()
        defer { client.destroy() }
        let registered = await waitUntil { AttributionCaptureProtocol.registerRequestCount >= 1 }
        XCTAssertTrue(registered, "precondition: the launch registration was attempted")
        await identifyAndBind(client, "user-a-\(UUID().uuidString)")

        client.reset()
        let adopted = await waitUntil { client.status().deviceId == Self.newDevice }

        XCTAssertTrue(adopted, "the row the identify reached holds the user: reset() must rotate")
    }

    /// 🔴 A launch registration still in flight when `reset()` rotates must not, on answering,
    /// put the abandoned device back in use.
    func testALaunchRegistrationAnsweredAfterTheRotationIsDiscarded() async {
        let defaults = UserDefaults(suiteName: Self.suite)
        defaults?.removeObject(forKey: StorageKeys.deviceRegistered)
        defaults?.set(Self.oldDevice, forKey: StorageKeys.deviceBindAttempted) // a previous launch identified
        AttributionCaptureProtocol.echoRegisteredDeviceId = true
        AttributionCaptureProtocol.holdRegister = true
        let client = makeClient()
        defer {
            AttributionCaptureProtocol.releaseHeldRegister()
            client.destroy()
        }
        let launching = await waitUntil { AttributionCaptureProtocol.registerRequestCount == 1 }
        XCTAssertTrue(launching, "precondition: the launch registration is in flight")

        client.reset()
        let rotating = await waitUntil { AttributionCaptureProtocol.registerRequestCount == 2 }
        XCTAssertTrue(rotating, "precondition: the rotation's registration is in flight")
        AttributionCaptureProtocol.releaseHeldRegister(index: 1)
        let adopted = await waitUntil { client.status().deviceId == Self.newDevice }
        XCTAssertTrue(adopted)
        AttributionCaptureProtocol.releaseHeldRegister(index: 0) // echoes the old device
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(client.status().deviceId, Self.newDevice, "the abandoned device must stay abandoned")
    }

    /// An install upgraded from an SDK that never recorded the row has the label `.unknown` by
    /// default. If it was never identified, nothing can be bound, and every new row is metered.
    func testResetOfANeverIdentifiedUpgradedInstallDoesNotRotate() async {
        let client = makeClient()
        defer { client.destroy() }
        let seen = await waitUntil { AttributionCaptureProtocol.configRequestCount >= 1 }
        XCTAssertTrue(seen)
        XCTAssertEqual(client.context.serverHeldUser.user, .unknown, "precondition: never labelled")

        client.reset()
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(AttributionCaptureProtocol.registerRequestCount, 0)
        XCTAssertEqual(client.status().deviceId, Self.oldDevice)
    }

    // MARK: - Identify after the rotation

    func testIdentifyAfterResetBindsTheNewDevice() async {
        let client = makeClient()
        defer { client.destroy() }
        await identifyAndBind(client, "user-a-\(UUID().uuidString)")

        client.reset()
        let userB = "user-b-\(UUID().uuidString)"
        client.identify(userId: userB)
        await client.awaitIdentityPostForTesting()

        XCTAssertEqual(AttributionCaptureProtocol.identifyUserIds.last, userB)
        XCTAssertEqual(AttributionCaptureProtocol.identifyDeviceIds.last, Self.newDevice)
        XCTAssertEqual(client.context.serverHeldUser.user, .known(userB))
    }

    func testIdentifyWhileTheNewRegistrationIsPendingWaitsForIt() async {
        let client = makeClient()
        defer { client.destroy() }
        await identifyAndBind(client, "user-a-\(UUID().uuidString)")
        AttributionCaptureProtocol.holdRegister = true

        client.reset()
        let userB = "user-b-\(UUID().uuidString)"
        client.identify(userId: userB)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(
            AttributionCaptureProtocol.identifyUserIds.contains(userB),
            "nothing may be sent while the new device is unknown — least of all to the old id")

        AttributionCaptureProtocol.releaseHeldRegister()
        await client.awaitIdentityPostForTesting()
        XCTAssertEqual(AttributionCaptureProtocol.identifyUserIds.last, userB)
        XCTAssertEqual(AttributionCaptureProtocol.identifyDeviceIds.last, Self.newDevice)
    }

    func testResetIdentifyResetBindsNobodyAndRotatesOnce() async {
        let client = makeClient()
        defer { client.destroy() }
        await identifyAndBind(client, "user-a-\(UUID().uuidString)")
        AttributionCaptureProtocol.holdRegister = true

        client.reset()
        let userB = "user-b-\(UUID().uuidString)"
        client.identify(userId: userB)
        client.reset()
        AttributionCaptureProtocol.releaseHeldRegister()
        let adopted = await waitUntil { client.status().deviceId == Self.newDevice }
        XCTAssertTrue(adopted)
        await client.awaitIdentityPostForTesting()

        XCTAssertEqual(
            AttributionCaptureProtocol.registerRequestCount, 1,
            "the pending device was never bound, so the second reset must not mint another")
        XCTAssertFalse(
            AttributionCaptureProtocol.identifyUserIds.contains(userB),
            "user B logged out before its POST could be sent")
        XCTAssertEqual(client.context.serverHeldUser.user, .known(nil))
    }

    /// 🔴 An identify POST for the OLD device that answers after the rotation must not label the
    /// NEW device as holding that user: the new row holds nobody.
    func testAnIdentifyAnsweredAfterTheRotationDoesNotRelabelTheNewDevice() async {
        let client = makeClient()
        defer { client.destroy() }
        let seen = await waitUntil { AttributionCaptureProtocol.configRequestCount >= 1 }
        XCTAssertTrue(seen)
        let userA = "user-a-\(UUID().uuidString)"
        AttributionCaptureProtocol.setIdentifyReply(.hold, for: userA)
        client.identify(userId: userA)
        let sent = await waitUntil { AttributionCaptureProtocol.identifyUserIds.contains(userA) }
        XCTAssertTrue(sent, "precondition: the POST is on the wire")
        let configMark = AttributionCaptureProtocol.configDeviceIds.count

        client.reset()
        let adopted = await waitUntil { client.status().deviceId == Self.newDevice }
        XCTAssertTrue(adopted, "an identify on the wire may have bound the old device: it rotates")
        AttributionCaptureProtocol.releaseHeldIdentify()
        await client.awaitIdentityPostForTesting()

        XCTAssertEqual(client.context.serverHeldUser.user, .known(nil))
        XCTAssertFalse(
            AttributionCaptureProtocol.configDeviceIds.dropFirst(configMark).contains(Self.oldDevice),
            "the stale POST's success must not refetch config for the old device")
    }

    // MARK: - Failure

    func testAFailedRotationRetriesWithBackoffAndNeverFallsBackToTheOldDevice() async {
        let client = makeClient()
        defer { client.destroy() }
        let diagnostics = codes(client)
        await identifyAndBind(client, "user-a-\(UUID().uuidString)")
        AttributionCaptureProtocol.failNextRegisterRequests(2)
        let configMark = AttributionCaptureProtocol.configDeviceIds.count

        client.reset()
        XCTAssertNotEqual(client.status().deviceId, Self.oldDevice, "dropped synchronously in reset()")
        let adopted = await waitUntil { client.status().deviceId == Self.newDevice }

        XCTAssertTrue(adopted, "retried until the registration succeeded")
        XCTAssertEqual(AttributionCaptureProtocol.registerRequestCount, 3)
        XCTAssertEqual(
            diagnostics.get().filter { $0 == "identity.device_rotation_failed" }.count, 2)
        XCTAssertFalse(
            AttributionCaptureProtocol.configDeviceIds.dropFirst(configMark).contains(Self.oldDevice))
    }
    /// 🔴 A 400 is `SDKError.badRequest`, not `.httpError(400)`, so the rotation's terminal check
    /// never saw it: the same rejected body was re-sent every 60 s for the life of the process.
    func testA400RotationRegistrationIsNotRetried() async {
        let client = makeClient()
        defer { client.destroy() }
        await identifyAndBind(client, "user-a-\(UUID().uuidString)")
        AttributionCaptureProtocol.failNextRegisterRequests(
            10, status: 400, body: DeviceRegistrationPayloadTests.validationErrorBody)

        client.reset()
        let rejected = await waitUntil {
            client.getRecentDiagnostics().contains {
                $0.code == "identity.device_rotation_failed" && $0.data?["outcome"]?.value as? String == "rejected"
            }
        }
        XCTAssertTrue(rejected, "a 400 is terminal: reported as rejected")
        // Retries would land every 20 ms here (`deviceRotationRetryDelayForTesting`).
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(AttributionCaptureProtocol.registerRequestCount, 1, "a 400 is never re-sent")
        let failure = client.getRecentDiagnostics().last { $0.code == "identity.device_rotation_failed" }
        XCTAssertEqual(failure?.data?["status_code"]?.value as? Int, 400)
        XCTAssertEqual(failure?.data?["rejected_fields"]?.value as? [String], ["country", "locale"])
        XCTAssertNotEqual(client.status().deviceId, Self.oldDevice, "never falls back to the old device")
    }
    /// 🔴 A launch registration rejected AFTER a rotation replaced its device says nothing about
    /// the current device: it must not back off registration for it.
    func testALaunchRejectionAnsweredAfterTheRotationWritesNoBackoff() async {
        let defaults = UserDefaults(suiteName: Self.suite)
        defaults?.removeObject(forKey: StorageKeys.deviceRegistered)
        defaults?.set(Self.oldDevice, forKey: StorageKeys.deviceBindAttempted)
        AttributionCaptureProtocol.failNextRegisterRequests(
            1, status: 400, body: DeviceRegistrationPayloadTests.validationErrorBody)
        AttributionCaptureProtocol.holdRegister = true
        let client = makeClient()
        defer {
            AttributionCaptureProtocol.releaseHeldRegister()
            client.destroy()
        }
        let launching = await waitUntil { AttributionCaptureProtocol.registerRequestCount == 1 }
        XCTAssertTrue(launching, "precondition: the launch registration is in flight")
        client.reset()
        let rotating = await waitUntil { AttributionCaptureProtocol.registerRequestCount == 2 }
        XCTAssertTrue(rotating, "precondition: the rotation's registration is in flight")
        AttributionCaptureProtocol.releaseHeldRegister(index: 1)
        let adopted = await waitUntil { client.status().deviceId == Self.newDevice }
        XCTAssertTrue(adopted)
        AttributionCaptureProtocol.releaseHeldRegister(index: 0) // the launch request's 400
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertNil(defaults?.string(forKey: StorageKeys.deviceRegistrationBackoffUntil))
        XCTAssertFalse(client.getRecentDiagnostics().contains {
            $0.code == "identity.device_registration_terminal_failure"
        })
    }
}
