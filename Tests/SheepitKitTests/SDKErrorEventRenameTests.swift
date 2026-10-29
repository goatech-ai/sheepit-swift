import XCTest
@testable import SheepitKit

/// Regression fence for decision 10 (`$sdk_error` -> `$error`,
/// DEVICE_CONTEXT_AND_AUDIENCE_ANALYTICS.md § 8) — `trackSDKError()`'s event NAME has no
/// compiler check, so a future refactor could silently revert it or typo it. Historical
/// rows in `events_raw` stay under `$sdk_error`; only new emissions move.
final class SDKErrorEventRenameTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SharedSDKStorage.clear()
        TeardownFlushes.install()
    }

    /// Awaits every destroyed client's fire-and-forget final flush before the shared stub and
    /// storage are reset, so it cannot land in the next test (`TeardownFlushes`).
    override func tearDown() async throws {
        await TeardownFlushes.drain(context: name)
        SharedSDKStorage.clear()
        try await super.tearDown()
    }

    func testTrackSDKErrorEmitsTheRenamedEventName() {
        let recorder = EventLifecycleRecorder()
        let client = SheepitClient.create(
            config: SheepitConfig(
                apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))",
                apiUrl: "http://127.0.0.1:1",
                // Loopback port 1 refuses at once (no DNS lookup), and one attempt skips the 1 s / 5 s
                // backoff — so the final flush `destroy()` starts settles before `tearDown` drains it.
                retryAttempts: 1,
                onEvent: { name, _ in recorder.record(name) },
                crashes: CrashConfig(enabled: false)
            )
        )
        defer { client.destroy() }

        client.trackSDKError(source: "test", error: SDKError.invalidResponse)

        XCTAssertTrue(recorder.wasRecorded("$error"), "the renamed event must be $error")
        XCTAssertFalse(
            recorder.wasRecorded("$sdk_error"),
            "the old name must never fire again — a saved chart filtering it goes flat, by design"
        )
    }

    /// `origin`/`type` are what separate SDK-internal `$error`s from a host app's
    /// `captureError` ones (`origin: "app"`, `type: "handled"`); `source` stays, because the
    /// server's host-app error predicate excludes on it.
    func testTrackSDKErrorIsMarkedAsSDKInternal() throws {
        let captured = LockedBox<[String: Any]?>(nil)
        let client = SheepitClient.constructOnlyForTesting(
            config: SheepitConfig(
                apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))",
                apiUrl: "http://127.0.0.1:1",
                // Loopback port 1 refuses at once (no DNS lookup), and one attempt skips the 1 s / 5 s
                // backoff — so the final flush `destroy()` starts settles before `tearDown` drains it.
                retryAttempts: 1,
                onEvent: { name, props in if name == "$error" { captured.set(props) } },
                crashes: CrashConfig(enabled: false)
            )
        )
        defer { client.destroy() }

        client.trackSDKError(source: "crashes", error: SDKError.httpError(503), endpoint: "/v1/crashes/report")

        let props = try XCTUnwrap(captured.get())
        XCTAssertEqual(props["origin"] as? String, "sdk")
        XCTAssertEqual(props["type"] as? String, "sdk_internal")
        XCTAssertEqual(props["source"] as? String, "crashes")
        XCTAssertEqual(props["platform"] as? String, DeviceProfile.platform)
        XCTAssertEqual(props["endpoint"] as? String, "/v1/crashes/report")
        XCTAssertEqual(props["status_code"] as? Int, 503)
    }
}

private final class EventLifecycleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _names: [String] = []

    func record(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        _names.append(name)
    }

    func wasRecorded(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; return _names.contains(name)
    }
}
