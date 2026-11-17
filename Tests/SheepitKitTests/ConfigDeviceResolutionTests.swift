import XCTest
@testable import SheepitKit

/// `/v1/config` answers 200, every device- and user-targeted flag on its default, when it cannot
/// resolve the device (`X-Sheepit-Device-Resolution: unknown_device | lookup_error`). Two defects:
///
/// - C3: SheepitKit checked only the status, so it applied that body, wrote it over a good cache
///   (served offline for up to `configOfflineMaxAge`), and kept its ETag. Now refused
///   (`DeviceResolution`).
/// - C1: the launch fetch runs alongside registration, and an ACCEPTED registration refetched
///   nothing, so a fresh install read defaults until the next poll (300 s by default). Now it
///   refetches unless a resolved body already applies (`ConfigSync.refetchAfterRegistration`).
final class ConfigDeviceResolutionTests: XCTestCase {
    private static let launch = Date(timeIntervalSince1970: 1_800_000_000)
    private static let resolvedBody = #"{"data":{"config_version":"7","etag":"\"v7\"","flags":{"native_home":true},"experiments":{}}}"#
    private static let defaultsBody = #"{"data":{"config_version":"7","etag":"\"u7\"","flags":{"native_home":false},"experiments":{}}}"#

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

    private func makeSync(
        storage: StorageProvider,
        freshness: ConfigFreshnessRecorder = ConfigFreshnessRecorder(),
        diagnostics: DiagnosticBus? = nil,
        provisional: LockedBox<[[String: AnyCodable]]> = LockedBox([]),
        applied: LockedBox<[[String: AnyCodable]]>
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
            now: { Self.launch },
            freshness: freshness,
            diagnostics: diagnostics,
            identityProvider: { (.fetchedUnder(nil), 0) },
            onConfig: { response, _, _ in applied.mutate { $0.append(response.flags) } },
            onProvisional: { response in provisional.mutate { $0.append(response.flags) } }
        )
    }

    private func seedGoodCache(_ storage: StorageProvider) throws {
        storage.set(Data(Self.resolvedBody.utf8), forKey: StorageKeys.sdkConfig)
        storage.set(String(Self.launch.timeIntervalSince1970 - 3 * 3600), forKey: StorageKeys.sdkConfigCachedAt)
        storage.set(try JSONEncoder().encode(ServerHeldUser.known(nil)), forKey: StorageKeys.sdkConfigFetchedUnder)
    }

    private static func serve(_ body: String, resolution: String?) {
        AttributionCaptureProtocol.serveConfig(body)
        AttributionCaptureProtocol.configResolution = resolution.map { value in { @Sendable _, _ in value } }
    }

    private func nativeHome(_ flags: [String: AnyCodable]?) -> Bool? {
        flags?["native_home"]?.value as? Bool
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    // MARK: - C3: an unresolved 200 is refused

    func testAnUnresolvedOKIsNeitherAppliedNorCachedAndLeavesAGoodCacheInPlace() async throws {
        for value in ["unknown_device", "lookup_error"] {
            AttributionCaptureProtocol.reset()
            let storage = InMemoryStorage()
            try seedGoodCache(storage)
            let stampBefore = storage.string(forKey: StorageKeys.sdkConfigCachedAt)
            let applied = LockedBox<[[String: AnyCodable]]>([])
            let freshness = ConfigFreshnessRecorder()
            let provisional = LockedBox<[[String: AnyCodable]]>([])
            Self.serve(Self.defaultsBody, resolution: value)
            let sync = makeSync(storage: storage, freshness: freshness, provisional: provisional, applied: applied)
            await sync.start(deviceIdGetter: { "device-1" })
            await sync.stop()
            await sync.refresh(deviceId: "device-1")

            XCTAssertGreaterThanOrEqual(AttributionCaptureProtocol.configRequestCount, 1, "precondition: fetched (\(value))")
            XCTAssertEqual(applied.get().count, 1, "only the cache may apply; the \(value) body was applied")
            XCTAssertEqual(nativeHome(applied.get().last), true, "the \(value) defaults replaced the applied values")
            XCTAssertEqual(storage.data(forKey: StorageKeys.sdkConfig), Data(Self.resolvedBody.utf8),
                           "the \(value) body was written over a good cache")
            XCTAssertEqual(storage.string(forKey: StorageKeys.sdkConfigCachedAt), stampBefore,
                           "the cache stamp moved on a refused body (\(value))")
            XCTAssertEqual(freshness.current?.source, .cache, "a refused body counts as no server fetch (\(value))")
            XCTAssertTrue(provisional.get().isEmpty, "a cache was loaded: the \(value) body must not reach memory")
        }
    }

    func testAResponseWithNoResolutionHeaderIsStillAppliedAndCached() async throws {
        for value in [nil, "resolved"] as [String?] {
            AttributionCaptureProtocol.reset()
            let storage = InMemoryStorage()
            let applied = LockedBox<[[String: AnyCodable]]>([])
            Self.serve(Self.resolvedBody, resolution: value)
            let sync = makeSync(storage: storage, applied: applied)
            await sync.refresh(deviceId: "device-1")

            XCTAssertEqual(nativeHome(applied.get().last), true, "a 200 with header \(value ?? "absent") must apply")
            XCTAssertEqual(storage.data(forKey: StorageKeys.sdkConfig), Data(Self.resolvedBody.utf8),
                           "a 200 with header \(value ?? "absent") must be cached")
        }
    }

    /// A proxy that strips the header turns the refusal off; that must not be silent. Once per process.
    func testAMissingHeaderIsReportedOnce() async {
        let bus = DiagnosticBus()
        Self.serve(Self.resolvedBody, resolution: nil)
        AttributionCaptureProtocol.honorIfNoneMatch = false
        let sync = makeSync(storage: InMemoryStorage(), diagnostics: bus, applied: LockedBox([]))
        await sync.refresh(deviceId: "device-1")
        await sync.refresh(deviceId: "device-1")

        XCTAssertEqual(AttributionCaptureProtocol.configRequestCount, 2)
        XCTAssertEqual(bus.getRecentDiagnostics().filter { $0.code == "config.resolution_header_absent" }.count, 1)
    }

    func testARefusedBodysETagIsNotSentOnTheNextFetch() async {
        let applied = LockedBox<[[String: AnyCodable]]>([])
        Self.serve(Self.defaultsBody, resolution: "unknown_device")
        let sync = makeSync(storage: InMemoryStorage(), applied: applied)
        await sync.refresh(deviceId: "device-1")
        await sync.refresh(deviceId: "device-1")

        XCTAssertEqual(AttributionCaptureProtocol.configIfNoneMatch.count, 2)
        XCTAssertNil(AttributionCaptureProtocol.configIfNoneMatch.last ?? nil,
                     "the refused body's ETag was sent: every later poll would 304 against the defaults")
        XCTAssertTrue(applied.get().isEmpty)
    }

    /// A blip (`lookup_error`) after a resolved body: the applied body's validator is kept.
    func testARefusedBodyKeepsTheValidatorOfTheBodyStillApplied() async {
        let applied = LockedBox<[[String: AnyCodable]]>([])
        let sync = makeSync(storage: InMemoryStorage(), applied: applied)
        Self.serve(Self.resolvedBody, resolution: "resolved")
        await sync.refresh(deviceId: "device-1")
        Self.serve(Self.defaultsBody, resolution: "lookup_error")
        await sync.refresh(deviceId: "device-1")
        await sync.refresh(deviceId: "device-1")

        XCTAssertEqual(AttributionCaptureProtocol.configIfNoneMatch, [nil, "\"v7\"", "\"v7\""])
        XCTAssertEqual(applied.get().count, 1)
        XCTAssertEqual(nativeHome(applied.get().last), true)
    }

    /// The refused body is not "applied", so an owed unconditional refetch stays owed.
    func testARefusedUnconditionalRefetchStaysOwed() async {
        let applied = LockedBox<[[String: AnyCodable]]>([])
        let sync = makeSync(storage: InMemoryStorage(), applied: applied)
        Self.serve(Self.resolvedBody, resolution: "resolved")
        await sync.refresh(deviceId: "device-1")
        Self.serve(Self.defaultsBody, resolution: "unknown_device")
        await sync.refetchUnconditionally(deviceId: "device-1")
        await sync.refresh(deviceId: "device-1")

        XCTAssertEqual(AttributionCaptureProtocol.configIfNoneMatch, [nil, nil, nil],
                       "after a refused unconditional refetch the next fetch must stay unconditional")
    }

    func testARefusalIsLoggedOnTheDiagnosticBusWithABoundedOutcome() async {
        for (value, outcome) in [("lookup_error", "lookup_error"), ("unknown_device", "unknown_device"),
                                 ("something-new <script>", "unrecognized"), ("", "unrecognized")] {
            AttributionCaptureProtocol.reset()
            let bus = DiagnosticBus()
            let applied = LockedBox<[[String: AnyCodable]]>([])
            Self.serve(Self.defaultsBody, resolution: value)
            await makeSync(storage: InMemoryStorage(), diagnostics: bus, applied: applied).refresh(deviceId: "device-1")

            let event = bus.getRecentDiagnostics().last { $0.code == "config.unresolved_body_refused" }
            XCTAssertEqual(event?.severity, .warn, "no refusal diagnostic for \(value.debugDescription)")
            XCTAssertEqual(event?.category, .config)
            XCTAssertEqual(event?.data?["outcome"]?.value as? String, outcome)
            XCTAssertTrue(applied.get().isEmpty, "\(value.debugDescription) is not `resolved`: refused")
        }
    }

    func testTheResolutionHeaderParse() {
        XCTAssertEqual(DeviceResolution(header: nil), .absent)
        XCTAssertEqual(DeviceResolution(header: "resolved"), .resolved)
        XCTAssertEqual(DeviceResolution(header: " Resolved "), .resolved)
        XCTAssertEqual(DeviceResolution(header: "unknown_device"), .unresolved("unknown_device"))
        XCTAssertEqual(DeviceResolution(header: "LOOKUP_ERROR"), .unresolved("lookup_error"))
        XCTAssertEqual(DeviceResolution(header: "x"), .unresolved("unrecognized"))
        XCTAssertEqual(DeviceResolution(header: ""), .unresolved("unrecognized"))
        // Repeated fields arrive comma-joined: resolved only when every token is (contract § 7).
        XCTAssertEqual(DeviceResolution(header: "resolved, resolved"), .resolved)
        XCTAssertEqual(DeviceResolution(header: "RESOLVED,resolved"), .resolved)
        XCTAssertEqual(DeviceResolution(header: "resolved, unknown_device"), .unresolved("unknown_device"))
        XCTAssertEqual(DeviceResolution(header: "resolved,"), .unresolved("unrecognized"))
        XCTAssertFalse(DeviceResolution.absent.refuses)
        XCTAssertFalse(DeviceResolution.resolved.refuses)
    }

    // MARK: - Memory-only: an unresolved body while nothing else is applied (contract § 7)

    func testAnUnresolvedBodyReachesMemoryOnlyWhileNothingElseIsApplied() async {
        let storage = InMemoryStorage()
        let applied = LockedBox<[[String: AnyCodable]]>([])
        let provisional = LockedBox<[[String: AnyCodable]]>([])
        let sync = makeSync(storage: storage, provisional: provisional, applied: applied)
        // The server's default for a device it cannot resolve, e.g. a killed flag served off.
        Self.serve(Self.resolvedBody, resolution: "unknown_device")
        await sync.refresh(deviceId: "device-1")

        XCTAssertEqual(nativeHome(provisional.get().last), true, "nothing applied: the server's defaults reach memory")
        XCTAssertTrue(applied.get().isEmpty, "never as a real apply (no label, no waiters)")
        XCTAssertNil(storage.data(forKey: StorageKeys.sdkConfig), "an unresolved body is never cached")

        Self.serve(Self.defaultsBody, resolution: "lookup_error")
        await sync.refresh(deviceId: "device-1")
        XCTAssertEqual(nativeHome(provisional.get().last), false, "a newer unresolved body replaces a memory-only one")
        XCTAssertEqual(AttributionCaptureProtocol.configIfNoneMatch, [nil, nil], "its ETag is never stored")

        Self.serve(Self.resolvedBody, resolution: "resolved")
        await sync.refresh(deviceId: "device-1")
        XCTAssertEqual(nativeHome(applied.get().last), true)
        Self.serve(Self.defaultsBody, resolution: "unknown_device")
        await sync.refresh(deviceId: "device-1")
        XCTAssertEqual(provisional.get().count, 2, "a real body is applied: an unresolved one is refused")
        XCTAssertEqual(storage.data(forKey: StorageKeys.sdkConfig), Data(Self.resolvedBody.utf8))
    }

    // MARK: - The refetch a registration answer owes

    private func makeSync(gate: ConfigResetGate, bus: DiagnosticBus, applied: LockedBox<[[String: AnyCodable]]>) -> ConfigSync {
        ConfigSync(
            http: HTTPClient(
                config: SheepitConfig(apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64),
                                      apiUrl: "https://stub.invalid", retryAttempts: 1),
                log: Logger(debug: false), urlProtocolClasses: [AttributionCaptureProtocol.self]),
            storage: InMemoryStorage(), refreshInterval: 3600, log: Logger(debug: false), resetGate: gate,
            diagnostics: bus, identityProvider: { (.fetchedUnder(nil), 0) },
            onConfig: { response, _, _ in applied.mutate { $0.append(response.flags) } })
    }

    private func skipReasons(_ bus: DiagnosticBus) -> [String] {
        bus.getRecentDiagnostics().filter { $0.code == "config.registration_refetch_skipped" }
            .compactMap { $0.data?["reason"]?.value as? String }
    }

    /// Keyed on the device id (contract § 7, as sdk-js): a client that moved off the id, or was
    /// destroyed, sends nothing for it, replaced or accepted.
    func testARegistrationRefetchIsDroppedWhenTheDeviceMoved() async {
        let bus = DiagnosticBus()
        let applied = LockedBox<[[String: AnyCodable]]>([])
        let sync = makeSync(gate: ConfigResetGate(), bus: bus, applied: applied)
        Self.serve(Self.resolvedBody, resolution: "resolved")

        await sync.refetchAfterRegistration(deviceId: "device-1", replaced: false, isCurrent: { false })
        await sync.refetchAfterRegistration(deviceId: "device-1", replaced: true, isCurrent: { false })

        XCTAssertEqual(AttributionCaptureProtocol.configRequestCount, 0, "a refetch owed to an abandoned device went out")
        XCTAssertTrue(applied.get().isEmpty)
        XCTAssertEqual(skipReasons(bus), ["superseded", "superseded"])
    }

    /// A `reset()` that KEEPS the device does not drop the refetch: it is sent, under the token
    /// current when it is issued, and applied.
    func testAResetThatKeepsTheDeviceDoesNotDropTheRegistrationRefetch() async {
        let gate = ConfigResetGate()
        let bus = DiagnosticBus()
        let applied = LockedBox<[[String: AnyCodable]]>([])
        let sync = makeSync(gate: gate, bus: bus, applied: applied)
        Self.serve(Self.resolvedBody, resolution: "resolved")
        gate.reset {}

        await sync.refetchAfterRegistration(deviceId: "device-1", replaced: false, isCurrent: { true })

        XCTAssertEqual(AttributionCaptureProtocol.configRequestCount, 1, "a kept device's owed refetch was dropped")
        XCTAssertEqual(nativeHome(applied.get().last), true)
        XCTAssertEqual(skipReasons(bus), [])
    }

    /// Mirrors sdk-js: an unresolved answer for the device the resolved marker names (an erased
    /// row, a lookup failure) clears it, so the next registration refetches.
    func testAnUnresolvedAnswerForTheMarkedDeviceMakesTheNextRegistrationRefetch() async {
        let bus = DiagnosticBus()
        let applied = LockedBox<[[String: AnyCodable]]>([])
        let sync = makeSync(gate: ConfigResetGate(), bus: bus, applied: applied)
        Self.serve(Self.resolvedBody, resolution: "resolved")
        await sync.refresh(deviceId: "device-1")
        Self.serve(Self.defaultsBody, resolution: "unknown_device")
        await sync.refresh(deviceId: "device-1")
        XCTAssertEqual(AttributionCaptureProtocol.configRequestCount, 2, "precondition")

        await sync.refetchAfterRegistration(deviceId: "device-1", replaced: false, isCurrent: { true })

        XCTAssertEqual(AttributionCaptureProtocol.configRequestCount, 3, "the re-registration skipped its refetch on a stale marker")
        XCTAssertEqual(skipReasons(bus), [])
    }

    // MARK: - C1: an accepted registration refetches

    private func makeClient() -> SheepitClient {
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
            urlProtocolClasses: [AttributionCaptureProtocol.self]
        )
        client.deviceRotationRetryDelayForTesting = { _ in .milliseconds(20) }
        return client
    }

    /// Read from the bus's buffer: a subscription made after `create()` misses what the launch fetch
    /// emitted before it.
    private struct Codes {
        let client: SheepitClient
        func get() -> [String] { client.diagnostics().getRecentDiagnostics().map(\.code) }
    }

    private func codes(_ client: SheepitClient) -> Codes { Codes(client: client) }

    /// The server's view: a device resolves once a register created its row.
    private static func modelTheServer() {
        AttributionCaptureProtocol.serveConfig(resolvedBody)
        AttributionCaptureProtocol.configResolution = { _, hasRow in hasRow ? "resolved" : "unknown_device" }
        AttributionCaptureProtocol.echoRegisteredDeviceId = true
    }

    func testAnAcceptedFirstRegistrationAfterAnUnresolvedFetchRefetchesAndAppliesTheResolvedBody() async {
        Self.modelTheServer()
        // What the server answers a device with no row: every flag on its default.
        AttributionCaptureProtocol.serveConfig(Self.defaultsBody)
        AttributionCaptureProtocol.holdRegister = true
        let client = makeClient()
        defer { client.destroy() }
        let diagnostics = codes(client)
        let proposal = client.status().deviceId

        let landed = await waitUntil { diagnostics.get().contains("config.unresolved_body_refused") }
        XCTAssertTrue(landed, "precondition: the launch fetch ran before registration answered, and was refused")
        XCTAssertEqual(client.flag("native_home"), .bool(false), "precondition: no resolved body yet")
        let mark = AttributionCaptureProtocol.configRequestCount
        AttributionCaptureProtocol.serveConfig(Self.resolvedBody)
        AttributionCaptureProtocol.releaseHeldRegister()

        let resolved = await waitUntil { client.flag("native_home") == .bool(true) }
        XCTAssertTrue(resolved, "the resolved body never applied: the app read defaults until the next poll")
        XCTAssertEqual(client.status().deviceId, proposal, "precondition: the proposal was accepted, not replaced")
        XCTAssertEqual(AttributionCaptureProtocol.configRequestCount, mark + 1, "exactly one refetch")
        XCTAssertNil(AttributionCaptureProtocol.configIfNoneMatch.last ?? nil, "the refetch is unconditional")
        XCTAssertTrue(diagnostics.get().contains("config.refetch_on_registration"))
    }

    /// An app update re-registers the same id. A resolved body already applies: no request.
    func testAReRegistrationWithAResolvedBodyAlreadyAppliedDoesNotRefetch() async {
        let device = SharedSDKStorage.markRegistered()
        UserDefaults(suiteName: SharedSDKStorage.suite)?.set(
            "0.0.0-previous", forKey: SharedSDKStorage.slot(StorageKeys.deviceRegisteredAppVersion))
        AttributionCaptureProtocol.serveConfig(Self.resolvedBody)
        AttributionCaptureProtocol.configResolution = { _, _ in "resolved" }
        AttributionCaptureProtocol.echoRegisteredDeviceId = true
        AttributionCaptureProtocol.holdRegister = true
        let client = makeClient()
        defer { client.destroy() }
        let diagnostics = codes(client)

        let applied = await waitUntil { client.flag("native_home") == .bool(true) }
        XCTAssertTrue(applied, "precondition: the launch fetch applied a resolved body")
        let held = await waitUntil { AttributionCaptureProtocol.registerRequestCount >= 1 }
        XCTAssertTrue(held, "precondition: the app update re-registers")
        AttributionCaptureProtocol.releaseHeldRegister()
        let registered = await waitUntil { diagnostics.get().contains("identity.device_registered") }
        XCTAssertTrue(registered)
        XCTAssertEqual(client.status().deviceId, device)
        let decided = await waitUntil {
            client.getRecentDiagnostics().contains {
                $0.code == "config.registration_refetch_skipped" && $0.data?["reason"]?.value as? String == "resolved_applied"
            }
        }
        XCTAssertTrue(decided, "the registration answer never decided against a refetch")

        XCTAssertEqual(AttributionCaptureProtocol.configRequestCount, 1, "a re-registration refetched a resolved config")
        XCTAssertFalse(diagnostics.get().contains("config.refetch_on_registration"))
    }

    /// The same gap after a logout rotation: every fetch since `reset()` named the fresh device,
    /// which has no row until its registration is accepted.
    func testAnAcceptedRotationRegistrationRefetchesForTheFreshDevice() async {
        let oldDevice = SharedSDKStorage.markRegistered()
        Self.modelTheServer()
        AttributionCaptureProtocol.configResolution = { device, hasRow in
            device == oldDevice || hasRow ? "resolved" : "unknown_device"
        }
        let client = makeClient()
        defer { client.destroy() }
        let applied = await waitUntil { client.flag("native_home") == .bool(true) }
        XCTAssertTrue(applied, "precondition: the old device's config applied")
        client.identify(userId: "user-\(UUID().uuidString)")
        await client.awaitIdentityPostForTesting()

        AttributionCaptureProtocol.holdRegister = true
        client.reset()
        let fresh = client.status().deviceId
        XCTAssertNotEqual(fresh, oldDevice, "precondition: reset() rotated")
        XCTAssertEqual(client.flag("native_home"), .bool(false), "precondition: reset() cleared the values")
        let held = await waitUntil { AttributionCaptureProtocol.registerRequestCount >= 1 }
        XCTAssertTrue(held, "precondition: the fresh device is registering")
        AttributionCaptureProtocol.releaseHeldRegister()

        let resolved = await waitUntil { client.flag("native_home") == .bool(true) }
        XCTAssertTrue(resolved, "no config for the fresh device until the next poll")
        XCTAssertEqual(client.status().deviceId, fresh, "precondition: the proposal was accepted")
        XCTAssertEqual(AttributionCaptureProtocol.configDeviceIds.last, fresh)
    }

    /// 🔴 A `reset()` between the registration answer and the refetch it owes: the refetch named the
    /// abandoned device, whose row still holds the logged-out user, and applied and cached their body.
    func testAResetRacingTheRegistrationRefetchSendsNothingForTheAbandonedDevice() async throws {
        let device = SharedSDKStorage.markRegistered()
        let defaults = UserDefaults(suiteName: SharedSDKStorage.suite)
        defaults?.set("0.0.0-previous", forKey: SharedSDKStorage.slot(StorageKeys.deviceRegisteredAppVersion))
        // The row holds a user, so `reset()` rotates (`DeviceRotation.deviceMayBeBound`).
        defaults?.set(try JSONEncoder().encode(ServerHeldUser.known("user-u")),
                      forKey: SharedSDKStorage.slot(StorageKeys.serverHeldUser))
        let userBody = Self.resolvedBody
        let anonymousBody = #"{"data":{"config_version":"7","etag":"\"a7\"","flags":{"native_home":false},"experiments":{}}}"#
        AttributionCaptureProtocol.configResponder = { id, hasRow in
            if id == device { return (userBody, "resolved") }
            return hasRow ? (anonymousBody, "resolved") : (Self.defaultsBody, "unknown_device")
        }
        AttributionCaptureProtocol.echoRegisteredDeviceId = true
        AttributionCaptureProtocol.holdRegister = true
        let client = makeClient()
        defer { client.destroy() }
        let applied = await waitUntil { client.flag("native_home") == .bool(true) }
        XCTAssertTrue(applied, "precondition: the user's config applied at launch")
        // The logout lands inside the registration answer, before the refetch it owes runs.
        let once = LockedBox(false)
        client.diagnostics().subscribe { event in
            guard event.code == "identity.device_registered" else { return }
            var first = false
            once.mutate { first = !$0; $0 = true }
            if first { client.reset() }
        }
        let mark = AttributionCaptureProtocol.configDeviceIds.count
        AttributionCaptureProtocol.releaseHeldRegister()

        let fresh = await waitUntil { client.status().deviceId != device }
        XCTAssertTrue(fresh, "precondition: reset() rotated")
        let freshId = client.status().deviceId ?? ""
        let settled = await waitUntil { AttributionCaptureProtocol.configDeviceIds.dropFirst(mark).contains(freshId) }
        XCTAssertTrue(settled, "precondition: the fresh device registered and fetched")
        let dropped = await waitUntil {
            client.getRecentDiagnostics().contains {
                $0.code == "config.registration_refetch_skipped" && $0.data?["reason"]?.value as? String == "superseded"
            }
        }
        XCTAssertTrue(dropped, "the abandoned device's refetch was not dropped")
        XCTAssertFalse(AttributionCaptureProtocol.configDeviceIds.dropFirst(mark).contains(device),
                       "a config request named the abandoned device after the logout")
        XCTAssertEqual(client.flag("native_home"), .bool(false), "the logged-out user's config is applied")
        let cached = defaults?.data(forKey: SharedSDKStorage.slot(StorageKeys.sdkConfig))
        XCTAssertNotEqual(cached, Data(userBody.utf8), "the logged-out user's config was cached after the logout")
    }

    /// S-D: the accepted-registration refetch is one-shot. A failed one leaves later polls
    /// conditional, so a 304 can still confirm the cache (`confirmCachedBody`).
    func testAFailedAcceptedRegistrationRefetchLeavesLaterPollsConditional() async {
        // A server that sends no resolution header: the accepted registration refetches once.
        AttributionCaptureProtocol.serveConfig(Self.resolvedBody)
        AttributionCaptureProtocol.echoRegisteredDeviceId = true
        AttributionCaptureProtocol.holdRegister = true
        let client = makeClient()
        defer { client.destroy() }
        let applied = await waitUntil { client.flag("native_home") == .bool(true) }
        XCTAssertTrue(applied, "precondition: the launch fetch applied")
        AttributionCaptureProtocol.failNextConfigRequests(1)
        AttributionCaptureProtocol.releaseHeldRegister()
        let refetched = await waitUntil { AttributionCaptureProtocol.configRequestCount >= 2 }
        XCTAssertTrue(refetched, "precondition: the accepted registration refetched (and it failed)")
        XCTAssertNil(AttributionCaptureProtocol.configIfNoneMatch.last ?? nil, "precondition: unconditional")

        await client.refreshConfigForTesting()

        XCTAssertEqual(AttributionCaptureProtocol.configIfNoneMatch.last ?? nil, "\"v7\"",
                       "a failed registration refetch left every later poll unconditional")
    }

    /// S-E: on a fresh install `awaitConfig` waits for the body fetched after registration; the
    /// launch answer (`unknown_device`, applied to memory only) never satisfies it.
    func testAwaitConfigOnAFreshInstallWaitsForTheFetchAfterRegistration() async {
        AttributionCaptureProtocol.configResponder = { _, hasRow in
            hasRow ? (Self.resolvedBody, "resolved") : (Self.defaultsBody, "unknown_device")
        }
        AttributionCaptureProtocol.echoRegisteredDeviceId = true
        AttributionCaptureProtocol.holdRegister = true
        let client = makeClient()
        defer { client.destroy() }
        let refused = await waitUntil { client.getRecentDiagnostics().contains { $0.code == "config.unresolved_body_refused" } }
        XCTAssertTrue(refused, "precondition: the launch fetch landed unresolved")

        let early = await client.awaitConfig(timeout: .milliseconds(200))
        XCTAssertFalse(early, "an unresolved body counted as the config")
        AttributionCaptureProtocol.releaseHeldRegister()
        let ready = await client.awaitConfig(timeout: .seconds(5))

        XCTAssertTrue(ready)
        XCTAssertEqual(client.flag("native_home"), .bool(true))
    }

    /// § 7 memory-only (was PENDING_WORK Q6): a device whose registration never succeeds still gets the server's defaults (killed
    /// flags included) in memory, and never caches them.
    func testADeviceThatNeverRegistersGetsTheServersDefaultsInMemoryOnly() async {
        // The server's defaults differ from the compiled-in one (`.bool(false)`).
        AttributionCaptureProtocol.configResponder = { _, _ in (Self.resolvedBody, "unknown_device") }
        AttributionCaptureProtocol.failNextRegisterRequests(
            100, status: 400, body: #"{"error":{"code":"VALIDATION_ERROR","message":"stub"}}"#)
        let client = makeClient()
        defer { client.destroy() }

        let served = await waitUntil { client.flag("native_home") == .bool(true) }

        XCTAssertTrue(served, "the server's defaults never reached memory")
        XCTAssertNil(UserDefaults(suiteName: SharedSDKStorage.suite)?.data(forKey: SharedSDKStorage.slot(StorageKeys.sdkConfig)),
                     "an unresolved body was cached")
        XCTAssertNil(client.status().configFreshness, "a memory-only body is not a fetched config")
        // Its exposures are labelled, so an analysis can drop untargeted defaults.
        let exposed = await waitUntil {
            client.drainQueuedEventsForTesting().contains {
                $0.eventName == "$flag_exposure" && $0.eventProperties?["config_source"]?.value as? String == "unresolved"
            }
        }
        XCTAssertTrue(exposed, "a memory-only exposure carried no config_source")
    }

    /// `reset()` from inside the registration answer, before the refetch it owes runs. Later
    /// registrations (the rotation's) are then honoured as proposed.
    private func resetOnFirstRegistrationAnswer(_ client: SheepitClient) {
        let once = LockedBox(false)
        client.diagnostics().subscribe { event in
            guard event.code == "identity.device_registered" else { return }
            var first = false
            once.mutate { first = !$0; $0 = true }
            guard first else { return }
            AttributionCaptureProtocol.echoRegisteredDeviceId = true
            client.reset()
        }
    }

    private func skipped(_ client: SheepitClient) -> [String] {
        client.getRecentDiagnostics().filter { $0.code == "config.registration_refetch_skipped" }
            .compactMap { $0.data?["reason"]?.value as? String }
    }

    /// BLOCKER 1: a `reset()` that keeps the device, landing between the registration answer and
    /// the refetch it owes, does not drop it (contract § 7). It is sent and applied.
    func testAResetKeepingTheDeviceStillSendsAndAppliesTheOwedRefetch() async {
        AttributionCaptureProtocol.configResponder = { _, hasRow in
            hasRow ? (Self.resolvedBody, "resolved") : (Self.defaultsBody, "unknown_device")
        }
        AttributionCaptureProtocol.echoRegisteredDeviceId = true
        AttributionCaptureProtocol.holdRegister = true
        let client = makeClient()
        defer { client.destroy() }
        let device = client.status().deviceId ?? ""
        let landed = await waitUntil { client.getRecentDiagnostics().contains { $0.code == "config.unresolved_body_refused" } }
        XCTAssertTrue(landed, "precondition: the launch fetch landed unresolved")
        resetOnFirstRegistrationAnswer(client)
        let mark = AttributionCaptureProtocol.configDeviceIds.count
        AttributionCaptureProtocol.releaseHeldRegister()

        let applied = await waitUntil { client.flag("native_home") == .bool(true) }

        XCTAssertTrue(client.getRecentDiagnostics().contains { $0.code == "identity.device_kept_on_reset" },
                      "precondition: reset() kept the device")
        XCTAssertEqual(client.status().deviceId, device)
        XCTAssertTrue(applied, "the owed refetch was dropped by a reset that kept the device")
        XCTAssertEqual(Array(AttributionCaptureProtocol.configDeviceIds.dropFirst(mark)), [device])
        XCTAssertEqual(skipped(client), [])
    }

    /// The replaced-id refetch goes through the same drop rule: a logout that rotates away from the
    /// replaced id, racing its refetch, sends nothing naming it and applies nothing from it.
    func testAReplacedIdRefetchRacingARotatingResetSendsNothingForIt() async throws {
        let replacedId = "dev_replaced_\(UUID().uuidString.lowercased())"
        // A row an identify may already have bound, so `reset()` rotates away from it.
        UserDefaults(suiteName: SharedSDKStorage.suite)?.set(
            String(data: try JSONEncoder().encode([replacedId]), encoding: .utf8),
            forKey: StorageKeys.deviceBindAttempted)
        let userBody = Self.resolvedBody
        AttributionCaptureProtocol.configResponder = { id, hasRow in
            if id == replacedId { return (userBody, "resolved") }
            return hasRow ? (Self.defaultsBody, "resolved") : (Self.defaultsBody, "unknown_device")
        }
        AttributionCaptureProtocol.registerDeviceId = replacedId
        AttributionCaptureProtocol.holdRegister = true
        let client = makeClient()
        defer { client.destroy() }
        let landed = await waitUntil { client.getRecentDiagnostics().contains { $0.code == "config.unresolved_body_refused" } }
        XCTAssertTrue(landed, "precondition: the launch fetch landed unresolved")
        resetOnFirstRegistrationAnswer(client)
        let mark = AttributionCaptureProtocol.configDeviceIds.count
        AttributionCaptureProtocol.releaseHeldRegister()

        let dropped = await waitUntil { self.skipped(client).contains("superseded") }

        XCTAssertTrue(dropped, "the replaced id's refetch was not dropped after the rotation")
        XCTAssertNotEqual(client.status().deviceId, replacedId, "precondition: reset() rotated away from it")
        XCTAssertFalse(AttributionCaptureProtocol.configDeviceIds.dropFirst(mark).contains(replacedId),
                       "a config request named the abandoned replaced id")
        XCTAssertEqual(client.flag("native_home"), .bool(false), "the abandoned row's body was applied")
        XCTAssertNotEqual(UserDefaults(suiteName: SharedSDKStorage.suite)?.data(forKey: SharedSDKStorage.slot(StorageKeys.sdkConfig)),
                          Data(userBody.utf8))
    }

    /// A `lookup_error` is a server failure, not evidence the row is gone: it leaves the resolved
    /// record, so an app-update re-registration with that body still applied skips its refetch
    /// (contract § 7). An `unknown_device` clears it (`testAnUnresolvedAnswerForTheMarkedDevice…`)
    /// and, client-side, replaces the device (C5, `ConfigErasedDeviceTests`).
    func testALookupErrorPollKeepsTheRecordSoTheReRegistrationSkipsItsRefetch() async {
        let device = SharedSDKStorage.markRegistered()
        UserDefaults(suiteName: SharedSDKStorage.suite)?.set(
            "0.0.0-previous", forKey: SharedSDKStorage.slot(StorageKeys.deviceRegisteredAppVersion))
        let failing = LockedBox(false)
        AttributionCaptureProtocol.configResponder = { _, _ in
            failing.get() ? (Self.defaultsBody, "lookup_error") : (Self.resolvedBody, "resolved")
        }
        AttributionCaptureProtocol.echoRegisteredDeviceId = true
        AttributionCaptureProtocol.holdRegister = true
        let client = makeClient()
        defer { client.destroy() }
        let applied = await waitUntil { client.flag("native_home") == .bool(true) }
        XCTAssertTrue(applied, "precondition: a resolved body applied at launch")
        failing.set(true)
        await client.refreshConfigForTesting()
        XCTAssertTrue(client.getRecentDiagnostics().contains { $0.code == "config.unresolved_body_refused" },
                      "precondition: the poll was answered unresolved")
        failing.set(false)
        let mark = AttributionCaptureProtocol.configRequestCount
        AttributionCaptureProtocol.releaseHeldRegister()

        let decided = await waitUntil { self.skipped(client).contains("resolved_applied") }

        XCTAssertTrue(decided, "a lookup_error cleared the resolved record")
        XCTAssertEqual(AttributionCaptureProtocol.configRequestCount, mark)
        XCTAssertEqual(client.status().deviceId, device)
    }
}
