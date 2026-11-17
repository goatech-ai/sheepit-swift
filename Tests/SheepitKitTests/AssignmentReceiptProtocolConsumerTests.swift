import XCTest
import SheepitCrashHandler
@testable import SheepitKit

/// Baseline-compatible real consumers prove the new protocol, without depending on new receipt APIs.
final class AssignmentReceiptProtocolConsumerTests: XCTestCase {
    override func setUp() {
        SharedSDKStorage.clear()
        AttributionCaptureProtocol.reset()
        AttributionCaptureProtocol.configResolution = { _, _ in "resolved" }
        AttributionCaptureProtocol.honorIfNoneMatch = false
        TeardownFlushes.install()
    }
    override func tearDown() async throws {
        await TeardownFlushes.drain(context: name)
        SharedSDKStorage.clear()
        AttributionCaptureProtocol.reset()
    }

    func testRealConfigReceiptIsFrozenBeforeALaterConfigAndFlush() async throws {
        func serve(_ token: String) {
            AttributionCaptureProtocol.serveConfig("{\"data\":{\"config_version\":\"1\",\"flags\":{},\"experiments\":{\"pricing\":{\"variant_key\":\"treatment\",\"payload\":{}}},\"assignment_token\":\"\(token)\"}}")
        }
        serve("captured-receipt")
        SharedSDKStorage.markRegistered("receipt-device")
        SharedSDKStorage.slotStorage().set(try JSONEncoder().encode(ServerHeldUser.known(nil)), forKey: StorageKeys.serverHeldUser)
        let client = SheepitClient.createForTesting(config: SheepitConfig(
            apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64), apiUrl: "https://stub.invalid",
            flushInterval: 3600, flushSize: 1000, configRefreshInterval: 3600, retryAttempts: 1),
            now: { Date() }, urlProtocolClasses: [AttributionCaptureProtocol.self])
        defer { client.destroy() }
        await client.refreshConfigForTesting()
        client.track("captured_before_refresh")
        serve("later-receipt")
        await client.refreshConfigForTesting()
        await client.flush()
        let event = try XCTUnwrap(AttributionCaptureProtocol.event(named: "captured_before_refresh"))
        let context = try XCTUnwrap(event["context"] as? [String: Any])
        XCTAssertEqual(context["assignment_token"] as? String, "captured-receipt")
        XCTAssertNil(context["experiments"])
        XCTAssertNil(context["experiment_assignments"])
    }

    func testMarkedSavedCohortReachesTheCrashWireWithItsIdentityAndNoToken() throws {
        let directory = CrashFixtures.tempDirectory("receipt-protocol-wire")
        defer { try? FileManager.default.removeItem(at: directory) }
        let report = directory.appendingPathComponent("saved.crash")
        let supplement = directory.appendingPathComponent("saved.supplement")
        let user = String(repeating: "界", count: 256)
        try CrashFixtures.writeReport(to: report)
        try CrashCohortFixtures.write(CrashCohortFixtures.capture(user: user,
            device: "saved-device", session: "saved-session", token: "saved-receipt", changed: true), to: supplement)
        _ = CrashCohortFixtures.capture(user: "uploader", token: "later-receipt")
        let payload = try XCTUnwrap(CrashReportReader.read(from: report.path, supplementPath: supplement.path))
        let wire = try CrashFixtures.wireJSON(payload)
        XCTAssertNil(wire["assignment_token"], "a marked cohort makes no claim, whatever the saved bytes carry")
        XCTAssertEqual(wire["assignment_status"] as? String, "identity_changed")
        XCTAssertEqual(wire["user_id"] as? String, user)
        XCTAssertEqual(wire["device_id"] as? String, "saved-device")
        XCTAssertEqual(wire["session_id"] as? String, "saved-session")
        XCTAssertNil(wire["active_experiments"])
    }
}
