import XCTest
import SheepitCrashHandler
@testable import SheepitKit

/// Uses the existing test factory and real owned reporter lifecycle in a temporary live directory.
@MainActor
func makeOwnedCrashClient(
    in test: XCTestCase, directory: URL, onDiagnostic: DiagnosticListener? = nil,
    onEvent: (@Sendable (String, [String: Any]?) -> Void)? = nil, allowFlagOverrides: Bool = false
) async throws -> SheepitClient {
    let client = SheepitClient.createForTesting(config: SheepitConfig(
        apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64), apiUrl: "https://stub.invalid",
        flushInterval: 3600, flushSize: 1000, configRefreshInterval: 3600, retryAttempts: 1,
        onEvent: onEvent, crashes: CrashConfig(enabled: true), onDiagnostic: onDiagnostic, allowFlagOverrides: allowFlagOverrides), now: { Date() },
        urlProtocolClasses: [AttributionCaptureProtocol.self],
        crashPendingDirectory: directory.appendingPathComponent("pending"), crashDirectory: directory)
    let reporter = try XCTUnwrap(client.crashReporterForTesting)
    test.addTeardownBlock {
        client.destroy()
        await reporter.stop()
        try? FileManager.default.removeItem(at: directory)
    }
    let deadline = Date().addingTimeInterval(3)
    while !client.getRecentDiagnostics().contains(where: {
        $0.code == "identity.crash_cohort" && $0.data?["outcome"]?.value as? String == "published"
    }) {
        guard Date() < deadline else { XCTFail("Owned reporter did not publish its initial cohort"); return client }
        try await Task.sleep(for: .milliseconds(10))
    }
    return client
}
