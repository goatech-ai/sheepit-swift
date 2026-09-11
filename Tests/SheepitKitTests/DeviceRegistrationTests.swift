import XCTest
@testable import SheepitKit

/// Coverage for D-1: device registration never ran, so `/v1/config` could never resolve
/// the device (`device_assignments` is written ONLY by `POST /v1/devices/register`). The
/// bug was invisible in a diff of either function alone — `beginWork()` persists the
/// locally-minted device id one statement before calling `start()`, so `start()`'s old
/// guard (`storage.string(forKey: StorageKeys.deviceId) == nil`) was never true.
///
/// 🔴 Uses a dedicated, path-aware stub (`RegistrationStubURLProtocol`) rather than the
/// shared `StubURLProtocol` in `Support/TransportTestHarness.swift`. That one returns ONE
/// global canned response for every request regardless of path, which is fine for
/// Transport-level tests but useless here: `start()` fires `POST /v1/devices/register` and
/// `GET /v1/config` concurrently, and "register was called exactly once" is meaningless if
/// a config-sync request can inflate (or satisfy) the same counter.
final class DeviceRegistrationTests: XCTestCase {
    private let suiteName = "ai.goatech.sdk"

    /// `SheepitClient` hardcodes its `UserDefaults` suite (no storage-injection seam), so —
    /// same as `SessionStartEmissionTests` — isolation means clearing the specific keys this
    /// suite cares about around each test, not swapping in a fresh store.
    private func clearDeviceStorage() {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        defaults.removeObject(forKey: StorageKeys.deviceId)
        defaults.removeObject(forKey: StorageKeys.deviceRegistered)
        defaults.removeObject(forKey: StorageKeys.deviceRegistrationBackoffUntil)
        defaults.removeObject(forKey: StorageKeys.sessionId)
        defaults.removeObject(forKey: StorageKeys.sessionLastSeen)
        // A prior run of `testSuccessfulRegistrationAdoptsTheServerIdAndIdentifyAwaitsIt`
        // persists `userId: "user-1"` here. Left uncleared, `identify(userId: "user-1")`
        // hits its same-user no-op branch on the NEXT run and never spawns the Task this
        // suite is testing — a false pass that looks like a timeout instead.
        defaults.removeObject(forKey: StorageKeys.identity)
    }

    override func setUp() {
        super.setUp()
        clearDeviceStorage()
        RegistrationStubURLProtocol.reset()
    }

    override func tearDown() {
        clearDeviceStorage()
        RegistrationStubURLProtocol.reset()
        super.tearDown()
    }

    private func makeConfig(
        configRefreshInterval: TimeInterval = 300,
        retryAttempts: Int = 1
    ) -> SheepitConfig {
        SheepitConfig(
            apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))",
            apiUrl: "https://stub.invalid",
            configRefreshInterval: configRefreshInterval,
            retryAttempts: retryAttempts,
            crashes: CrashConfig(enabled: false)
        )
    }

    private func registerSuccessBody(deviceId: String) -> String {
        """
        {"data":{"device_id":"\(deviceId)","anonymous_id":"anon-1", \
        "flag_assignments":{},"experiment_assignments":{}, \
        "config":{"flush_interval_ms":1000,"flush_size":20}}}
        """
    }

    private let configSuccessBody = """
    {"data":{"config_version":"1","etag":"e1","flags":{},"experiments":{}}}
    """

    /// Bounded poll — the same shape `LifecycleSafetyTests` uses for async convergence.
    /// Device registration is a genuine network round trip (via `Task`), so there is no
    /// synchronous point to assert against.
    private func waitUntil(
        timeout: TimeInterval = 3.0,
        _ condition: @escaping () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    // MARK: - 1. Fresh storage registers

    func testFreshStorageRegistersExactlyOnceOnFirstLaunch() async {
        RegistrationStubURLProtocol.setResponder { method, path in
            if method == "POST", path == SDKEndpoints.deviceRegister {
                return .status(200, body: self.registerSuccessBody(deviceId: "dev_abc"))
            }
            return .status(200, body: self.configSuccessBody)
        }

        let client = SheepitClient.createForTesting(
            config: makeConfig(),
            now: { Date() },
            urlProtocolClasses: [RegistrationStubURLProtocol.self]
        )
        defer { client.destroy() }

        await waitUntil {
            RegistrationStubURLProtocol.requests(method: "POST", path: SDKEndpoints.deviceRegister).count >= 1
        }

        XCTAssertEqual(
            RegistrationStubURLProtocol.requests(method: "POST", path: SDKEndpoints.deviceRegister).count,
            1,
            "a device that has never had a successful registration must register exactly once on first launch"
        )
    }

    // MARK: - 2. Already-registered storage skips it

    func testAnAlreadyRegisteredDeviceDoesNotRegisterAgain() async {
        UserDefaults(suiteName: suiteName)?.set("1", forKey: StorageKeys.deviceRegistered)
        RegistrationStubURLProtocol.setResponder { _, _ in .status(200, body: self.configSuccessBody) }

        let client = SheepitClient.createForTesting(
            config: makeConfig(),
            now: { Date() },
            urlProtocolClasses: [RegistrationStubURLProtocol.self]
        )
        defer { client.destroy() }

        // Config sync always fires on start() — use it as the "the client has started"
        // signal, then assert register never fired alongside it.
        await waitUntil {
            RegistrationStubURLProtocol.requests(method: "GET", path: SDKEndpoints.config).count >= 1
        }

        XCTAssertEqual(
            RegistrationStubURLProtocol.requests(method: "POST", path: SDKEndpoints.deviceRegister).count,
            0,
            "a device with gt_device_registered already set must not register again"
        )
    }

    // MARK: - 2.1 A device already holding a server-assigned id — forward-looking

    /// `didMintDeviceId == false` also has to cover a device that already holds a
    /// SERVER-assigned `dev_…` id — should some later bug make it attempt registration a
    /// second time. No install is actually in this state today: `POST /v1/devices/register`
    /// has never fired in any published version (`ContextManager.init` has unconditionally
    /// persisted `gt_device_id` before `start()` ever ran since the SDK's first commit, so
    /// `start()`'s guard was never satisfiable — verified back to `swift-v0.3.0`). This test
    /// exists so that once registration succeeds for real and devices DO start holding
    /// `dev_…` ids, a re-attempt keeps sending the existing one rather than minting a new
    /// server-side device out from under it. This test fails against code that sends
    /// `existingDeviceId: nil` unconditionally: it asserts the request body carries the
    /// EXISTING device id, not merely that a request went out.
    func testADeviceAlreadyHoldingAServerAssignedIdSendsItRatherThanMintingAFreshOne() async {
        UserDefaults(suiteName: suiteName)?.set("dev_existing123", forKey: StorageKeys.deviceId)
        RegistrationStubURLProtocol.setResponder { method, path in
            if method == "POST", path == SDKEndpoints.deviceRegister {
                return .status(200, body: self.registerSuccessBody(deviceId: "dev_existing123"))
            }
            return .status(200, body: self.configSuccessBody)
        }

        let client = SheepitClient.createForTesting(
            config: makeConfig(),
            now: { Date() },
            urlProtocolClasses: [RegistrationStubURLProtocol.self]
        )
        defer { client.destroy() }

        await waitUntil {
            RegistrationStubURLProtocol.requests(method: "POST", path: SDKEndpoints.deviceRegister).count >= 1
        }

        let registerRequests = RegistrationStubURLProtocol.requests(
            method: "POST", path: SDKEndpoints.deviceRegister
        )
        XCTAssertEqual(registerRequests.count, 1, "the device must still register exactly once")

        guard
            let body = registerRequests.first?.body,
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else {
            XCTFail("register request must carry a JSON body")
            return
        }

        XCTAssertEqual(
            json["device_id"] as? String,
            "dev_existing123",
            "a device already holding a server-assigned id must re-register AGAINST it — " +
            "sending nil here mints a new server-side device out from under it"
        )
    }

    // MARK: - 2.2 Fresh install — no device id sent

    /// `DeviceRegisterRequest.deviceId` is `String?`; Swift's synthesized `Encodable` omits a
    /// nil optional via `encodeIfPresent` rather than encoding a JSON `null`. Assert the key
    /// is ABSENT, not merely nil-typed, since the two are observably different on the wire
    /// and the server branches on `providedDeviceId ?? mintNew()`
    /// (`apps/api/src/routes/v1/devices.ts:139`).
    func testFreshInstallSendsNoDeviceIdKey() async {
        // No `gt_device_id` seeded — `clearDeviceStorage()` in `setUp()` already guarantees this.
        RegistrationStubURLProtocol.setResponder { method, path in
            if method == "POST", path == SDKEndpoints.deviceRegister {
                return .status(200, body: self.registerSuccessBody(deviceId: "dev_fresh"))
            }
            return .status(200, body: self.configSuccessBody)
        }

        let client = SheepitClient.createForTesting(
            config: makeConfig(),
            now: { Date() },
            urlProtocolClasses: [RegistrationStubURLProtocol.self]
        )
        defer { client.destroy() }

        await waitUntil {
            RegistrationStubURLProtocol.requests(method: "POST", path: SDKEndpoints.deviceRegister).count >= 1
        }

        let registerRequests = RegistrationStubURLProtocol.requests(
            method: "POST", path: SDKEndpoints.deviceRegister
        )
        guard
            let body = registerRequests.first?.body,
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else {
            XCTFail("register request must carry a JSON body")
            return
        }

        XCTAssertNil(
            json["device_id"],
            "a fresh install must send no device_id key at all, so the server mints one — a " +
            "present (even null) key would defeat server-side id assignment"
        )
    }

    // MARK: - 2.3 A locally-minted id — the state EVERY real existing install is actually in

    /// `POST /v1/devices/register` has never fired in any published version — verified back
    /// to `swift-v0.3.0` and the SDK's first commit — so this, not the server-assigned-id
    /// case above, is the state every real existing install is actually in: a non-`dev_`-
    /// prefixed UUID persisted as `gt_device_id` (`ContextManager.init`'s fallback), with
    /// registration never having run against it. `didMintDeviceId` must treat this exactly
    /// like the server-assigned case — the id was RESTORED from storage this launch,
    /// regardless of what shape it is — so it round-trips to the server rather than being
    /// discarded and replaced. That preserves whatever event history this install already
    /// has, keyed to the identity it already carries.
    func testEveryRealExistingInstallSendsItsLocallyMintedIdRatherThanMintingAFreshOne() async {
        let localOnlyId = "5F1B3C2E-0000-0000-0000-000000000000"
        UserDefaults(suiteName: suiteName)?.set(localOnlyId, forKey: StorageKeys.deviceId)
        RegistrationStubURLProtocol.setResponder { method, path in
            if method == "POST", path == SDKEndpoints.deviceRegister {
                return .status(200, body: self.registerSuccessBody(deviceId: localOnlyId))
            }
            return .status(200, body: self.configSuccessBody)
        }

        let client = SheepitClient.createForTesting(
            config: makeConfig(),
            now: { Date() },
            urlProtocolClasses: [RegistrationStubURLProtocol.self]
        )
        defer { client.destroy() }

        await waitUntil {
            RegistrationStubURLProtocol.requests(method: "POST", path: SDKEndpoints.deviceRegister).count >= 1
        }

        let registerRequests = RegistrationStubURLProtocol.requests(
            method: "POST", path: SDKEndpoints.deviceRegister
        )
        guard
            let body = registerRequests.first?.body,
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else {
            XCTFail("register request must carry a JSON body")
            return
        }

        XCTAssertEqual(
            json["device_id"] as? String,
            localOnlyId,
            "a non-dev_-prefixed id restored from storage must still round-trip to the server " +
            "so its event history stays attached to the same identity"
        )
    }

    // MARK: - 3 & 5. Success adopts the server id, and identify() waits for it

    func testSuccessfulRegistrationAdoptsTheServerIdAndIdentifyAwaitsIt() async {
        let identifyPath = SDKEndpoints.deviceIdentify(deviceId: "dev_abc")
        RegistrationStubURLProtocol.setResponder { method, path in
            if method == "POST", path == SDKEndpoints.deviceRegister {
                return .status(200, body: self.registerSuccessBody(deviceId: "dev_abc"))
            }
            if method == "POST", path == identifyPath {
                return .status(200, body: """
                {"data":{"device_id":"dev_abc","user_id":"user-1","anonymous_id":"anon-1", \
                "flag_assignments":{}}}
                """)
            }
            return .status(200, body: self.configSuccessBody)
        }

        let client = SheepitClient.createForTesting(
            config: makeConfig(),
            now: { Date() },
            urlProtocolClasses: [RegistrationStubURLProtocol.self]
        )
        defer { client.destroy() }

        await waitUntil { client.context.deviceId == "dev_abc" }
        XCTAssertEqual(
            client.context.deviceId, "dev_abc",
            "a successful registration must adopt the server-assigned device id"
        )

        // identify() awaits registrationTask before deviceManager.identify() fires — if it
        // didn't, this request would go out under the OLD, locally-minted UUID, and the URL
        // below (keyed on the SERVER id) would never see it.
        client.identify(userId: "user-1")

        await waitUntil {
            RegistrationStubURLProtocol.requests(method: "POST", path: identifyPath).count >= 1
        }

        XCTAssertEqual(
            RegistrationStubURLProtocol.requests(method: "POST", path: identifyPath).count,
            1,
            "identify() must await the real registration task, so its own POST targets the " +
            "server-assigned device id the server actually knows about"
        )
    }

    // MARK: - 4. A failed registration retries on the next launch

    func testAFailedRegistrationLeavesTheFlagUnsetSoTheNextLaunchRetries() async {
        RegistrationStubURLProtocol.setResponder { method, path in
            if method == "POST", path == SDKEndpoints.deviceRegister {
                return .status(500, body: "{}")
            }
            return .status(200, body: self.configSuccessBody)
        }

        let first = SheepitClient.createForTesting(
            config: makeConfig(),
            now: { Date() },
            urlProtocolClasses: [RegistrationStubURLProtocol.self]
        )
        await waitUntil {
            RegistrationStubURLProtocol.requests(method: "POST", path: SDKEndpoints.deviceRegister).count >= 1
        }
        // Let the failed attempt's do/catch finish unwinding before asserting its absence.
        try? await Task.sleep(for: .milliseconds(50))
        first.destroy()

        XCTAssertNil(
            UserDefaults(suiteName: suiteName)?.string(forKey: StorageKeys.deviceRegistered),
            """
            The naive fix (guard on whether an id was minted) breaks exactly this case: the \
            locally-minted id is persisted regardless of whether the network round trip \
            succeeds, so a failed FIRST attempt must not be mistaken for a completed one.
            """
        )

        RegistrationStubURLProtocol.setResponder { method, path in
            if method == "POST", path == SDKEndpoints.deviceRegister {
                return .status(200, body: self.registerSuccessBody(deviceId: "dev_retry"))
            }
            return .status(200, body: self.configSuccessBody)
        }

        let second = SheepitClient.createForTesting(
            config: makeConfig(),
            now: { Date() },
            urlProtocolClasses: [RegistrationStubURLProtocol.self]
        )
        defer { second.destroy() }

        await waitUntil {
            RegistrationStubURLProtocol.requests(method: "POST", path: SDKEndpoints.deviceRegister).count >= 2
        }

        XCTAssertEqual(
            RegistrationStubURLProtocol.requests(method: "POST", path: SDKEndpoints.deviceRegister).count,
            2,
            "the second launch must retry registration since the first attempt never succeeded"
        )
        XCTAssertEqual(
            UserDefaults(suiteName: suiteName)?.string(forKey: StorageKeys.deviceRegistered),
            "1",
            "the second, successful attempt must set the flag"
        )
    }

    // MARK: - 6. Auto-flush ordering — the founder-ruled fix on top of D-1

    /// `start()` emits `$session_start` SYNCHRONOUSLY, before the detached registration
    /// `Task` it just created has any chance to run — so on a fresh install that event is
    /// always enqueued under the LOCAL, pre-registration id. Without `EventQueue
    /// .restampDeviceId` (called from the registration success path) and the auto-flush
    /// gate (`awaitDeviceIdSettlementForAutoFlush`), the periodic flush loop could — and
    /// without the gate, reliably WOULD, since it wakes up long before a stubbed round trip
    /// resolves at 5s default — send that event to `/v1/ingest` still carrying an id
    /// `device_assignments` never heard of, orphaning it forever. This asserts on the
    /// actual wire payload's `context.device.id`, not merely that a flush happened.
    func testAutoFlushWaitsForRegistrationSoTheWireBatchCarriesTheAdoptedId() async {
        RegistrationStubURLProtocol.setResponder { method, path in
            if method == "POST", path == SDKEndpoints.deviceRegister {
                // Deliberately slower than `flushInterval` below — see `Stub.delayed`'s doc
                // for why this is what makes the test able to fail against the pre-fix code.
                return .delayed(seconds: 0.15, then: .status(200, body: self.registerSuccessBody(deviceId: "dev_fresh")))
            }
            if method == "POST", path == SDKEndpoints.ingest {
                return .status(200, body: #"{"data":{"accepted":1}}"#)
            }
            return .status(200, body: self.configSuccessBody)
        }

        var config = makeConfig()
        // `flushSize: 1` makes `track("$session_start")` — which `start()` fires
        // SYNCHRONOUSLY, well before the 0.15s-delayed registration above resolves — trigger
        // its own auto-flush IMMEDIATELY, with no `Task.sleep` involved. A `flushInterval`-based
        // trigger would need to fight `TimeInterval.sanitizedForSleep()`'s 1-second floor,
        // which would mask this race behind >1s of accidental headroom.
        config.flushSize = 1

        let client = SheepitClient.createForTesting(
            config: config,
            now: { Date() },
            urlProtocolClasses: [RegistrationStubURLProtocol.self]
        )
        defer { client.destroy() }

        await waitUntil {
            RegistrationStubURLProtocol.requests(method: "POST", path: SDKEndpoints.ingest).count >= 1
        }

        guard
            let body = RegistrationStubURLProtocol.requests(method: "POST", path: SDKEndpoints.ingest)
                .first?.body,
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let context = json["context"] as? [String: Any],
            let device = context["device"] as? [String: Any]
        else {
            XCTFail("ingest request must carry a JSON body with context.device")
            return
        }

        XCTAssertEqual(
            device["id"] as? String,
            "dev_fresh",
            "an auto-flush must never send a batch still stamped with the pre-registration id"
        )
    }

    /// A permanently-queued flush would be worse than the bug this whole fix exists to
    /// close. `deviceManager.register()` returning `.transientFailure` (a 500 here) must
    /// still let `awaitDeviceIdSettlementForAutoFlush()` resolve — the gate waits for
    /// registration to SETTLE, not to succeed — so the auto-flush proceeds with whatever id
    /// the device still has (its own local one, since nothing was adopted).
    func testATransientRegistrationFailureStillUnblocksTheAutoFlush() async {
        RegistrationStubURLProtocol.setResponder { method, path in
            if method == "POST", path == SDKEndpoints.deviceRegister {
                return .delayed(seconds: 0.15, then: .status(500, body: "{}"))
            }
            if method == "POST", path == SDKEndpoints.ingest {
                return .status(200, body: #"{"data":{"accepted":1}}"#)
            }
            return .status(200, body: self.configSuccessBody)
        }

        var config = makeConfig(retryAttempts: 1)
        config.flushSize = 1 // see the sibling test's comment for why size, not interval

        let client = SheepitClient.createForTesting(
            config: config,
            now: { Date() },
            urlProtocolClasses: [RegistrationStubURLProtocol.self]
        )
        defer { client.destroy() }

        await waitUntil {
            RegistrationStubURLProtocol.requests(method: "POST", path: SDKEndpoints.ingest).count >= 1
        }

        XCTAssertEqual(
            RegistrationStubURLProtocol.requests(method: "POST", path: SDKEndpoints.ingest).count,
            1,
            "a failed registration must not permanently block the auto-flush queue"
        )
    }

    /// The gate must be a true no-op once a device is already registered — `start()` never
    /// even creates a `registrationTask` in that case, so nothing should delay this launch's
    /// first auto-flush at all. Uses a tight timeout (well under the suite's usual 3s) as a
    /// coarse proxy for "not deferred."
    func testAnAlreadyRegisteredDevicesAutoFlushIsNeverDeferred() async {
        UserDefaults(suiteName: suiteName)?.set("dev_existing", forKey: StorageKeys.deviceId)
        UserDefaults(suiteName: suiteName)?.set("1", forKey: StorageKeys.deviceRegistered)
        RegistrationStubURLProtocol.setResponder { method, path in
            if method == "POST", path == SDKEndpoints.ingest {
                return .status(200, body: #"{"data":{"accepted":1}}"#)
            }
            return .status(200, body: self.configSuccessBody)
        }

        var config = makeConfig()
        // No `gt_session_id` was seeded, so `start()` also auto-emits `$session_start` — that's
        // event #1. `flushSize: 2` makes the tracked event below (#2) the one that crosses the
        // threshold, so both land in exactly ONE size-triggered auto-flush rather than each
        // tracked event separately triggering its own (which `flushSize: 1` would do, and isn't
        // what this test is about).
        config.flushSize = 2

        let client = SheepitClient.createForTesting(
            config: config,
            now: { Date() },
            urlProtocolClasses: [RegistrationStubURLProtocol.self]
        )
        defer { client.destroy() }

        client.track("host_event")

        await waitUntil(timeout: 1.0) {
            RegistrationStubURLProtocol.requests(method: "POST", path: SDKEndpoints.ingest).count >= 1
        }

        XCTAssertEqual(
            RegistrationStubURLProtocol.requests(method: "POST", path: SDKEndpoints.ingest).count,
            1,
            "an already-registered device's auto-flush must not wait on anything"
        )
        XCTAssertEqual(
            RegistrationStubURLProtocol.requests(method: "POST", path: SDKEndpoints.deviceRegister).count,
            0
        )
    }

    // MARK: - 7. Terminal registration failures (401/403/422)

    /// A revoked key must stop being retried on every cold start, but the founder's ruling
    /// was explicit that it must not be silently confused with success either — so this
    /// asserts on BOTH halves: `deviceRegistered` stays unset (a fixed key must eventually
    /// be retried), and the backoff window plus a diagnostic (with a distinct `outcome`
    /// value, matching this repo's bug-fix observability convention) are recorded so the
    /// failure is actually visible somewhere.
    func testTerminalFailureBacksOffWithoutClaimingSuccessAndEmitsADiagnostic() async {
        RegistrationStubURLProtocol.setResponder { method, path in
            if method == "POST", path == SDKEndpoints.deviceRegister {
                return .status(401, body: "{}")
            }
            return .status(200, body: self.configSuccessBody)
        }

        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let client = SheepitClient.createForTesting(
            config: makeConfig(),
            now: { fixedNow },
            urlProtocolClasses: [RegistrationStubURLProtocol.self]
        )
        defer { client.destroy() }

        await waitUntil {
            RegistrationStubURLProtocol.requests(method: "POST", path: SDKEndpoints.deviceRegister).count >= 1
        }
        // Let the terminal-failure branch finish writing storage/diagnostics before asserting.
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertNil(
            UserDefaults(suiteName: suiteName)?.string(forKey: StorageKeys.deviceRegistered),
            "a terminal failure must never be recorded as a success"
        )

        guard
            let raw = UserDefaults(suiteName: suiteName)?.string(
                forKey: StorageKeys.deviceRegistrationBackoffUntil
            ),
            let until = TimeInterval(raw)
        else {
            XCTFail("a terminal failure must record a backoff window")
            return
        }
        XCTAssertGreaterThan(until, fixedNow.timeIntervalSince1970, "the window must be in the future")

        let diagnostic = client.getRecentDiagnostics().first {
            $0.code == "identity.device_registration_terminal_failure"
        }
        XCTAssertEqual(
            diagnostic?.data?["outcome"]?.value as? String,
            "revoked_key",
            "a 401 must be classified with its own distinct outcome value, not a generic one"
        )
    }

    /// The whole point of the backoff: a second cold start within the window must not hit
    /// the network again.
    func testTerminalFailureDoesNotRetryWithinTheBackoffWindow() async {
        RegistrationStubURLProtocol.setResponder { method, path in
            if method == "POST", path == SDKEndpoints.deviceRegister {
                return .status(401, body: "{}")
            }
            return .status(200, body: self.configSuccessBody)
        }

        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let first = SheepitClient.createForTesting(
            config: makeConfig(),
            now: { fixedNow },
            urlProtocolClasses: [RegistrationStubURLProtocol.self]
        )
        await waitUntil {
            RegistrationStubURLProtocol.requests(method: "POST", path: SDKEndpoints.deviceRegister).count >= 1
        }
        try? await Task.sleep(for: .milliseconds(50))
        first.destroy()

        let second = SheepitClient.createForTesting(
            config: makeConfig(),
            now: { fixedNow.addingTimeInterval(60) }, // one minute later — still inside the 24h window
            urlProtocolClasses: [RegistrationStubURLProtocol.self]
        )
        defer { second.destroy() }
        // Nothing to poll FOR (the assertion is an absence) — give any wrongly-fired retry
        // time to land before checking the count stayed put.
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(
            RegistrationStubURLProtocol.requests(method: "POST", path: SDKEndpoints.deviceRegister).count,
            1,
            "a second launch inside the backoff window must not retry a terminally-rejected key"
        )
    }

    /// ...and once the window elapses, a fixed key (or freed-up capacity) IS picked up again
    /// — the whole reason `deviceRegistered` was deliberately left unset.
    func testTerminalFailureRetriesAfterTheBackoffWindowElapses() async {
        RegistrationStubURLProtocol.setResponder { method, path in
            if method == "POST", path == SDKEndpoints.deviceRegister {
                return .status(401, body: "{}")
            }
            return .status(200, body: self.configSuccessBody)
        }

        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let first = SheepitClient.createForTesting(
            config: makeConfig(),
            now: { fixedNow },
            urlProtocolClasses: [RegistrationStubURLProtocol.self]
        )
        await waitUntil {
            RegistrationStubURLProtocol.requests(method: "POST", path: SDKEndpoints.deviceRegister).count >= 1
        }
        // Wait for the 401 to be PROCESSED and its backoff marker persisted — not merely
        // for the POST to have been sent. The `waitUntil` above only proves the request
        // left; the response still has to come back and be written. A fixed 50ms sleep
        // raced that write and failed ~20% of runs.
        await waitUntil {
            UserDefaults(suiteName: self.suiteName)?
                .string(forKey: StorageKeys.deviceRegistrationBackoffUntil) != nil
        }
        first.destroy()

        RegistrationStubURLProtocol.setResponder { method, path in
            if method == "POST", path == SDKEndpoints.deviceRegister {
                return .status(200, body: self.registerSuccessBody(deviceId: "dev_fixed_key"))
            }
            return .status(200, body: self.configSuccessBody)
        }

        let second = SheepitClient.createForTesting(
            config: makeConfig(),
            now: { fixedNow.addingTimeInterval(SDKDefaults.deviceRegistrationTerminalBackoff + 1) },
            urlProtocolClasses: [RegistrationStubURLProtocol.self]
        )
        defer { second.destroy() }

        // Poll the END STATE the assertions below actually check — the persisted success
        // flag — rather than the request count. The count reaches 2 the instant the POST
        // is sent, while `gt_device_registered` is written only once the 200 comes back
        // and is processed, so asserting on it right after a count-based wait is a race.
        await waitUntil {
            UserDefaults(suiteName: self.suiteName)?
                .string(forKey: StorageKeys.deviceRegistered) == "1"
        }

        XCTAssertEqual(
            RegistrationStubURLProtocol.requests(method: "POST", path: SDKEndpoints.deviceRegister).count,
            2,
            "a launch after the backoff window elapses must retry"
        )
        XCTAssertEqual(
            UserDefaults(suiteName: suiteName)?.string(forKey: StorageKeys.deviceRegistered),
            "1",
            "a retry that now succeeds must be recorded as such"
        )
    }

    // MARK: - 8. Regression: restamp-before-adopt ordering in `case .success(let deviceId):`

    /// Pins the ordering `SheepitClient` deliberately picks on the registration success path:
    /// `queue.restampDeviceId(from:to:)` THEN `context.setDeviceId(deviceId)`. They take two
    /// DIFFERENT locks (`EventQueue`'s, `ContextManager`'s), so nothing at the type level
    /// enforces the order — only this test does.
    ///
    /// Why the order matters: `IngestEvent` (`Types/GeneratedTypes.swift`) carries no device
    /// id at all — the wire id is `first.deviceId`, the HEAD of each session group
    /// (`Transport.buildPayload`), groups cut by session alone. `flush()` is public and
    /// deliberately ungated (never awaits registration settlement — see
    /// `awaitDeviceIdSettlementForAutoFlush`, which only the AUTO-flush path goes through), so
    /// a flush landing between the two statements is reachable in production, not just here.
    ///
    /// The seam: `ContextManager.setDeviceId` writes `StorageKeys.deviceId` to `UserDefaults`
    /// WHILE HOLDING its own non-recursive lock, and `UserDefaults` KVO fires INLINE — on the
    /// calling thread, before `set(_:forKey:)` returns — verified empirically before writing
    /// this test (a throwaway `swift` script; also holds across two separately-created
    /// `UserDefaults(suiteName:)` instances for the same suite, matching production: the SDK's
    /// `UserDefaultsStorage` owns one instance, this test another). So a KVO observer on that
    /// key fires exactly inside the window the two statements open — after `restampDeviceId`
    /// in the current order, before it in a reversed one.
    ///
    /// Deadlock hazard: anything the observer calls that re-enters `ContextManager` (`track()`,
    /// `eventContext()`) deadlocks against that same non-recursive lock. The observer itself
    /// does nothing but signal a semaphore; a dedicated `Thread` — NOT a Swift Task, so it
    /// costs nothing from the cooperative thread pool while parked — is what actually spawns
    /// `Task { await client.flush() }` (`Transport` holds no reference to `ContextManager`, so
    /// that path is safe). The observer then blocks the ORIGINAL calling thread — the one
    /// running `case .success` — on a second, bounded-timeout semaphore until that flush has
    /// fully landed. That block is what makes the test deterministic rather than a coin flip:
    /// without it, the synchronous statement immediately following the KVO-triggering one
    /// (`restampDeviceId`, in a hypothetically reversed order) would almost always complete
    /// microseconds before a real network round trip could, even a stubbed one — silently
    /// passing either order and defeating the whole point of this test. Every wait below is
    /// bounded so a broken seam fails the assertion rather than hanging the suite.
    func testRestampBeforeAdoptOrderingMeansAFlushDuringRegistrationShipsTheNewId() async {
        // Deliberately slower than an ordinary local-stub response — see `Stub.delayed`'s
        // doc, and `testAutoFlushWaitsForRegistrationSoTheWireBatchCarriesTheAdoptedId`
        // above, which uses the same technique for the same reason. Measured with temporary
        // instrumentation (removed) before adding this: with an INSTANT register response,
        // `context.setDeviceId("dev_race")` can land as little as ~1-2ms after this client is
        // constructed — sometimes faster than `UserDefaults.addObserver(_:forKeyPath:...)`
        // below has finished its own internal bookkeeping, so the KVO notification for that
        // specific write is silently never delivered even though the value demonstrably
        // changed (confirmed by a parallel polling task that DID see it). That is a real,
        // reproducible race in observer SETUP, not in this test's synchronization logic —
        // the fix is to guarantee the observer is fully attached well before the write can
        // possibly happen, the same reason the sibling test above delays its own register
        // response.
        RegistrationStubURLProtocol.setResponder { method, path in
            if method == "POST", path == SDKEndpoints.deviceRegister {
                return .delayed(
                    seconds: 0.2,
                    then: .status(200, body: self.registerSuccessBody(deviceId: "dev_race"))
                )
            }
            if method == "POST", path == SDKEndpoints.ingest {
                return .status(200, body: #"{"data":{"accepted":1}}"#)
            }
            return .status(200, body: self.configSuccessBody)
        }

        // `flushInterval` defaults to `SDKDefaults.flushInterval` — exactly 5.0s. Left at
        // that default, the SDK's OWN periodic flush loop wakes up around the same mark as
        // this test's bounded waits and sends whatever the queue holds BY THEN — which, by
        // definition, is always AFTER `case .success` has long since finished both
        // statements, in whatever order the source has them. That masked a real failure of
        // this test's OWN KVO-triggered flush to engage in time: the assertion still saw
        // "dev_race" and passed, but via the periodic loop's settled-state flush, not the
        // mid-registration race this test exists to pin. Pushed far outside the test's own
        // bounded waits so the ONLY possible source of an ingest request is this test's own
        // deliberate, precisely-timed flush.
        var config = makeConfig()
        config.flushInterval = 3600
        let client = SheepitClient.createForTesting(
            config: config,
            now: { Date() },
            urlProtocolClasses: [RegistrationStubURLProtocol.self]
        )
        defer { client.destroy() }

        // Settled synchronously inside `createForTesting()` -> `beginWork()` ->
        // `context.persistOnBeginWork()`, before this line runs. This is the exact id
        // `$session_start` (enqueued synchronously in `start()`) was stamped with.
        guard
            let preRegistrationDeviceId = UserDefaults(suiteName: suiteName)?
                .string(forKey: StorageKeys.deviceId)
        else {
            XCTFail("client must have persisted a device id by the time createForTesting() returns")
            return
        }

        // observer -> dedicated thread: "KVO fired, go start the flush".
        let kvoFired = DispatchSemaphore(value: 0)
        // dedicated thread -> observer: "the flush landed, you may proceed".
        let flushLanded = DispatchSemaphore(value: 0)

        // Bounds are generous, not tight. Measured repeatedly: isolated (`swift test
        // --filter`) and as part of the class/full suite alike, this whole KVO-to-flush round
        // trip normally completes in well under 0.5s (the register delay above plus the
        // flush's own network round trip). Every bound below is a last-resort backstop
        // against a genuinely broken seam, not the thing making the test correct —
        // correctness comes from the KVO write itself being synchronous, not from timing. A
        // hang here must fail loudly rather than block the suite.
        //
        // Filtered to the exact NEW value this client's registration will adopt —
        // `StorageKeys.deviceId` is one shared `UserDefaults` key written by EVERY
        // `SheepitClient` in the process (`UserDefaultsStorage`'s suite name is hardcoded,
        // not injected — see this file's own top-of-class doc). Any other test's lingering,
        // not-yet-fully-torn-down client writing that SAME key during this test's window
        // fires this observer too. An unfiltered observer treated that stray write as ITS
        // OWN signal — consuming the one-shot `flushThread` below at a moment unrelated to
        // this client's `case .success` block, which let the reversed-order (buggy) source
        // pass by pure timing luck instead of failing. Matching on `.new == "dev_race"`
        // — a literal unique to this test — makes the gate fire only for this client's own
        // adopt-write, never a stray one from elsewhere in the same suite.
        let observer = DeviceIdKVOObserver(matching: "dev_race") {
            kvoFired.signal()
            _ = flushLanded.wait(timeout: .now() + 15.0)
        }
        let observerDefaults = UserDefaults(suiteName: suiteName)!
        observerDefaults.addObserver(observer, forKeyPath: StorageKeys.deviceId, options: [.new], context: nil)
        defer { observerDefaults.removeObserver(observer, forKeyPath: StorageKeys.deviceId) }

        let flushThread = Thread {
            guard kvoFired.wait(timeout: .now() + 10.0) == .success else { return }
            let flushDone = DispatchSemaphore(value: 0)
            Task(priority: .userInitiated) {
                await client.flush()
                flushDone.signal()
            }
            _ = flushDone.wait(timeout: .now() + 10.0)
            flushLanded.signal()
        }
        flushThread.start()

        // Filtered, not `.first` — a PRIOR test's `client.destroy()` fires its own
        // fire-and-forget teardown flush (`performTeardown()`'s `Task { await flush() }`)
        // that is not awaited before the test method returns, so that straggler can still be
        // in flight when THIS test starts, and can land its OWN device id (e.g. another
        // test's "dev_abc") in `RegistrationStubURLProtocol`'s shared recorder before this
        // test's own request does — `.first` picked up exactly that contamination once,
        // non-deterministically, in a real run. This client's own flush can only ever carry
        // one of two values — the pre-registration id (bug) or "dev_race" (correct) — so
        // filtering to those two is immune to any other test's traffic regardless of arrival
        // order.
        func ownIngestDeviceId() -> String? {
            for request in RegistrationStubURLProtocol.requests(method: "POST", path: SDKEndpoints.ingest) {
                guard
                    let body = request.body,
                    let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
                    let context = json["context"] as? [String: Any],
                    let device = context["device"] as? [String: Any],
                    let id = device["id"] as? String,
                    id == "dev_race" || id == preRegistrationDeviceId
                else { continue }
                return id
            }
            return nil
        }

        await waitUntil(timeout: 15.0) { ownIngestDeviceId() != nil }

        guard let shippedDeviceId = ownIngestDeviceId() else {
            XCTFail(
                "the KVO-triggered flush during registration never reached /v1/ingest with " +
                "either candidate device id — either the KVO seam did not fire, or the flush " +
                "never landed within its bounded wait"
            )
            return
        }

        XCTAssertNotEqual(
            preRegistrationDeviceId, "dev_race",
            "test setup invariant: the stub's server-assigned id must differ from the " +
            "locally-minted one, or this test can't distinguish old-id from new-id"
        )
        XCTAssertEqual(
            shippedDeviceId,
            "dev_race",
            "a flush landing between restampDeviceId and setDeviceId must still ship the NEW " +
            "server-assigned id — restampDeviceId runs FIRST, so every queued head is already " +
            "re-stamped by the time setDeviceId's KVO write fires. A failure here means the " +
            "two statements in SheepitClient's `case .success(let deviceId):` were reordered."
        )
    }
}

/// Signals a caller-supplied closure synchronously from `UserDefaults`'s KVO callback. Kept
/// to a single responsibility (fire a closure, nothing else) so the deadlock-hazard doc on
/// its one call site stays accurate — see
/// `testRestampBeforeAdoptOrderingMeansAFlushDuringRegistrationShipsTheNewId`.
private final class DeviceIdKVOObserver: NSObject {
    private let expectedNewValue: String
    private let onChange: () -> Void

    /// - Parameter matching: only writes whose NEW value equals this fire `onChange`. See
    ///   the call site's doc — `StorageKeys.deviceId` is a single shared key across every
    ///   `SheepitClient` alive in the test process, so an unfiltered observer would also
    ///   fire for a write that has nothing to do with the client under test.
    init(matching expectedNewValue: String, onChange: @escaping () -> Void) {
        self.expectedNewValue = expectedNewValue
        self.onChange = onChange
    }

    override func observeValue(
        forKeyPath keyPath: String?,
        of object: Any?,
        change: [NSKeyValueChangeKey: Any]?,
        context: UnsafeMutableRawPointer?
    ) {
        guard change?[.newKey] as? String == expectedNewValue else { return }
        onChange()
    }
}

/// Path-aware network stub. Every request landing on `stub.invalid` is recorded (method +
/// path + headers) and answered via an installable responder closure, so a test can tell
/// `POST /v1/devices/register` apart from the `GET /v1/config` request `ConfigSync` fires
/// concurrently — the shared `StubURLProtocol` (one global response for every path) can't
/// express that. Registered per-client via `SheepitClient.createForTesting`'s
/// `urlProtocolClasses` seam, mirroring the same parameter on `HTTPClient` directly.
final class RegistrationStubURLProtocol: URLProtocol, @unchecked Sendable {
    struct RecordedRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data?
    }

    enum Stub {
        case status(Int, body: String)
        /// Answers after `seconds` on a background `Task` rather than synchronously inside
        /// `startLoading()`. Needed to make the auto-flush-ordering tests deterministic: a
        /// same-thread synchronous stub resolves "registration" faster than any
        /// `flushInterval` a test could set without slowing the whole suite down, so
        /// removing the gate under test never actually reproduced the race it exists to
        /// close. A real network round trip is exactly this shape — slower than the local
        /// stub-out below it — so this isn't an artificial scenario, just a compressed one.
        indirect case delayed(seconds: TimeInterval, then: Stub)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var responder: (@Sendable (String, String) -> Stub)?
    nonisolated(unsafe) private static var recorded: [RecordedRequest] = []

    static func setResponder(_ responder: @escaping @Sendable (_ method: String, _ path: String) -> Stub) {
        lock.lock(); self.responder = responder; lock.unlock()
    }

    static func requests(method: String, path: String) -> [RecordedRequest] {
        lock.lock(); defer { lock.unlock() }
        return recorded.filter { $0.method == method && $0.path == path }
    }

    static func reset() {
        lock.lock()
        responder = nil
        recorded = []
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "stub.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// `URLSession` sometimes hands `URLProtocol` the body as `httpBodyStream` rather than
    /// `httpBody`, even though `HTTPClient` set `request.httpBody` directly — read both so a
    /// test asserting on the serialized body doesn't flake depending on which one shows up.
    private static func bodyData(for request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return data
    }

    override func startLoading() {
        guard let url = request.url, let method = request.httpMethod else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }

        Self.lock.lock()
        Self.recorded.append(
            RecordedRequest(
                method: method,
                path: url.path,
                headers: request.allHTTPHeaderFields ?? [:],
                body: Self.bodyData(for: request)
            )
        )
        let stub = Self.responder?(method, url.path) ?? .status(200, body: #"{"data":{}}"#)
        Self.lock.unlock()

        deliver(stub, url: url)
    }

    private func deliver(_ stub: Stub, url: URL) {
        switch stub {
        case .status(let code, let body):
            guard let response = HTTPURLResponse(
                url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: [:]
            ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        case .delayed(let seconds, let next):
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                self?.deliver(next, url: url)
            }
        }
    }

    override func stopLoading() {}
}
