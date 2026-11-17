import XCTest
@testable import SheepitKit

/// The C5 trigger in `ConfigSync.handleUnresolved` (contract § 7): it fires only for an
/// `unknown_device` answer for the device the resolved record names, that started after the body
/// applied and under the reset token the record was made under. A stale answer, or one from before a
/// `reset()`, must not replace a device the server still knows.
final class ConfigErasedDeviceTriggerTests: XCTestCase {
    private static let resolvedBody = #"{"data":{"config_version":"7","etag":"\"v7\"","flags":{"native_home":true},"experiments":{}}}"#
    private static let defaultsBody = #"{"data":{"config_version":"7","etag":"\"u7\"","flags":{"native_home":false},"experiments":{}}}"#

    override func setUp() {
        super.setUp()
        AttributionCaptureProtocol.reset()
    }

    override func tearDown() {
        AttributionCaptureProtocol.reset()
        super.tearDown()
    }

    /// `mint`: the hook stands in for a rotation whose C5 registration was answered (spends the cap).
    /// `joined`: it joined a replacement already registering (mints nothing for C5).
    private func makeSync(
        gate: ConfigResetGate = ConfigResetGate(), bus: DiagnosticBus, hits: LockedBox<[String]>,
        mint: Bool = true, joined: Bool = false, provisional: LockedBox<[SDKConfigResponse]> = LockedBox([])
    ) -> ConfigSync {
        let sync = ConfigSync(
            http: HTTPClient(
                config: SheepitConfig(apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64),
                                      apiUrl: "https://stub.invalid", retryAttempts: 1),
                log: Logger(debug: false), urlProtocolClasses: [AttributionCaptureProtocol.self]),
            storage: InMemoryStorage(), refreshInterval: 3600, log: Logger(debug: false), resetGate: gate,
            diagnostics: bus, identityProvider: { (.fetchedUnder(nil), 0) },
            onConfig: { _, _, _ in }, onProvisional: { body in provisional.mutate { $0.append(body) } })
        // Stands in for a rotation still on the device: a nil outcome is a capped trigger.
        sync.onResolvedDeviceUnknown.value = { id, outcome in
            guard let outcome else { return .capped }
            hits.mutate { $0.append(id) }
            if mint, !joined { outcome.minted() }
            return joined ? .joined : .replacing
        }
        return sync
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// Answers each request in order with `resolutions`; the last one repeats.
    private static func resolve(_ resolutions: [String]) {
        let calls = LockedBox(0)
        AttributionCaptureProtocol.configResolution = { _, _ in
            var n = 0
            calls.mutate { $0 += 1; n = $0 }
            return resolutions[min(n, resolutions.count) - 1]
        }
    }

    func testResolvedThenUnknownFiresOnceForThatDevice() async {
        let bus = DiagnosticBus()
        let hits = LockedBox<[String]>([])
        let sync = makeSync(bus: bus, hits: hits)
        AttributionCaptureProtocol.serveConfig(Self.resolvedBody)
        AttributionCaptureProtocol.honorIfNoneMatch = false
        Self.resolve(["resolved", "unknown_device"])

        await sync.refresh(deviceId: "device-1")
        await sync.refresh(deviceId: "device-1")
        await sync.refresh(deviceId: "device-1")

        XCTAssertEqual(hits.get(), ["device-1"], "fired more than once, or not at all")
        XCTAssertEqual(bus.getRecentDiagnostics().filter { $0.code == "config.device_replaced_unknown" }.count, 1)
    }

    /// A `lookup_error` is a server failure: it leaves the record, so the erasure that follows it
    /// still fires.
    func testALookupErrorBeforeTheErasureLeavesTheRecordArmed() async {
        let bus = DiagnosticBus()
        let hits = LockedBox<[String]>([])
        let sync = makeSync(bus: bus, hits: hits)
        AttributionCaptureProtocol.serveConfig(Self.resolvedBody)
        AttributionCaptureProtocol.honorIfNoneMatch = false
        Self.resolve(["resolved", "lookup_error", "unknown_device"])

        await sync.refresh(deviceId: "device-1")
        await sync.refresh(deviceId: "device-1")
        await sync.refresh(deviceId: "device-1")

        XCTAssertEqual(hits.get(), ["device-1"], "a lookup_error disarmed the replacement")
    }

    /// An unknown resolution value says nothing about the row: it neither fires nor clears, so the
    /// `unknown_device` that follows still fires.
    func testAnUnknownResolutionValueNeitherFiresNorDisarms() async {
        let bus = DiagnosticBus()
        let hits = LockedBox<[String]>([])
        let sync = makeSync(bus: bus, hits: hits)
        AttributionCaptureProtocol.serveConfig(Self.resolvedBody)
        AttributionCaptureProtocol.honorIfNoneMatch = false
        Self.resolve(["resolved", "row_archived"])
        await sync.refresh(deviceId: "device-1")
        await sync.refresh(deviceId: "device-1")
        XCTAssertEqual(hits.get(), [], "an unknown value replaced the device")

        Self.resolve(["unknown_device"])
        await sync.refresh(deviceId: "device-1")

        XCTAssertEqual(hits.get(), ["device-1"], "an unknown value disarmed the replacement")
    }

    /// An answer that started before the resolved body applied: it describes an older moment.
    func testAnOlderUnknownDeviceAnswerLandingAfterAResolvedOneDoesNotFire() async {
        let bus = DiagnosticBus()
        let hits = LockedBox<[String]>([])
        let sync = makeSync(bus: bus, hits: hits)
        AttributionCaptureProtocol.scriptConfig([(Self.defaultsBody, 0.4), (Self.resolvedBody, 0)])
        Self.resolve(["unknown_device", "resolved"])

        let stale = Task { await sync.refresh(deviceId: "device-1") }
        let started = await waitUntil { AttributionCaptureProtocol.configRequestCount == 1 }
        XCTAssertTrue(started, "precondition: the older fetch is on the wire")
        await sync.refresh(deviceId: "device-1")
        await stale.value

        XCTAssertTrue(bus.getRecentDiagnostics().contains { $0.code == "config.unresolved_body_refused" },
                      "precondition: the older answer landed")
        XCTAssertEqual(hits.get(), [], "a stale unknown_device replaced a device the server resolves")
    }

    /// An answer to a request issued before a `reset()`: the reset moved the token it was issued
    /// under, so it says nothing about the device now.
    func testAnUnknownDeviceAnswerIssuedBeforeAResetDoesNotFire() async {
        let gate = ConfigResetGate()
        let bus = DiagnosticBus()
        let hits = LockedBox<[String]>([])
        let sync = makeSync(gate: gate, bus: bus, hits: hits)
        AttributionCaptureProtocol.scriptConfig([(Self.resolvedBody, 0), (Self.defaultsBody, 0.4)])
        Self.resolve(["resolved", "unknown_device"])
        await sync.refresh(deviceId: "device-1")

        let inFlight = Task { await sync.refresh(deviceId: "device-1") }
        let started = await waitUntil { AttributionCaptureProtocol.configRequestCount == 2 }
        XCTAssertTrue(started, "precondition: the fetch is on the wire")
        gate.reset {}
        await inFlight.value

        XCTAssertTrue(bus.getRecentDiagnostics().contains { $0.code == "config.unresolved_body_refused" },
                      "precondition: the answer landed")
        XCTAssertEqual(hits.get(), [], "an answer from before reset() replaced the device")
    }

    private static func reasons(_ bus: DiagnosticBus) -> [String] {
        bus.getRecentDiagnostics().filter { $0.code == "config.device_replaced_unknown" }
            .compactMap { $0.data?["reason"]?.value as? String }
    }

    /// SK-Q16: the per-launch cap is per reset generation. A logout's `reset()` releases it, so a
    /// replacement before the logout does not leave the device the logout ends on unprotected.
    func testAResetReleasesTheCapForTheDeviceTheLogoutEndsOn() async {
        let gate = ConfigResetGate()
        let bus = DiagnosticBus()
        let hits = LockedBox<[String]>([])
        let sync = makeSync(gate: gate, bus: bus, hits: hits)
        AttributionCaptureProtocol.serveConfig(Self.resolvedBody)
        AttributionCaptureProtocol.honorIfNoneMatch = false
        Self.resolve(["resolved", "unknown_device"])
        await sync.refresh(deviceId: "device-1")
        await sync.refresh(deviceId: "device-1")
        XCTAssertEqual(hits.get(), ["device-1"], "precondition: the first erasure replaced")

        gate.reset {}
        Self.resolve(["resolved", "unknown_device"])
        await sync.refresh(deviceId: "device-2")
        await sync.refresh(deviceId: "device-2")

        XCTAssertEqual(hits.get(), ["device-1", "device-2"], "a replacement before reset() capped the device after it")
        XCTAssertEqual(Self.reasons(bus), ["resolved_then_unknown", "resolved_then_unknown"])
    }

    /// Without a reset the cap holds: the second erasure in the same generation only reports.
    func testWithoutAResetTheSecondErasureIsCapped() async {
        let bus = DiagnosticBus()
        let hits = LockedBox<[String]>([])
        let sync = makeSync(bus: bus, hits: hits)
        AttributionCaptureProtocol.serveConfig(Self.resolvedBody)
        AttributionCaptureProtocol.honorIfNoneMatch = false
        Self.resolve(["resolved", "unknown_device"])
        await sync.refresh(deviceId: "device-1")
        await sync.refresh(deviceId: "device-1")
        Self.resolve(["resolved", "unknown_device"])
        await sync.refresh(deviceId: "device-2")
        await sync.refresh(deviceId: "device-2")

        XCTAssertEqual(hits.get(), ["device-1"])
        XCTAssertEqual(Self.reasons(bus), ["resolved_then_unknown", "capped"])
    }

    /// A trigger that joins a replacement already registering (an identify 404's) reports `joined`,
    /// and leaves the cap unspent: the mint was the identify's, not C5's.
    func testAJoinedTriggerReportsJoinedAndLeavesTheCapUnspent() async {
        let bus = DiagnosticBus()
        let hits = LockedBox<[String]>([])
        let sync = makeSync(bus: bus, hits: hits, joined: true)
        AttributionCaptureProtocol.serveConfig(Self.resolvedBody)
        AttributionCaptureProtocol.honorIfNoneMatch = false
        Self.resolve(["resolved", "unknown_device"])
        await sync.refresh(deviceId: "device-1")
        await sync.refresh(deviceId: "device-1")
        Self.resolve(["resolved", "unknown_device"])
        await sync.refresh(deviceId: "device-2")
        await sync.refresh(deviceId: "device-2")

        XCTAssertEqual(hits.get(), ["device-1", "device-2"], "a joined replacement spent the cap")
        XCTAssertEqual(Self.reasons(bus), ["joined", "joined"])
    }

    /// A trigger whose replacement minted nothing (an adoption: the client already moved; or a
    /// failed or deferred registration) leaves the cap unspent.
    func testATriggerThatMintsNothingLeavesTheCapUnspent() async {
        let bus = DiagnosticBus()
        let hits = LockedBox<[String]>([])
        let sync = makeSync(bus: bus, hits: hits, mint: false)
        AttributionCaptureProtocol.serveConfig(Self.resolvedBody)
        AttributionCaptureProtocol.honorIfNoneMatch = false
        Self.resolve(["resolved", "unknown_device"])
        await sync.refresh(deviceId: "device-1")
        await sync.refresh(deviceId: "device-1")
        Self.resolve(["resolved", "unknown_device"])
        await sync.refresh(deviceId: "device-2")
        await sync.refresh(deviceId: "device-2")

        XCTAssertEqual(hits.get(), ["device-1", "device-2"], "a trigger that minted nothing spent the cap")
        XCTAssertEqual(Self.reasons(bus), ["resolved_then_unknown", "resolved_then_unknown"])
    }

    /// A capped trigger keeps the erased id but drops its values: the server's defaults (kill
    /// switches included) apply in memory, and the next unresolved answer is not refused either.
    func testACappedTriggerAppliesTheServerDefaultsInMemory() async {
        let bus = DiagnosticBus()
        let hits = LockedBox<[String]>([])
        let provisional = LockedBox<[SDKConfigResponse]>([])
        let sync = makeSync(bus: bus, hits: hits, provisional: provisional)
        AttributionCaptureProtocol.scriptConfig([
            (Self.resolvedBody, 0), (Self.defaultsBody, 0), (Self.resolvedBody, 0), (Self.defaultsBody, 0), (Self.defaultsBody, 0),
        ])
        Self.resolve(["resolved", "unknown_device", "resolved", "unknown_device", "unknown_device"])
        await sync.refresh(deviceId: "device-1")
        await sync.refresh(deviceId: "device-1")
        await sync.refresh(deviceId: "device-2")
        XCTAssertEqual(provisional.get().count, 0, "precondition: a real body shields the device")
        await sync.refresh(deviceId: "device-2")

        XCTAssertEqual(Self.reasons(bus), ["resolved_then_unknown", "capped"])
        XCTAssertEqual(provisional.get().last?.flags["native_home"]?.value as? Bool, false,
                       "a capped trigger kept the erased device's values")
        await sync.refresh(deviceId: "device-2")
        XCTAssertEqual(provisional.get().count, 2, "a later unresolved answer was refused")
    }
}
