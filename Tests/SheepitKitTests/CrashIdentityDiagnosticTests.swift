import XCTest
import Darwin
@testable import SheepitKit

/// Unavailable saved cohorts produce an existing-bus diagnostic without identity or token contents.
final class CrashIdentityDiagnosticTests: XCTestCase {
    func testSidecarInstallFailureHasAStructuredUnavailableOutcome() async throws {
        let directory = CrashFixtures.tempDirectory("cohort-sidecar-failure")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("current.supplement"),
            withIntermediateDirectories: true)
        let diagnostics = DiagnosticBus()
        let reporter = CrashReporter(http: HTTPClient(config: SheepitConfig(
            apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64), apiUrl: "https://stub.invalid"),
            log: Logger(debug: false)), context: ContextManager(storage: InMemoryStorage()),
            config: CrashConfig(enabled: true), appVersionOverride: nil, storage: InMemoryStorage(),
            log: Logger(debug: false), appState: AppForegroundState(launchedInBackground: false, tracksAppState: true),
            crashDirectory: directory, diagnostics: diagnostics)
        await reporter.start()
        addTeardownBlock { await reporter.stop(); try? FileManager.default.removeItem(at: directory) }
        let event = try XCTUnwrap(diagnostics.getRecentDiagnostics().first { $0.code == "transport.crash_identity" })
        XCTAssertEqual(event.severity, .warn)
        XCTAssertEqual(event.data?["outcome"]?.value as? String, "sidecar_unavailable")
        XCTAssertEqual(event.data?.keys.sorted(), ["outcome"])
    }

    func testUnavailableSavedCohortIsDiagnosedDuringTheRealUploadPath() async throws {
        AttributionCaptureProtocol.reset()
        for (rawCount, version, unreadable) in [
            (UInt32(2), UInt32(3), false), (513, 3, false), (UInt32.max, 3, false),
            (2, 1, false), (2, 2, false), (2, 4, false), (2, 3, true),
        ] {
            let directory = CrashFixtures.tempDirectory("cohort-upload-diagnostic")
            let report = directory.appendingPathComponent("current.crash")
            let supplement = directory.appendingPathComponent("current.supplement")
            try CrashFixtures.writeReport(to: report, imageCount: rawCount)
            var unavailable = CrashCohortFixtures.capture(user: "private-saved-user", token: "private-saved-token")
            if rawCount == 2 && version == 3 && !unreadable { unavailable.valid = 0 }
            try CrashCohortFixtures.write(unavailable, to: supplement,
                imageCount: rawCount == 2 ? 2 : 512, formatVersion: version)
            if unreadable {
                try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: supplement.path)
                let descriptor = open(supplement.path, O_RDONLY)
                let readError = errno
                if descriptor >= 0 { close(descriptor) }
                XCTAssertEqual(descriptor, -1)
                XCTAssertEqual(readError, EACCES)
            }
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: supplement.path) }
            let diagnostics = DiagnosticBus()
            let reporter = CrashReporter(http: HTTPClient(config: SheepitConfig(
                apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64), apiUrl: "https://stub.invalid",
                retryAttempts: 1), log: Logger(debug: false), urlProtocolClasses: [AttributionCaptureProtocol.self]),
                context: ContextManager(storage: InMemoryStorage()), config: CrashConfig(enabled: true),
                appVersionOverride: nil, storage: InMemoryStorage(), log: Logger(debug: false),
                appState: AppForegroundState(launchedInBackground: false, tracksAppState: true),
                crashDirectory: directory, diagnostics: diagnostics,
                now: { Date(timeIntervalSince1970: Double(CrashFixtures.timestampMs) / 1000 + 1) })
            await reporter.start()
            addTeardownBlock {
                await reporter.stop()
                try? FileManager.default.removeItem(at: directory)
                AttributionCaptureProtocol.reset()
            }
            let event = try XCTUnwrap(diagnostics.getRecentDiagnostics().first { $0.code == "transport.crash_identity" })
            XCTAssertEqual(event.severity, .warn)
            XCTAssertEqual(event.category, .transport)
            XCTAssertEqual(event.data?["outcome"]?.value as? String, "unavailable")
            XCTAssertEqual(event.data?.keys.sorted(), ["outcome"])
            XCTAssertFalse(event.message.contains("private-saved"))
            XCTAssertTrue(diagnostics.getRecentDiagnostics().contains {
                $0.code == "transport.crash_upload" && $0.data?["outcome"]?.value as? String == "uploaded"
            })
            await reporter.stop()
        }
    }
}
