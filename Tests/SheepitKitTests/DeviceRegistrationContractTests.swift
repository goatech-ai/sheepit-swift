import XCTest
@testable import SheepitKit

/// The cross-SDK device registration contract, end to end through a real client:
/// `Docs/Technical/SDK_DEVICE_REGISTRATION_CONTRACT.md`, acceptance tests 1–5, 8 and 10. Every test
/// here fails against 0.9.x, which sent no `device_id` on a fresh install, retried inside the HTTP
/// client, persisted nothing for a transient failure or a 429, and never re-registered on an app
/// update. Unit-level halves (delay math, the record, host rules) are in `RegistrationPolicyTests`
/// and `APIURLValidationTests`.
final class DeviceRegistrationContractTests: XCTestCase {
    private func makeConfig() -> SheepitConfig {
        SheepitConfig(
            apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))",
            apiUrl: "https://stub.invalid",
            configRefreshInterval: 300,
            retryAttempts: 3,
            crashes: CrashConfig(enabled: false)
        )
    }

    override func setUp() {
        super.setUp()
        SharedSDKStorage.clear()
        ContractStub.reset()
        TeardownFlushes.install()
    }

    override func tearDown() async throws {
        await TeardownFlushes.drain(context: name)
        SharedSDKStorage.clear()
        ContractStub.reset()
        try await super.tearDown()
    }

    private func makeClient(
        now: @escaping @Sendable () -> Date = { Date() },
        retryDelay: (@Sendable (TimeInterval) -> Duration)? = { _ in .milliseconds(5) }
    ) -> SheepitClient {
        SheepitClient.createForTesting(
            config: makeConfig(),
            now: now,
            urlProtocolClasses: [ContractStub.self],
            launchRegistrationRetryDelay: retryDelay
        )
    }

    private func waitUntil(timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private var proposals: [String?] { ContractStub.registerBodies().map { $0["device_id"] as? String } }

    // MARK: - 1. Lost reply

    func testALostReplyIsRetriedWithTheSameProposalAndChangesNothing() async {
        ContractStub.script = [.lost, .echo]
        let changes = LockedBox<[String]>([])
        let client = makeClient()
        client.deviceIdChangeHookForTesting.value = { id in changes.mutate { $0.append(id) } }
        defer { client.destroy() }
        let minted = client.status().deviceId

        await waitUntil { SharedSDKStorage.isRegistered() }

        XCTAssertEqual(proposals, [minted, minted], "the retry re-sends the SAME proposal: it is the idempotency key")
        XCTAssertEqual(client.status().deviceId, minted, "the honoured proposal stays the device id")
        XCTAssertEqual(changes.get(), [], "an accepted proposal fires no device-id change callback")
    }

    /// A stored legacy id of a non-minted (but usable) shape is proposed verbatim.
    func testALegacyStoredIdIsProposedVerbatim() async {
        UserDefaults(suiteName: SharedSDKStorage.suite)?.set("legacy:odd", forKey: SharedSDKStorage.slot(StorageKeys.deviceId))
        ContractStub.script = [.echo]
        let client = makeClient()
        defer { client.destroy() }
        await waitUntil { SharedSDKStorage.isRegistered() }
        XCTAssertEqual(proposals, ["legacy:odd"])
        XCTAssertEqual(client.status().deviceId, "legacy:odd")
    }

    // MARK: - 2. Replaced vs accepted

    func testAReplacedProposalReStampsQueuedEventsAndRefetchesConfig() async {
        ContractStub.script = [.replace("dev_server_assigned")]
        ContractStub.registerDelay = 0.3
        let changes = LockedBox<[String]>([])
        let client = makeClient()
        client.deviceIdChangeHookForTesting.value = { id in changes.mutate { $0.append(id) } }
        defer { client.destroy() }
        client.track("before_registration_answers")

        await waitUntil { ContractStub.configDeviceIds().contains("dev_server_assigned") }

        XCTAssertEqual(changes.get(), ["dev_server_assigned"])
        XCTAssertEqual(client.getRecentDiagnostics().last { $0.code == "identity.device_registered" }?.data?["outcome"]?.value as? String,
                       "replaced")
        XCTAssertTrue(ContractStub.configDeviceIds().contains("dev_server_assigned"), "config is refetched for the new row")
        let queued = client.drainQueuedEventsForTesting().filter { $0.eventName == "before_registration_answers" }
        XCTAssertEqual(queued.map(\.deviceId), ["dev_server_assigned"], "queued events are re-stamped to the adopted id")
    }

    /// With a resolved body already applied. Without one, an accepted proposal refetches once
    /// (`ConfigDeviceResolutionTests`).
    func testAnAcceptedProposalFiresNoChangeCallbackAndNoConfigRefetch() async {
        ContractStub.script = [.echo]
        ContractStub.registerDelay = 0.3
        let changes = LockedBox<[String]>([])
        let client = makeClient()
        client.deviceIdChangeHookForTesting.value = { id in changes.mutate { $0.append(id) } }
        defer { client.destroy() }
        let minted = client.status().deviceId

        await waitUntil { SharedSDKStorage.isRegistered() }
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(changes.get(), [], "nothing changed hands, so nothing is announced")
        XCTAssertEqual(client.getRecentDiagnostics().last { $0.code == "identity.device_registered" }?.data?["outcome"]?.value as? String,
                       "proposed")
        XCTAssertEqual(Set(ContractStub.configDeviceIds()), [minted], "no config fetch names any other id")
        XCTAssertLessThanOrEqual(ContractStub.configDeviceIds().count, 1, "no config invalidation on an accepted proposal")
    }

    // MARK: - 3. The same X-Device-ID before and after registration

    func testConfigCarriesTheSameDeviceIdBeforeAndAfterRegistration() async {
        ContractStub.script = [.echo]
        ContractStub.registerDelay = 0.2
        let client = makeClient()
        defer { client.destroy() }

        await waitUntil { !ContractStub.configDeviceIds().isEmpty }
        let before = ContractStub.configDeviceIds().first
        await waitUntil { SharedSDKStorage.isRegistered() }
        await client.refreshConfigForTesting()

        XCTAssertNotNil(before)
        XCTAssertEqual(ContractStub.configDeviceIds().last, before, "post-register config names the pre-register id")
    }

    // MARK: - 4. The attempt budget

    func testTheSeventhAttemptInALaunchNeverFires() async {
        ContractStub.script = Array(repeating: .status(503), count: 20)
        let client = makeClient()
        defer { client.destroy() }

        await waitUntil { client.getRecentDiagnostics().contains { $0.code == "identity.device_registration_budget_exhausted" } }
        try? await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(ContractStub.registerBodies().count, RegistrationPolicy.attemptsPerLaunch,
                       "six attempts per launch, each a single HTTP request: no inner retry layer")
        XCTAssertEqual(SharedSDKStorage.backoffRecord()?.failuresTotal, 6, "every failure was persisted")
    }

    // MARK: - 5. A persisted window spans launches

    func testAFirstAttemptFailurePersistsAWindowThatGatesTheNextLaunch() async {
        let launch1 = Date(timeIntervalSince1970: 1_800_000_000)
        ContractStub.script = [.status(500)]
        let first = makeClient(now: { launch1 }, retryDelay: { _ in .seconds(60) })
        await waitUntil { SharedSDKStorage.backoffRecord() != nil }
        first.destroy()
        let record = SharedSDKStorage.backoffRecord()
        XCTAssertEqual(record?.failuresTotal, 1)
        XCTAssertTrue((1...2).contains((record?.until ?? 0) - launch1.timeIntervalSince1970), "the first window is jittered in [1 s, 2 s]")

        // Relaunch inside the window: nothing is sent (the deferred attempt waits it out).
        ContractStub.script = [.echo]
        let inside = makeClient(now: { launch1.addingTimeInterval(0.5) }, retryDelay: { _ in .seconds(60) })
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(ContractStub.registerBodies().count, 1, "a relaunch inside the window sends nothing")
        inside.destroy()

        // Relaunch after it: registers at once.
        let after = makeClient(now: { launch1.addingTimeInterval(3) })
        defer { after.destroy() }
        await waitUntil { SharedSDKStorage.isRegistered() }
        XCTAssertEqual(ContractStub.registerBodies().count, 2, "a relaunch after the window registers")
        XCTAssertNil(SharedSDKStorage.backoffRecord(), "success clears the record")
    }

    // MARK: - 8. An unexpected transport throw

    func testAnUnexpectedTransportErrorIsTransientAndPersisted() async {
        ContractStub.script = [.fail(NSError(domain: "UnexpectedTransport", code: 42))]
        let client = makeClient(retryDelay: { _ in .seconds(60) })
        defer { client.destroy() }

        await waitUntil { SharedSDKStorage.backoffRecord() != nil }

        XCTAssertEqual(SharedSDKStorage.backoffRecord()?.failuresTotal, 1, "the throw landed in a class that persists")
        let failure = client.getRecentDiagnostics().last { $0.code == "identity.device_registration_failed" }
        XCTAssertEqual(failure?.data?["outcome"]?.value as? String, "network_error")
    }

    // MARK: - IDENTIFY_WAIT_BUDGET (11 s)

    /// A reload inside a 24 h terminal window: `identify(userId:timeout:)` settles at once instead of
    /// waiting out the window or sending a POST that could only 404; `track()` and flags carry on.
    func testIdentifyInsideALongWindowSettlesPromptlyAndTrackAndFlagsAreUnaffected() async {
        let launch = Date(timeIntervalSince1970: 1_800_000_000)
        SharedSDKStorage.seedBackoff(until: launch.addingTimeInterval(SDKDefaults.deviceRegistrationTerminalBackoff))
        let client = makeClient(now: { launch }, retryDelay: { _ in .seconds(60) })
        defer { client.destroy() }

        let started = Date()
        let outcome = await client.identify(userId: "user-in-window", timeout: .seconds(5))
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertEqual(outcome, .failed, "settles \"not registered yet\"")
        XCTAssertLessThan(elapsed, 1, "no wait toward a 24 h window or the 5 s timeout")
        XCTAssertGreaterThan(RegistrationBackoff.load(storage: SharedSDKStorage.slotStorage(), now: launch)?.until ?? 0,
                             launch.timeIntervalSince1970 + RegistrationPolicy.identifyWaitBudgetSeconds)
        XCTAssertEqual(ContractStub.identifyPaths(), [], "no identify POST that could only 404")
        XCTAssertEqual(ContractStub.registerBodies().count, 0, "nothing is sent inside the window")
        XCTAssertTrue(client.getRecentDiagnostics().contains { $0.code == "identity.identify_deferred" })
        XCTAssertEqual(client.status().userId, "user-in-window", "the app's label is kept for the later bind")

        let before = client.status().queueDepth
        client.track("still_tracked")
        XCTAssertEqual(client.status().queueDepth, before + 1, "track() is unaffected")
        XCTAssertEqual(client.flag("any_flag", default: .bool(true)).boolValue, true, "flags answer as usual")
    }

    /// A7b: an identify that is never sent (inside a long window) settles its identity switch and
    /// owes a server config at once. The periodic poll would 304 and apply nothing, leaving every
    /// device-kind claim unattributed for the session (`ExperimentManager.IdentitySwitch`).
    func testANeverSentIdentifyFetchesConfigSoItsIdentitySwitchCanEnd() async {
        let launch = Date(timeIntervalSince1970: 1_800_000_000)
        SharedSDKStorage.seedBackoff(until: launch.addingTimeInterval(SDKDefaults.deviceRegistrationTerminalBackoff))
        let client = makeClient(now: { launch }, retryDelay: { _ in .seconds(60) })
        defer { client.destroy() }
        await waitUntil { ContractStub.configDeviceIds().count >= 1 }
        let before = ContractStub.configDeviceIds().count
        XCTAssertEqual(before, 1, "precondition: the launch fetch landed, and the next poll is 300 s away")

        client.identify(userId: "user-never-sent")
        await waitUntil { ContractStub.configDeviceIds().count > before }

        XCTAssertTrue(client.getRecentDiagnostics().contains { $0.code == "identity.identify_deferred" },
                      "precondition: the identify was never sent")
        XCTAssertEqual(ContractStub.identifyPaths(), [])
        XCTAssertEqual(ContractStub.configDeviceIds().count, before + 1, "the settle fetched config at once")
    }

    /// An unresolved answer is applied to memory only (`ConfigApplyOrigin.provisional`), and was
    /// evaluated for no known row, so it must not end the switch: a merge of #1489 into A7b first
    /// wired it with the default origin, a server fetch started after every settle, which did.
    func testAnUnresolvedConfigDoesNotEndANeverSentIdentifysSwitch() async {
        ContractStub.configResolution = "unknown_device"
        let launch = Date(timeIntervalSince1970: 1_800_000_000)
        SharedSDKStorage.seedBackoff(until: launch.addingTimeInterval(SDKDefaults.deviceRegistrationTerminalBackoff))
        let client = makeClient(now: { launch }, retryDelay: { _ in .seconds(60) })
        defer { client.destroy() }
        await waitUntil { ContractStub.configDeviceIds().count >= 1 }
        let before = ContractStub.configDeviceIds().count

        client.identify(userId: "user-never-sent")
        await waitUntil { ContractStub.configDeviceIds().count > before }
        await waitUntil { client.getRecentDiagnostics().filter { $0.code == "config.unresolved_body_refused" }.count >= 2 }

        XCTAssertEqual(client.getRecentDiagnostics().filter { $0.code == "config.unresolved_body_refused" }.count, 2,
                       "precondition: the settle's refetch was answered unresolved")
        XCTAssertTrue(client.identitySwitchPendingForTesting, "an unresolved body must not end the switch")
    }

    /// A window within IDENTIFY_WAIT_BUDGET is waited out: the identify goes out after the
    /// deferred registration, for the registered id.
    func testIdentifyInsideAShortWindowWaitsForTheRegistration() async {
        SharedSDKStorage.seedBackoff(until: Date().addingTimeInterval(0.3))
        ContractStub.script = [.echo]
        let client = makeClient(retryDelay: nil)
        defer { client.destroy() }
        let deviceId = client.status().deviceId ?? ""

        let outcome = await client.identify(userId: "user-after-window", timeout: .seconds(5))

        XCTAssertNotEqual(outcome, .failed)
        XCTAssertEqual(ContractStub.registerBodies().count, 1)
        XCTAssertEqual(ContractStub.identifyPaths(), [SDKEndpoints.deviceIdentify(deviceId: deviceId)])
    }

    // MARK: - 10. Re-register on an app-version change

    func testAnAppVersionChangeRegistersAgainWithTheSameId() async {
        let deviceId = SharedSDKStorage.markRegistered()
        UserDefaults(suiteName: SharedSDKStorage.suite)?.set(
            "0.0.0-previous-build", forKey: SharedSDKStorage.slot(StorageKeys.deviceRegisteredAppVersion))
        ContractStub.script = [.echo]
        let client = makeClient()
        defer { client.destroy() }

        await waitUntil { SharedSDKStorage.isRegistered() && !ContractStub.registerBodies().isEmpty }
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(proposals, [deviceId], "an updated app re-registers, proposing the same id")
        XCTAssertEqual(
            UserDefaults(suiteName: SharedSDKStorage.suite)?.string(forKey: SharedSDKStorage.slot(StorageKeys.deviceRegisteredAppVersion)),
            SharedSDKStorage.registeredAppVersion)
    }

    func testTheSameAppVersionDoesNotRegisterAgain() async {
        SharedSDKStorage.markRegistered()
        ContractStub.script = [.echo]
        let client = makeClient()
        defer { client.destroy() }
        await waitUntil { !ContractStub.configDeviceIds().isEmpty }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(ContractStub.registerBodies().count, 0)
    }
}

/// A path-aware stub for `https://stub.invalid` whose register answers come from `script`, in
/// order (the last entry repeats once it runs out; echo when empty). Records register bodies and
/// every config request's `X-Device-ID`.
final class ContractStub: URLProtocol, @unchecked Sendable {
    enum Reply {
        /// 201 with the proposed `device_id`.
        case echo
        /// 201 with this `device_id` instead of the proposal.
        case replace(String)
        case status(Int)
        /// The request went out and no reply came back.
        case lost
        case fail(Error)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _script: [Reply] = []
    nonisolated(unsafe) private static var _registerDelay: TimeInterval = 0
    nonisolated(unsafe) private static var bodies: [[String: Any]] = []
    nonisolated(unsafe) private static var configIds: [String] = []
    nonisolated(unsafe) private static var identifies: [String] = []
    nonisolated(unsafe) private static var _configResolution = "resolved"

    static var script: [Reply] {
        get { lock.lock(); defer { lock.unlock() }; return _script }
        set { lock.lock(); _script = newValue; lock.unlock() }
    }

    static var registerDelay: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return _registerDelay }
        set { lock.lock(); _registerDelay = newValue; lock.unlock() }
    }

    /// The `X-Sheepit-Device-Resolution` every config 200 carries; `resolved` by default.
    static var configResolution: String {
        get { lock.lock(); defer { lock.unlock() }; return _configResolution }
        set { lock.lock(); _configResolution = newValue; lock.unlock() }
    }

    static func registerBodies() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return bodies }
    static func configDeviceIds() -> [String] { lock.lock(); defer { lock.unlock() }; return configIds }
    static func identifyPaths() -> [String] { lock.lock(); defer { lock.unlock() }; return identifies }

    static func reset() {
        lock.lock()
        _script = []
        _registerDelay = 0
        bodies = []
        configIds = []
        identifies = []
        _configResolution = "resolved"
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        guard let url = request.url else { return }
        if url.path == SDKEndpoints.deviceRegister {
            let body = (Self.body(of: request).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) ?? [:]
            Self.lock.lock()
            Self.bodies.append(body)
            let reply = Self._script.isEmpty ? .echo : Self._script.count == 1 ? Self._script[0] : Self._script.removeFirst()
            let delay = Self._registerDelay
            Self.lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                self.answer(reply, proposal: body["device_id"] as? String, url: url)
            }
            return
        }
        if url.path == SDKEndpoints.config {
            Self.lock.lock()
            Self.configIds.append(request.value(forHTTPHeaderField: "X-Device-ID") ?? "")
            let resolution = Self._configResolution
            Self.lock.unlock()
            // `resolved` by default, as the current server says once the device's row exists: an
            // accepted registration then refetches nothing (`ConfigSync.refetchAfterRegistration`).
            respond(200, #"{"data":{"config_version":"1","etag":"e1","flags":{},"experiments":{}}}"#, url: url,
                    headers: ["X-Sheepit-Device-Resolution": resolution])
            return
        }
        if url.path.hasSuffix("/identify") {
            Self.lock.lock()
            Self.identifies.append(url.path)
            Self.lock.unlock()
        }
        respond(200, #"{"data":{"accepted":1}}"#, url: url)
    }

    private func answer(_ reply: Reply, proposal: String?, url: URL) {
        switch reply {
        case .echo: respond(201, Self.registered(proposal ?? "dev_minted_by_server"), url: url)
        case .replace(let id): respond(201, Self.registered(id), url: url)
        case .status(let code): respond(code, "{}", url: url)
        case .lost: client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
        case .fail(let error): client?.urlProtocol(self, didFailWithError: error)
        }
    }

    private static func registered(_ id: String) -> String {
        #"{"data":{"device_id":"\#(id)","anonymous_id":"anon","flag_assignments":{},"experiment_assignments":{},"#
            + #""config":{"flush_interval_ms":5000,"flush_size":20}}}"#
    }

    private func respond(_ status: Int, _ body: String, url: URL, headers: [String: String] = [:]) {
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func body(of request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }
}
