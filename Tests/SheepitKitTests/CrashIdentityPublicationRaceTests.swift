import XCTest
import SheepitCrashHandler
@testable import SheepitKit

/// The actual client's publication callback obeys exposure ordering and never invokes host code locked.
final class CrashIdentityPublicationRaceTests: XCTestCase {
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

    @MainActor
    func testDelayedContextRefreshCannotOverwriteANewerIdentityOrConfig() async throws {
        let dir = CrashFixtures.tempDirectory("identity-delayed-refresh")
        let client = try await makeOwnedCrashClient(in: self, directory: dir)
        client.identify(userId: "user-A")
        let reporter = try XCTUnwrap(client.crashReporterForTesting)
        let reached = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let complete = expectation(description: "delayed refresh finishes")
        defer { release.signal(); client.exposureDecisionGateForTesting.willLockHookForTesting.value = nil }
        client.exposureDecisionGateForTesting.willLockHookForTesting.value = { _ in
            if Thread.current.name == "delayed-crash-refresh" {
                reached.signal()
                XCTAssertEqual(release.wait(timeout: .now() + 3), .success)
            }
        }
        let thread = Thread {
            Thread.current.name = "delayed-crash-refresh"
            reporter.updateContext()
            complete.fulfill()
        }
        thread.start()
        XCTAssertEqual(reached.wait(timeout: .now() + 3), .success)
        client.identify(userId: "user-B")
        client.applyConfigForTesting(flags: ["latest": AnyCodable(true)], assignments: [:], appliedUnder: .fetchedUnder("user-B"))
        release.signal()
        await fulfillment(of: [complete], timeout: 3)
        var cohort = sheepit_crash_cohort_t()
        sheepit_crash_cohort_snapshot(&cohort)
        XCTAssertEqual(CrashIdentityCohort(cohort)?.userId, "user-B")
        let context = try XCTUnwrap(sheepit_get_crash_context())
        XCTAssertEqual(CrashText.string(context.pointee.active_flags_json), #"{"latest":true}"#)
    }

    @MainActor
    func testIdentifyResetAndDeviceRefreshPublishFullCohortsBeforeReturning() async throws {
        let dir = CrashFixtures.tempDirectory("identity-transitions")
        let client = try await makeOwnedCrashClient(in: self, directory: dir)
        let id = String(repeating: "界", count: 256)
        client.identify(userId: id)
        var raw = sheepit_crash_cohort_t()
        sheepit_crash_cohort_snapshot(&raw)
        XCTAssertEqual(CrashIdentityCohort(raw)?.userId, id)
        client.reset()
        sheepit_crash_cohort_snapshot(&raw)
        XCTAssertNil(CrashIdentityCohort(raw)?.userId)
        XCTAssertEqual(CrashIdentityCohort(raw)?.deviceId, client.context.deviceId)
        client.context.setDeviceId("replacement-device")
        client.crashReporterForTesting?.updateContext()
        sheepit_crash_cohort_snapshot(&raw)
        XCTAssertEqual(CrashIdentityCohort(raw)?.deviceId, "replacement-device")
        XCTAssertNil(CrashIdentityCohort(raw)?.userId)
    }

    @MainActor
    func testActualC5ReplacementPublishesTheAdoptedDevice() async throws {
        let oldDevice = SharedSDKStorage.markRegistered()
        let erased = LockedBox(false)
        let resolved = #"{"data":{"config_version":"7","etag":"v7","flags":{"native_home":true},"experiments":{}}}"#
        let defaults = #"{"data":{"config_version":"7","etag":"u7","flags":{"native_home":false},"experiments":{}}}"#
        AttributionCaptureProtocol.configResponder = { device, hasRow in
            if device == oldDevice { return erased.get() ? (defaults, "unknown_device") : (resolved, "resolved") }
            return hasRow ? (resolved, "resolved") : (defaults, "unknown_device")
        }
        AttributionCaptureProtocol.echoRegisteredDeviceId = true
        let directory = CrashFixtures.tempDirectory("identity-c5")
        let client = try await makeOwnedCrashClient(in: self, directory: directory)
        await client.refreshConfigForTesting()
        XCTAssertEqual(client.flag("native_home"), .bool(true))
        erased.set(true)
        await client.refreshConfigForTesting()
        let deadline = Date().addingTimeInterval(3)
        while !client.getRecentDiagnostics().contains(where: { $0.code == "identity.device_replaced_unknown" }) {
            guard Date() < deadline else { return XCTFail("Actual C5 replacement never completed") }
            try await Task.sleep(for: .milliseconds(10))
        }
        let adopted = client.context.eventContext().deviceId
        XCTAssertNotEqual(adopted, oldDevice)
        var raw = sheepit_crash_cohort_t()
        sheepit_crash_cohort_snapshot(&raw)
        XCTAssertEqual(CrashIdentityCohort(raw)?.deviceId, adopted)
        XCTAssertNil(CrashIdentityCohort(raw)?.userId)
    }

    @MainActor
    func testPublicationDiagnosticRunsOutsideExposureAndLeaksNoIdentity() async throws {
        let dir = CrashFixtures.tempDirectory("identity-diagnostic")
        let holder = LockedBox<SheepitClient?>(nil)
        let observed = LockedBox<[DiagnosticEvent]>([])
        let client = try await makeOwnedCrashClient(in: self, directory: dir, onDiagnostic: { event in
            guard event.code == "identity.crash_cohort" else { return }
            if let client = holder.get() {
                XCTAssertFalse(client.exposureDecisionGateForTesting.isHeldForTesting())
                _ = client.flag("diagnostic-reentrant", default: .bool(false))
            }
            observed.mutate { $0.append(event) }
        })
        holder.set(client)
        defer { holder.set(nil) }
        client.identify(userId: "private-user")
        let event = try XCTUnwrap(observed.get().last)
        XCTAssertEqual(event.data?["outcome"]?.value as? String, "published")
        XCTAssertEqual(event.data?.keys.sorted(), ["outcome"])
        XCTAssertFalse(event.message.contains("private-user"))
    }

}
