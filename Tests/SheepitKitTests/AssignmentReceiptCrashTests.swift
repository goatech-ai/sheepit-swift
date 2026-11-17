import XCTest
import SheepitCrashHandler
@testable import SheepitKit

/// Actual owned reporter publication uses N1's single full-identity cohort; saved reports never repair.
final class AssignmentReceiptCrashTests: XCTestCase {
    override func setUp() {
        SharedSDKStorage.clear()
        AttributionCaptureProtocol.reset()
        TeardownFlushes.install()
    }
    override func tearDown() async throws {
        await TeardownFlushes.drain(context: name)
        SharedSDKStorage.clear()
        AttributionCaptureProtocol.reset()
    }
    private func cohort() throws -> CrashIdentityCohort {
        var value = sheepit_crash_cohort_t()
        sheepit_crash_cohort_snapshot(&value)
        return try XCTUnwrap(CrashIdentityCohort(value))
    }

    @MainActor
    func testFullIdentityReceiptAndResetArePublishedAndSavedTogether() async throws {
        SharedSDKStorage.markRegistered()
        let directory = CrashFixtures.tempDirectory("receipt-full-live")
        let client = try await makeOwnedCrashClient(in: self, directory: directory)
        let device = client.context.deviceId
        let session = client.context.sessionId
        let full = String(repeating: "界", count: 256)
        AttributionCaptureProtocol.setIdentifyReply(.hold, for: full)
        defer { AttributionCaptureProtocol.releaseHeldIdentify() }
        client.identify(userId: full)
        client.applyConfigForTesting(flags: ["feature": AnyCodable(true)], assignments: [:],
            appliedUnder: .fetchedUnder(full), assignmentToken: "full-identity-receipt")
        let captured = try cohort()
        XCTAssertEqual(captured.userId, full)
        XCTAssertEqual(captured.deviceId, device)
        XCTAssertEqual(captured.sessionId, session)
        XCTAssertEqual(captured.assignmentToken, "full-identity-receipt")
        XCTAssertFalse(captured.identityChanged)
        let report = directory.appendingPathComponent("saved.crash")
        let supplement = directory.appendingPathComponent("saved.supplement")
        try CrashFixtures.writeReport(to: report)
        var raw = sheepit_crash_cohort_t()
        sheepit_crash_cohort_snapshot(&raw)
        try CrashCohortFixtures.write(raw, to: supplement)
        let bytes = try Data(contentsOf: supplement)
        client.reset()
        XCTAssertNil(try cohort().assignmentToken)
        XCTAssertNil(try cohort().userId)
        let payload = try XCTUnwrap(CrashReportReader.read(from: report.path, supplementPath: supplement.path))
        let wire = try CrashFixtures.wireJSON(payload)
        XCTAssertEqual(wire["assignment_token"] as? String, "full-identity-receipt")
        XCTAssertEqual(wire["user_id"] as? String, full)
        XCTAssertEqual(try Data(contentsOf: supplement), bytes)
    }

    @MainActor
    func testActualOverrideObserverCannotPublishThePartialManagersNewReceipt() async throws {
        SharedSDKStorage.markRegistered()
        let directory = CrashFixtures.tempDirectory("receipt-partial-override")
        let client = try await makeOwnedCrashClient(in: self, directory: directory, allowFlagOverrides: true)
        defer { client.clearOverrides() }
        client.clearOverrides()
        let a = try JSONDecoder().decode(SDKExperimentAssignment.self,
            from: Data(#"{"variant_key":"a","payload":{}}"#.utf8))
        let b = try JSONDecoder().decode(SDKExperimentAssignment.self,
            from: Data(#"{"variant_key":"b","payload":{}}"#.utf8))
        client.applyConfigForTesting(flags: ["feature": AnyCodable(false)], assignments: ["experiment": a],
            appliedUnder: .fetchedUnder(nil), assignmentToken: "receipt-a")
        XCTAssertEqual(try cohort().assignmentToken, "receipt-a")
        client.exposureDecisionGateForTesting.withLock {
            client.seedAssignmentsForTesting(["experiment": b], assignmentToken: "receipt-b")
            XCTAssertNotEqual(try? cohort().assignmentToken, "receipt-b")
            client.overrideFlag("debug-only", value: .bool(true))
            XCTAssertNotEqual(try? cohort().assignmentToken, "receipt-b",
                "a private override observer must not publish B while A flags remain applied")
        }
        client.applyConfigForTesting(flags: ["feature": AnyCodable(true)], assignments: ["experiment": b],
            appliedUnder: .fetchedUnder(nil), assignmentToken: "receipt-b")
        XCTAssertEqual(try cohort().assignmentToken, "receipt-b")
    }

    @MainActor
    func testActualC5AdoptionInvalidatesTheOldReceiptBeforeTheReplacementHook() async throws {
        let oldDevice = SharedSDKStorage.markRegistered()
        SharedSDKStorage.slotStorage().set(try JSONEncoder().encode(ServerHeldUser.known(nil)), forKey: StorageKeys.serverHeldUser)
        let erased = LockedBox(false)
        let resolved = #"{"data":{"config_version":"7","flags":{"native_home":true},"experiments":{},"assignment_token":"receipt-old-device"}}"#
        let defaults = #"{"data":{"config_version":"7","flags":{"native_home":false},"experiments":{},"assignment_token":"receipt-old-device"}}"#
        AttributionCaptureProtocol.configResponder = { device, hasRow in
            if device == oldDevice { return erased.get() ? (defaults, "unknown_device") : (resolved, "resolved") }
            return hasRow ? (resolved, "resolved") : (defaults, "unknown_device")
        }
        AttributionCaptureProtocol.echoRegisteredDeviceId = true
        let directory = CrashFixtures.tempDirectory("receipt-c5-adoption")
        let client = try await makeOwnedCrashClient(in: self, directory: directory)
        await client.refreshConfigForTesting()
        XCTAssertEqual(try cohort().assignmentToken, "receipt-old-device")
        let observed = LockedBox<[CrashIdentityCohort]>([])
        client.deviceIdChangeHookForTesting.value = { _ in
            var raw = sheepit_crash_cohort_t()
            sheepit_crash_cohort_snapshot(&raw)
            if let value = CrashIdentityCohort(raw) { observed.mutate { $0.append(value) } }
        }
        erased.set(true)
        await client.refreshConfigForTesting()
        let deadline = Date().addingTimeInterval(3)
        while !client.getRecentDiagnostics().contains(where: { $0.code == "identity.device_replaced_unknown" }) {
            guard Date() < deadline else { return XCTFail("Actual C5 replacement never completed") }
            try await Task.sleep(for: .milliseconds(10))
        }
        let replacement = try XCTUnwrap(observed.get().first)
        XCTAssertNotEqual(replacement.deviceId, oldDevice)
        XCTAssertNil(replacement.assignmentToken, "the old device receipt must be gone before the host hook")
        XCTAssertEqual(replacement.deviceId, client.context.deviceId)
    }

}
