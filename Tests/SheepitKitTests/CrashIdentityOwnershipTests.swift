import XCTest
import SheepitCrashHandler
@testable import SheepitKit

/// Only a successful owned installation may publish into the process-global crash mapping.
final class CrashIdentityOwnershipTests: XCTestCase {
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
    func testUnstartedReporterDoesNotCreateDirectoryOrCorruptAnOwnersCohort() async throws {
        let dir = CrashFixtures.tempDirectory("cohort-owner")
        let owner = try await makeOwnedCrashClient(in: self, directory: dir)
        owner.identify(userId: "owner")
        let intruderDir = dir.appendingPathComponent("unstarted")
        let diagnostics = DiagnosticBus()
        let intruder = makeReporter(directory: intruderDir, diagnostics: diagnostics)
        XCTAssertFalse(FileManager.default.fileExists(atPath: intruderDir.path))
        intruder.updateContext()
        var raw = sheepit_crash_cohort_t()
        sheepit_crash_cohort_snapshot(&raw)
        XCTAssertEqual(CrashIdentityCohort(raw)?.userId, "owner")
        XCTAssertTrue(diagnostics.getRecentDiagnostics().isEmpty, "unstarted refresh performs no work or callbacks")
        await intruder.stop()
    }

    @MainActor
    func testFailedInstallationDoesNotPublishAnotherReportersIdentity() async throws {
        let dir = CrashFixtures.tempDirectory("cohort-failed-owner")
        let owner = try await makeOwnedCrashClient(in: self, directory: dir)
        owner.identify(userId: "owner")
        let diagnostics = DiagnosticBus()
        let intruder = makeReporter(directory: dir.appendingPathComponent("failed"), diagnostics: diagnostics)
        await intruder.start()
        XCTAssertEqual(diagnostics.getRecentDiagnostics().last?.data?["outcome"]?.value as? String, "unavailable")
        var raw = sheepit_crash_cohort_t()
        sheepit_crash_cohort_snapshot(&raw)
        XCTAssertEqual(CrashIdentityCohort(raw)?.userId, "owner")
        await intruder.stop()
    }

    private func makeReporter(directory: URL, diagnostics: DiagnosticBus) -> CrashReporter {
        let context = ContextManager(storage: InMemoryStorage())
        context.setUserId("intruder")
        return CrashReporter(http: HTTPClient(config: SheepitConfig(
            apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64), apiUrl: "https://stub.invalid"),
            log: Logger(debug: false)), context: context, config: CrashConfig(enabled: true),
            appVersionOverride: nil, storage: InMemoryStorage(), log: Logger(debug: false),
            appState: AppForegroundState(launchedInBackground: false, tracksAppState: true),
            crashDirectory: directory, diagnostics: diagnostics)
    }
}
