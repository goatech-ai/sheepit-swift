import XCTest
@testable import SheepitKit

/// C5 (contract § 7, founder 2026-11-09): a device that got a RESOLVED `/v1/config` body for its
/// current id and is then answered `unknown_device` had its server row erased or purged. It kept its
/// last real body, so a kill switch reached it only after its next re-registration, and that
/// re-registration re-created the erased id. It is now replaced as after an identify 404
/// (`DeviceRotation.replaceErasedDevice`): a fresh lowercase UUIDv4 is registered and its config
/// fetched. Also SK-Q10: a stale unresolved answer no longer clears a newer resolved record.
final class ConfigErasedDeviceTests: XCTestCase {
    private static let resolvedBody = #"{"data":{"config_version":"7","etag":"\"v7\"","flags":{"native_home":true},"experiments":{}}}"#
    private static let defaultsBody = #"{"data":{"config_version":"7","etag":"\"u7\"","flags":{"native_home":false},"experiments":{}}}"#
    /// What the server answers the fresh device once it has a row: a kill switch flipped meanwhile.
    private static let killedBody = #"{"data":{"config_version":"8","etag":"\"k8\"","flags":{"native_home":true,"kill_switch":true},"experiments":{}}}"#

    override func setUp() {
        super.setUp()
        SharedSDKStorage.clear()
        AttributionCaptureProtocol.reset()
        TeardownFlushes.install()
    }

    override func tearDown() async throws {
        await TeardownFlushes.drain(context: name)
        SharedSDKStorage.clear()
        AttributionCaptureProtocol.reset()
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func makeClient(onEvent: (@Sendable (String, [String: Any]?) -> Void)? = nil) -> SheepitClient {
        let client = SheepitClient.createForTesting(
            config: SheepitConfig(
                apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64),
                apiUrl: "https://stub.invalid",
                flushInterval: 3600,
                flushSize: 1000,
                configRefreshInterval: 3600,
                retryAttempts: 1,
                onEvent: onEvent,
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

    private func replacements(_ client: SheepitClient) -> [DiagnosticEvent] {
        client.getRecentDiagnostics().filter { $0.code == "config.device_replaced_unknown" }
    }

    private func registeredIds() -> [String] {
        AttributionCaptureProtocol.registerBodies.compactMap { $0["device_id"] as? String }
    }

    /// A device registered on an earlier launch whose row the server resolves until `erased` is set,
    /// with `answer` then as its resolution. Any other device: `fresh` once registered, else unknown.
    private func modelErasure(
        of device: String,
        erased: LockedBox<Bool>,
        answer: String = "unknown_device",
        fresh: @escaping @Sendable (Bool) -> (body: String, resolution: String?) = { hasRow in
            hasRow ? (ConfigErasedDeviceTests.killedBody, "resolved") : (ConfigErasedDeviceTests.defaultsBody, "unknown_device")
        }
    ) {
        AttributionCaptureProtocol.configResponder = { id, hasRow in
            if id == device { return erased.get() ? (Self.defaultsBody, answer) : (Self.resolvedBody, "resolved") }
            return fresh(hasRow)
        }
        AttributionCaptureProtocol.echoRegisteredDeviceId = true
    }

    // MARK: - C5

    func testAResolvedDeviceAnsweredUnknownRegistersAFreshIdAndAppliesItsConfig() async {
        let device = SharedSDKStorage.markRegistered()
        let erased = LockedBox(false)
        modelErasure(of: device, erased: erased)
        let client = makeClient()
        defer { client.destroy() }
        let applied = await waitUntil { client.flag("native_home") == .bool(true) }
        XCTAssertTrue(applied, "precondition: a resolved body applied at launch")
        XCTAssertEqual(AttributionCaptureProtocol.registerRequestCount, 0, "precondition: nothing registers at launch")

        erased.set(true)
        await client.refreshConfigForTesting()

        let swapped = await waitUntil { client.status().deviceId != device }
        XCTAssertTrue(swapped, "the erased device was kept")
        let fresh = client.status().deviceId ?? ""
        XCTAssertNotNil(UUID(uuidString: fresh), "the replacement is not a UUID: \(fresh)")
        XCTAssertEqual(fresh, fresh.lowercased(), "the replacement is not minted lowercase")
        XCTAssertEqual(registeredIds(), [fresh], "the fresh id was not the one proposed, or the erased id was re-registered")
        let landed = await waitUntil { client.flag("kill_switch") == .bool(true) }
        XCTAssertTrue(landed, "the fresh device's config never applied: the kill switch waits for a re-registration")
        XCTAssertEqual(AttributionCaptureProtocol.configDeviceIds.last, fresh)
        let events = replacements(client)
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.severity, .warn)
        XCTAssertEqual(events.first?.data?["reason"]?.value as? String, "resolved_then_unknown")
    }

    /// F-2: the fresh row holds no user. An identified app's label becomes unknown and its identify
    /// is re-sent for the fresh device at once, as sdk-js binds it, not at the next refresh tick
    /// (300 s by default): no tick is advanced here.
    func testAnIdentifiedAppReIdentifiesOnTheFreshDeviceRightAfterTheSwap() async {
        let device = SharedSDKStorage.markRegistered()
        let erased = LockedBox(false)
        modelErasure(of: device, erased: erased)
        let client = makeClient()
        defer { client.destroy() }
        let applied = await waitUntil { client.flag("native_home") == .bool(true) }
        XCTAssertTrue(applied, "precondition: a resolved body applied at launch")
        let user = "user-\(UUID().uuidString)"
        client.identify(userId: user)
        await client.awaitIdentityPostForTesting()
        XCTAssertEqual(AttributionCaptureProtocol.identifyDeviceIds, [device], "precondition: identified on the old device")

        erased.set(true)
        await client.refreshConfigForTesting()
        let swapped = await waitUntil { client.status().deviceId != device }
        XCTAssertTrue(swapped, "precondition: the erased device was replaced")
        let fresh = client.status().deviceId ?? ""
        let bound = await waitUntil { AttributionCaptureProtocol.identifyDeviceIds.last == fresh }
        XCTAssertTrue(bound, "the user was not bound to the fresh device without a refresh tick")
        XCTAssertEqual(AttributionCaptureProtocol.identifyUserIds.last, user)
    }

    /// A server-side lookup failure says nothing about the row: no replacement.
    func testALookupErrorForAResolvedDeviceReplacesNothing() async {
        let device = SharedSDKStorage.markRegistered()
        let erased = LockedBox(false)
        modelErasure(of: device, erased: erased, answer: "lookup_error")
        let client = makeClient()
        defer { client.destroy() }
        let applied = await waitUntil { client.flag("native_home") == .bool(true) }
        XCTAssertTrue(applied, "precondition: a resolved body applied at launch")

        erased.set(true)
        await client.refreshConfigForTesting()
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertTrue(client.getRecentDiagnostics().contains { $0.code == "config.unresolved_body_refused" },
                      "precondition: the poll was answered unresolved")
        XCTAssertEqual(client.status().deviceId, device, "a lookup error replaced the device")
        XCTAssertEqual(AttributionCaptureProtocol.registerRequestCount, 0)
        XCTAssertTrue(replacements(client).isEmpty)
    }

    /// A first launch: the launch fetch names a device with no row yet. Nothing was resolved for it,
    /// so `unknown_device` is the normal answer, not an erasure.
    func testAnUnknownDeviceWithNoPriorResolveReplacesNothing() async {
        AttributionCaptureProtocol.configResponder = { _, hasRow in
            hasRow ? (Self.resolvedBody, "resolved") : (Self.defaultsBody, "unknown_device")
        }
        AttributionCaptureProtocol.echoRegisteredDeviceId = true
        AttributionCaptureProtocol.holdRegister = true
        let client = makeClient()
        defer { client.destroy() }
        let proposal = client.status().deviceId
        let refused = await waitUntil { client.getRecentDiagnostics().contains { $0.code == "config.unresolved_body_refused" } }
        XCTAssertTrue(refused, "precondition: the launch fetch was answered unknown_device")
        await client.refreshConfigForTesting()
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(AttributionCaptureProtocol.registerRequestCount, 1, "a replacement registered beside the launch registration")
        XCTAssertTrue(replacements(client).isEmpty)
        AttributionCaptureProtocol.releaseHeldRegister()
        let resolved = await waitUntil { client.flag("native_home") == .bool(true) }
        XCTAssertTrue(resolved)
        XCTAssertEqual(client.status().deviceId, proposal, "the first-launch proposal was replaced")
    }

    /// One-shot: the record is cleared as the replacement starts, so neither a second answer for the
    /// erased id (while the replacement registers) nor an unresolved answer for the fresh id
    /// replaces again.
    func testASecondUnknownDeviceAfterTheReplacementDoesNotReplaceAgain() async {
        let device = SharedSDKStorage.markRegistered()
        let erased = LockedBox(false)
        // The fresh row is not yet visible to `/v1/config`: every answer for it is unknown.
        modelErasure(of: device, erased: erased, fresh: { _ in (ConfigErasedDeviceTests.defaultsBody, "unknown_device") })
        let client = makeClient()
        defer { client.destroy() }
        let applied = await waitUntil { client.flag("native_home") == .bool(true) }
        XCTAssertTrue(applied, "precondition: a resolved body applied at launch")
        AttributionCaptureProtocol.holdRegister = true
        erased.set(true)
        await client.refreshConfigForTesting()
        let registering = await waitUntil { AttributionCaptureProtocol.registerRequestCount == 1 }
        XCTAssertTrue(registering, "precondition: the replacement is registering")

        await client.refreshConfigForTesting()
        AttributionCaptureProtocol.releaseHeldRegister()
        let swapped = await waitUntil { client.status().deviceId != device }
        XCTAssertTrue(swapped, "precondition: the replacement swapped in")
        let fresh = client.status().deviceId ?? ""
        let refetched = await waitUntil { AttributionCaptureProtocol.configDeviceIds.contains(fresh) }
        XCTAssertTrue(refetched, "precondition: the fresh device's config was fetched")
        await client.refreshConfigForTesting()
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(AttributionCaptureProtocol.registerRequestCount, 1, "a further unknown_device registered again")
        XCTAssertEqual(replacements(client).count, 1)
        XCTAssertEqual(client.status().deviceId, fresh)
    }

    /// One replacement per launch: the fresh device resolves, then its own row disappears too. The
    /// second trigger reports `capped` and registers nothing (a relaunch may replace once more).
    func testASecondErasureInTheSameLaunchIsCappedAndReplacesNothing() async {
        let device = SharedSDKStorage.markRegistered()
        let erased = LockedBox(false)
        let freshErased = LockedBox(false)
        modelErasure(of: device, erased: erased, fresh: { hasRow in
            hasRow && !freshErased.get()
                ? (ConfigErasedDeviceTests.killedBody, "resolved") : (ConfigErasedDeviceTests.defaultsBody, "unknown_device")
        })
        AttributionCaptureProtocol.honorIfNoneMatch = false
        let client = makeClient()
        defer { client.destroy() }
        let applied = await waitUntil { client.flag("native_home") == .bool(true) }
        XCTAssertTrue(applied, "precondition: a resolved body applied at launch")
        erased.set(true)
        await client.refreshConfigForTesting()
        let resolved = await waitUntil { client.flag("kill_switch") == .bool(true) }
        XCTAssertTrue(resolved, "precondition: the first replacement registered and resolved")
        let fresh = client.status().deviceId ?? ""

        freshErased.set(true)
        await client.refreshConfigForTesting()
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(client.status().deviceId, fresh, "a second erasure in the same launch replaced again")
        XCTAssertEqual(AttributionCaptureProtocol.registerRequestCount, 1)
        XCTAssertEqual(replacements(client).compactMap { $0.data?["reason"]?.value as? String },
                       ["resolved_then_unknown", "capped"])
        XCTAssertEqual(replacements(client).last?.severity, .warn)
    }

    /// A C5 replacement whose registration fails keeps the erased id but drops its values: the
    /// server's defaults apply in memory, so a kill switch can land; the resolved stamp stays on
    /// disk, so the next launch retries the replacement once.
    func testAFailedReplacementKeepsTheIdButDropsItsValues() async {
        let device = SharedSDKStorage.markRegistered()
        let erased = LockedBox(false)
        modelErasure(of: device, erased: erased)
        let client = makeClient()
        defer { client.destroy() }
        let applied = await waitUntil { client.flag("native_home") == .bool(true) }
        XCTAssertTrue(applied, "precondition: a resolved body applied at launch")

        AttributionCaptureProtocol.failNextRegisterRequests(1)
        erased.set(true)
        await client.refreshConfigForTesting()
        let failed = await waitUntil {
            client.getRecentDiagnostics().contains { $0.code == "identity.device_replacement_failed" }
        }
        XCTAssertTrue(failed, "precondition: the replacement's registration failed")

        let dropped = await waitUntil { client.flag("native_home") == .bool(false) }
        XCTAssertTrue(dropped, "the erased device's values stayed applied after the replacement failed")
        XCTAssertEqual(client.status().deviceId, device, "the erased id was not kept")
        let stamp = UserDefaults(suiteName: SharedSDKStorage.suite)?
            .string(forKey: SharedSDKStorage.slot(StorageKeys.sdkConfigResolvedFor))
        XCTAssertEqual(stamp, device, "the stamp went, so the next launch cannot retry")
        XCTAssertNotNil(UserDefaults(suiteName: SharedSDKStorage.suite)?
            .data(forKey: SharedSDKStorage.slot(StorageKeys.sdkConfig)), "a failed replacement dropped the cached body")
    }

    /// Round-3 BLOCKER: a fetch for the erased device still on the wire when C5 swaps in a fresh id
    /// and the swap drops the cache. The swap does not move the reset gate, so that answer passed
    /// every guard and wrote the erased device's body, stamped for it, back to disk: every later
    /// launch on the fresh id applied it, with C5 disarmed (the stamp names another id).
    func testAFetchForTheErasedDeviceLandingAfterTheSwapWritesNothing() async {
        let device = SharedSDKStorage.markRegistered()
        AttributionCaptureProtocol.echoRegisteredDeviceId = true
        // 1: launch (resolved); 2: a poll held on the wire (resolved, lands last); 3: a poll answered
        // unknown_device, which fires C5; 4: the fresh device's refetch (no row visible yet).
        AttributionCaptureProtocol.scriptConfig([(Self.resolvedBody, 0), (Self.resolvedBody, 1.0), (Self.defaultsBody, 0), (Self.defaultsBody, 0)])
        let deviceCalls = LockedBox(0)
        AttributionCaptureProtocol.configResolution = { id, _ in
            guard id == device else { return "unknown_device" }
            var n = 0
            deviceCalls.mutate { $0 += 1; n = $0 }
            return n <= 2 ? "resolved" : "unknown_device"
        }
        AttributionCaptureProtocol.honorIfNoneMatch = false
        let client = makeClient()
        defer { client.destroy() }
        let launched = await waitUntil { client.status().configFreshness?.source == .server }
        XCTAssertTrue(launched, "precondition: the launch fetch applied")

        let slow = Task { await client.refreshConfigForTesting() }
        let onTheWire = await waitUntil { AttributionCaptureProtocol.configRequestCount == 2 }
        XCTAssertTrue(onTheWire, "precondition: the erased device's poll is on the wire")
        await client.refreshConfigForTesting()
        let swapped = await waitUntil { client.status().deviceId != device }
        XCTAssertTrue(swapped, "precondition: C5 replaced the device")
        let refetched = await waitUntil { AttributionCaptureProtocol.configRequestCount >= 4 }
        XCTAssertTrue(refetched, "precondition: the fresh device's refetch went out")
        let defaults = UserDefaults(suiteName: SharedSDKStorage.suite)
        XCTAssertNil(defaults?.data(forKey: SharedSDKStorage.slot(StorageKeys.sdkConfig)), "precondition: the swap dropped the cache")
        await slow.value

        XCTAssertNil(defaults?.data(forKey: SharedSDKStorage.slot(StorageKeys.sdkConfig)),
                     "the erased device's late body was written to disk after the swap")
        XCTAssertNil(defaults?.string(forKey: SharedSDKStorage.slot(StorageKeys.sdkConfigResolvedFor)),
                     "the erased device's resolved stamp was written back after the swap")
    }

    /// The launch cache is applied off the actor, so it shields the device through its own slot
    /// (`LaunchCacheState.appliedUnder`), not `realBodyResetToken`. When a replacement for a device
    /// erased between launches fails, both must stop shielding it: the server's later
    /// unresolved answers (a kill switch flipped meanwhile) reach memory, not just the first one.
    func testAFailedReplacementAfterALaunchCacheLetsLaterDefaultsThrough() async throws {
        let device = SharedSDKStorage.markRegistered()
        try seedCache(for: device, stamped: true)
        let killed = LockedBox(false)
        let killedDefaults = #"{"data":{"config_version":"9","etag":"\"u9\"","flags":{"native_home":false,"kill_switch":true},"experiments":{}}}"#
        AttributionCaptureProtocol.configResponder = { _, _ in
            (killed.get() ? killedDefaults : Self.defaultsBody, "unknown_device")
        }
        AttributionCaptureProtocol.failNextRegisterRequests(1)
        let client = makeClient()
        defer { client.destroy() }
        let failed = await waitUntil {
            client.getRecentDiagnostics().contains { $0.code == "identity.device_replacement_failed" }
        }
        XCTAssertTrue(failed, "precondition: the replacement's registration failed")
        let dropped = await waitUntil { client.flag("native_home") == .bool(false) }
        XCTAssertTrue(dropped, "precondition: the erased device's cached values were dropped")

        killed.set(true)
        await client.refreshConfigForTesting()
        XCTAssertEqual(client.flag("kill_switch"), .bool(true),
                       "the launch cache still shielded the erased device: a later kill switch was refused")
    }

    /// SK-Q18: SheepitKit keeps one cached body, not one per device, so nothing accumulates, but
    /// with no age limit the erased row's body outlived a SUCCESSFUL replacement whose refetch did
    /// not land: every offline launch on the fresh id applied it. It goes at the swap, stamp and all.
    func testASuccessfulReplacementDropsTheErasedDevicesCachedBody() async throws {
        let device = SharedSDKStorage.markRegistered()
        try seedCache(for: device, stamped: true)
        // The fresh row is not visible yet (replica lag): its refetch is unresolved, so it caches
        // nothing and only the drop can have removed the erased body.
        modelErasure(of: device, erased: LockedBox(true), fresh: { _ in (Self.defaultsBody, "unknown_device") })
        let client = makeClient()
        defer { client.destroy() }

        let swapped = await waitUntil { client.status().deviceId != device }
        XCTAssertTrue(swapped, "precondition: the erased device was replaced")
        let refetched = await waitUntil { AttributionCaptureProtocol.configRequestCount >= 2 }
        XCTAssertTrue(refetched, "precondition: the fresh device's refetch went out")

        let defaults = UserDefaults(suiteName: SharedSDKStorage.suite)
        XCTAssertNil(defaults?.data(forKey: SharedSDKStorage.slot(StorageKeys.sdkConfig)),
                     "the erased device's body stayed on disk for the fresh id")
        XCTAssertNil(defaults?.string(forKey: SharedSDKStorage.slot(StorageKeys.sdkConfigResolvedFor)),
                     "the erased device's stamp stayed on disk")
    }

    /// B2 / F-1: an anonymous install's exposure subject is the device, so a device replaced by C5
    /// is a new subject. Its exposures are re-armed only once the fresh device's config is in: a read
    /// between the swap and that refetch must not expose the erased device's arm under the fresh id,
    /// and the fresh arm is exposed exactly once after it. The unchanged flag fires again too.
    func testAnAnonymousDeviceReplacedByC5ExposesTheFreshArmOnceAndNeverTheErasedOne() async {
        let armedA = #"{"data":{"config_version":"7","etag":"\"v7\"","flags":{"native_home":true},"experiments":{"e":{"variant_key":"a","payload":{}}}}}"#
        let armedB = #"{"data":{"config_version":"8","etag":"\"b8\"","flags":{"native_home":true},"experiments":{"e":{"variant_key":"b","payload":{}}}}}"#
        // A registered anonymous device whose row is known to hold no user: the launch body is
        // applied under a confirmed label, so the reads below are not ones an identity wait re-arms
        // (`ExperimentManager.setAssignments`), and only the C5 clear re-arms them.
        let device = SharedSDKStorage.markRegistered()
        UserDefaults(suiteName: SharedSDKStorage.suite)?.set(
            try? JSONEncoder().encode(ServerHeldUser.known(nil)), forKey: SharedSDKStorage.slot(StorageKeys.serverHeldUser))
        // 1: launch (arm a); 2: the erasure (unknown_device); 3: the fresh device's refetch (arm b),
        // held 1 s so a read lands between the swap and it.
        AttributionCaptureProtocol.scriptConfig([(armedA, 0), (Self.defaultsBody, 0), (armedB, 1.0)])
        let deviceCalls = LockedBox(0)
        AttributionCaptureProtocol.configResolution = { id, _ in
            guard id == device else { return "resolved" }
            var n = 0
            deviceCalls.mutate { $0 += 1; n = $0 }
            return n == 1 ? "resolved" : "unknown_device"
        }
        AttributionCaptureProtocol.honorIfNoneMatch = false
        AttributionCaptureProtocol.echoRegisteredDeviceId = true
        let exposures = LockedBox<[(name: String, variant: String?)]>([])
        let client = makeClient(onEvent: { name, props in
            if name == "$flag_exposure" || name == "$experiment_exposure" {
                exposures.mutate { $0.append((name, props?["variant"] as? String)) }
            }
        })
        defer { client.destroy() }
        let applied = await waitUntil { client.status().flagCount == 1 }
        XCTAssertTrue(applied, "precondition: a resolved body applied at launch")
        _ = client.flag("native_home")
        _ = client.experiment("e")
        XCTAssertEqual(exposures.get().count, 2, "precondition: one flag and one arm exposure at launch")

        await client.refreshConfigForTesting()
        let swapped = await waitUntil { client.status().deviceId != device }
        XCTAssertTrue(swapped, "precondition: C5 replaced the device")
        XCTAssertLessThan(AttributionCaptureProtocol.configRequestCount, 4, "precondition: the refetch is still held")
        // Between the swap and the fresh device's config: the erased device's arm is still applied.
        _ = client.experiment("e")
        _ = client.flag("native_home")
        let refetchSent = await waitUntil { AttributionCaptureProtocol.configDeviceIds.contains(client.status().deviceId ?? "") }
        XCTAssertTrue(refetchSent, "precondition: the fresh device's refetch went out")
        // Its answer is held 1 s; let it apply.
        try? await Task.sleep(for: .milliseconds(1400))
        _ = client.experiment("e")
        _ = client.flag("native_home")

        let afterSwap = Array(exposures.get().dropFirst(2))
        XCTAssertFalse(afterSwap.contains { $0.name == "$experiment_exposure" && $0.variant == "a" },
                       "the erased device's arm was exposed under the fresh id: \(afterSwap)")
        XCTAssertEqual(afterSwap.filter { $0.name == "$experiment_exposure" && $0.variant == "b" }.count, 1,
                       "the fresh arm was not exposed exactly once: \(afterSwap)")
        XCTAssertEqual(afterSwap.filter { $0.name == "$flag_exposure" }.count, 1,
                       "the unchanged flag was not exposed exactly once for the fresh id: \(afterSwap)")
    }

    /// B3: an identify 404 already swapped the device (it does not move the reset gate), then a
    /// stale `/v1/config` answer for the old id comes back `unknown_device`. C5 has nothing to
    /// replace: like sdk-js it reports nothing, registers nothing and stashes nothing.
    func testAStaleUnknownDeviceForAnIdTheIdentify404AlreadyReplacedReportsNothing() async {
        let device = SharedSDKStorage.markRegistered()
        AttributionCaptureProtocol.modelEnvironmentRows = true
        AttributionCaptureProtocol.echoRegisteredDeviceId = true
        // 1: the launch fetch (resolved); 2: a poll still on the wire across the swap
        // (answered unknown_device, late); 3: the replacement's refetch (later still).
        AttributionCaptureProtocol.scriptConfig([(Self.resolvedBody, 0), (Self.defaultsBody, 0.5), (Self.killedBody, 1.0)])
        let deviceCalls = LockedBox(0)
        AttributionCaptureProtocol.configResolution = { id, _ in
            guard id == device else { return "resolved" }
            var n = 0
            deviceCalls.mutate { $0 += 1; n = $0 }
            return n == 1 ? "resolved" : "unknown_device"
        }
        AttributionCaptureProtocol.honorIfNoneMatch = false
        let client = makeClient()
        defer { client.destroy() }
        let applied = await waitUntil { client.flag("native_home") == .bool(true) }
        XCTAssertTrue(applied, "precondition: a resolved body applied for the device")

        let stale = Task { await client.refreshConfigForTesting() }
        let onTheWire = await waitUntil { AttributionCaptureProtocol.configRequestCount == 2 }
        XCTAssertTrue(onTheWire, "precondition: the poll for the old id is on the wire")
        client.identify(userId: "user-\(UUID().uuidString)")
        let swapped = await waitUntil { client.status().deviceId != device }
        XCTAssertTrue(swapped, "precondition: the identify 404 replaced the device")
        await stale.value
        XCTAssertTrue(client.getRecentDiagnostics().contains { $0.code == "config.unresolved_body_refused" },
                      "precondition: the stale unknown_device answer landed")

        XCTAssertTrue(replacements(client).isEmpty, "C5 reported a replacement for a device the client had already left")
        XCTAssertEqual(AttributionCaptureProtocol.registerRequestCount, 1, "a second registration went out")
        let landed = await waitUntil { client.flag("kill_switch") == .bool(true) }
        XCTAssertTrue(landed, "the replacement's config never applied")
    }

    // MARK: - C5 across launches (the cache's resolved stamp)

    /// A launch cache as an earlier launch left it: a resolved body for `device`, stamped resolved
    /// for it unless `stamped` is false (a cache written before the stamp existed).
    private func seedCache(for device: String, stamped: Bool) throws {
        let defaults = UserDefaults(suiteName: SharedSDKStorage.suite)
        defaults?.set(Data(Self.resolvedBody.utf8), forKey: SharedSDKStorage.slot(StorageKeys.sdkConfig))
        defaults?.set(String(Date().timeIntervalSince1970 - 3600), forKey: SharedSDKStorage.slot(StorageKeys.sdkConfigCachedAt))
        defaults?.set(try JSONEncoder().encode(ServerHeldUser.known(nil)), forKey: SharedSDKStorage.slot(StorageKeys.sdkConfigFetchedUnder))
        if stamped { defaults?.set(device, forKey: SharedSDKStorage.slot(StorageKeys.sdkConfigResolvedFor)) }
    }

    private func skipReasons(_ client: SheepitClient) -> [String] {
        client.getRecentDiagnostics().filter { $0.code == "config.registration_refetch_skipped" }
            .compactMap { $0.data?["reason"]?.value as? String }
    }

    /// The row was erased while the app was not running. The ETag is memory-only, so the launch
    /// fetch is unconditional and answers `unknown_device` at once; the stamp on the cache is what
    /// says this device was resolved before.
    func testAnErasureWhileTheAppWasNotRunningIsCaughtAtTheNextLaunch() async throws {
        let device = SharedSDKStorage.markRegistered()
        try seedCache(for: device, stamped: true)
        modelErasure(of: device, erased: LockedBox(true))
        let client = makeClient()
        defer { client.destroy() }

        let swapped = await waitUntil { client.status().deviceId != device }

        XCTAssertTrue(swapped, "an erasure between launches was not detected")
        let fresh = client.status().deviceId ?? ""
        XCTAssertEqual(registeredIds(), [fresh], "the fresh id was not the one proposed, or the erased id was re-registered")
        let landed = await waitUntil { client.flag("kill_switch") == .bool(true) }
        XCTAssertTrue(landed, "the fresh device's config never applied")
        XCTAssertEqual(replacements(client).count, 1)
    }

    /// SK-Q12 (round-2 adversarial H1): an identified install whose row was erased between
    /// launches. The launch identify 404s into the replacement while the launch fetch's
    /// `unknown_device` fires C5 into it too; both reached `replaceUnknown` and registered, leaving
    /// an orphan metered row. The replacement is single-flight per device id: exactly ONE goes out.
    func testAnIdentifiedInstallErasedBetweenLaunchesRegistersExactlyOneReplacement() async throws {
        let device = SharedSDKStorage.markRegistered()
        try seedCache(for: device, stamped: true)
        modelErasure(of: device, erased: LockedBox(true))
        // The identify route 404s for a device with no row, as the API does.
        AttributionCaptureProtocol.modelEnvironmentRows = true
        // Hold the replacement on the wire until BOTH callers have reached it: without the hold the
        // second can arrive after the swap, where the "already left" guard stops it on its own.
        AttributionCaptureProtocol.holdRegister = true
        let client = makeClient()
        defer { client.destroy() }
        let user = "user-\(UUID().uuidString)"
        client.identify(userId: user)

        let bothArrived = await waitUntil {
            client.getRecentDiagnostics().contains { $0.code == "config.device_replaced_unknown" }
                && AttributionCaptureProtocol.identifyDeviceIds.contains(device)
                && AttributionCaptureProtocol.registerRequestCount >= 1
        }
        XCTAssertTrue(bothArrived, "precondition: the identify 404 and the C5 trigger both reached the replacement")
        try? await Task.sleep(for: .milliseconds(300))
        AttributionCaptureProtocol.releaseHeldRegister()

        let swapped = await waitUntil { client.status().deviceId != device }
        XCTAssertTrue(swapped, "the erased device was never replaced")
        await client.awaitIdentityPostForTesting()
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(AttributionCaptureProtocol.registerRequestCount, 1, "two replacements registered for one erased device")
        // Which caller started the replacement: C5 first ("resolved_then_unknown", the identify
        // joined) or the identify 404 first ("joined"). Printed so a run log shows the ordering.
        let reasons = replacements(client).compactMap { $0.data?["reason"]?.value as? String }
        print("H1 ordering: \(reasons)")
        XCTAssertEqual(reasons.count, 1, "C5 reported other than once")
        XCTAssertTrue(["joined", "resolved_then_unknown"].contains(reasons.first ?? ""), "unexpected C5 reason \(reasons)")
        let fresh = client.status().deviceId ?? ""
        XCTAssertEqual(registeredIds(), [fresh])
        XCTAssertEqual(AttributionCaptureProtocol.identifyDeviceIds.last, fresh, "the user was not bound to the replacement")
        let landed = await waitUntil { client.flag("kill_switch") == .bool(true) }
        XCTAssertTrue(landed, "the replacement's config never applied")
    }

    /// A cache written before the stamp existed reads as not resolved: fail closed, no replacement.
    func testALegacyCacheWithNoStampDoesNotReplaceTheDevice() async throws {
        let device = SharedSDKStorage.markRegistered()
        try seedCache(for: device, stamped: false)
        modelErasure(of: device, erased: LockedBox(true))
        let client = makeClient()
        defer { client.destroy() }
        let refused = await waitUntil { client.getRecentDiagnostics().contains { $0.code == "config.unresolved_body_refused" } }
        XCTAssertTrue(refused, "precondition: the launch fetch was answered unknown_device")
        try? await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(client.status().deviceId, device, "an unstamped cache armed the replacement")
        XCTAssertEqual(AttributionCaptureProtocol.registerRequestCount, 0)
        XCTAssertTrue(replacements(client).isEmpty)
        XCTAssertEqual(client.flag("native_home"), .bool(true), "precondition: the cached body stays applied")
    }

    /// A relaunch with the row intact: the launch fetch resolves, polls then 304 against its ETag
    /// (the server answers 304 before the device lookup), and only the `config_version` bump of a
    /// flag kill brings a 200, answered `unknown_device` once the row is gone.
    func testAfterARelaunchThe304sHoldUntilAFlagKillThenTheErasedDeviceIsReplaced() async throws {
        let device = SharedSDKStorage.markRegistered()
        try seedCache(for: device, stamped: true)
        let erased = LockedBox(false)
        let bumped = LockedBox(false)
        // As the API does: `If-None-Match` is compared before the device lookup, so an erased row
        // still 304s against the resolved ETag until a flag kill moves `config_version`; the 200
        // then carries the new version's resolved-shaped ETag, answered `unknown_device`.
        let bumpedDefaults = #"{"data":{"config_version":"8","etag":"\"v8\"","flags":{"native_home":false,"kill_switch":true},"experiments":{}}}"#
        AttributionCaptureProtocol.configResponder = { id, hasRow in
            guard id == device else { return hasRow ? (Self.killedBody, "resolved") : (Self.defaultsBody, "unknown_device") }
            guard erased.get() else { return (Self.resolvedBody, "resolved") }
            return bumped.get() ? (bumpedDefaults, "unknown_device") : (Self.resolvedBody, "unknown_device")
        }
        AttributionCaptureProtocol.echoRegisteredDeviceId = true
        let client = makeClient()
        defer { client.destroy() }
        // Applied, not just sent: the ETag the poll revalidates with is taken in the same actor turn.
        let launched = await waitUntil { client.status().configFreshness?.source == .server }
        XCTAssertTrue(launched, "precondition: the launch fetch applied")
        await client.refreshConfigForTesting()
        XCTAssertEqual(AttributionCaptureProtocol.configIfNoneMatch.last ?? nil, "\"v7\"", "precondition: the poll was conditional")
        XCTAssertEqual(client.status().deviceId, device, "precondition: a 304 replaced nothing")

        // The row is gone, but the server answers 304 before the device lookup, so nothing changes
        // until the `config_version` moves.
        erased.set(true)
        await client.refreshConfigForTesting()
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(client.status().deviceId, device, "a poll replaced the device before any config_version bump")
        XCTAssertTrue(replacements(client).isEmpty, "C5 fired on an answer the server would have 304'd")

        bumped.set(true)
        await client.refreshConfigForTesting()

        let swapped = await waitUntil { client.status().deviceId != device }
        XCTAssertTrue(swapped, "the flag kill's unknown_device did not replace the erased device")
        let landed = await waitUntil { client.flag("kill_switch") == .bool(true) }
        XCTAssertTrue(landed, "the kill never applied")
        XCTAssertEqual(registeredIds(), [client.status().deviceId ?? ""])
    }

    /// The stamp arms C5 only. A launch-cache body never counts as an applied resolved body for the
    /// refetch an accepted registration owes (contract § 1 (2)): with the launch fetch failed, the
    /// app-update re-registration still refetches.
    func testACacheStampDoesNotSuppressTheRefetchAfterRegistration() async throws {
        let device = SharedSDKStorage.markRegistered()
        UserDefaults(suiteName: SharedSDKStorage.suite)?.set(
            "0.0.0-previous", forKey: SharedSDKStorage.slot(StorageKeys.deviceRegisteredAppVersion))
        try seedCache(for: device, stamped: true)
        modelErasure(of: device, erased: LockedBox(false))
        AttributionCaptureProtocol.failNextConfigRequests(1)
        AttributionCaptureProtocol.holdRegister = true
        let client = makeClient()
        defer { client.destroy() }
        let ready = await waitUntil {
            AttributionCaptureProtocol.configRequestCount >= 1 && AttributionCaptureProtocol.registerRequestCount >= 1
        }
        XCTAssertTrue(ready, "precondition: the launch fetch failed and the re-registration is held")
        let mark = AttributionCaptureProtocol.configRequestCount
        AttributionCaptureProtocol.releaseHeldRegister()

        let refetched = await waitUntil { AttributionCaptureProtocol.configRequestCount > mark }

        XCTAssertTrue(refetched, "the cache stamp counted as an applied resolved body")
        XCTAssertFalse(skipReasons(client).contains("resolved_applied"))
    }

    // MARK: - SK-Q10

    /// A fetch that started BEFORE a resolved one and lands after it, unresolved: an older answer, so
    /// the record of the newer body stays and the next registration still skips its refetch.
    func testAStaleUnresolvedAnswerAfterANewerResolvedOneKeepsTheRecord() async {
        let bus = DiagnosticBus()
        let sync = ConfigSync(
            http: HTTPClient(
                config: SheepitConfig(apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64),
                                      apiUrl: "https://stub.invalid", retryAttempts: 1),
                log: Logger(debug: false), urlProtocolClasses: [AttributionCaptureProtocol.self]),
            storage: InMemoryStorage(), refreshInterval: 3600, log: Logger(debug: false),
            diagnostics: bus, identityProvider: { (.fetchedUnder(nil), 0) },
            onConfig: { _, _, _ in })
        let calls = LockedBox(0)
        AttributionCaptureProtocol.scriptConfig([(Self.defaultsBody, 0.4), (Self.resolvedBody, 0)])
        AttributionCaptureProtocol.configResolution = { _, _ in
            var n = 0
            calls.mutate { $0 += 1; n = $0 }
            return n == 1 ? "unknown_device" : "resolved"
        }

        let stale = Task { await sync.refresh(deviceId: "device-1") }
        let started = await waitUntil { AttributionCaptureProtocol.configRequestCount == 1 }
        XCTAssertTrue(started, "precondition: the older fetch is on the wire")
        await sync.refresh(deviceId: "device-1")
        await stale.value
        XCTAssertTrue(bus.getRecentDiagnostics().contains { $0.code == "config.unresolved_body_refused" },
                      "precondition: the older answer landed unresolved, after the resolved one")

        await sync.refetchAfterRegistration(deviceId: "device-1", replaced: false, isCurrent: { true })

        XCTAssertEqual(AttributionCaptureProtocol.configRequestCount, 2, "a stale unresolved answer erased the newer resolved record")
        XCTAssertTrue(bus.getRecentDiagnostics().contains {
            $0.code == "config.registration_refetch_skipped" && $0.data?["reason"]?.value as? String == "resolved_applied"
        })
    }
}
