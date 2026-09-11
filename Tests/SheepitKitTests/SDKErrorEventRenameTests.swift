import XCTest
@testable import SheepitKit

/// Regression fence for decision 10 (`$sdk_error` -> `$error`,
/// DEVICE_CONTEXT_AND_AUDIENCE_ANALYTICS.md § 8) — `trackSDKError()`'s event NAME has no
/// compiler check, so a future refactor could silently revert it or typo it. Historical
/// rows in `events_raw` stay under `$sdk_error`; only new emissions move.
final class SDKErrorEventRenameTests: XCTestCase {
    func testTrackSDKErrorEmitsTheRenamedEventName() {
        let recorder = EventLifecycleRecorder()
        let client = SheepitClient.create(
            config: SheepitConfig(
                apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))",
                apiUrl: "https://stub.invalid",
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
