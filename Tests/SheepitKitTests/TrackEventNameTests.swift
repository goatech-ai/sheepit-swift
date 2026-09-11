import XCTest
@testable import SheepitKit

/// Regression coverage for FIX 3 in the 2026-09 security follow-up to #972: `track(_:)`'s
/// `validateEventName` used `precondition(!trimmed.isEmpty, ...)`, which traps the host
/// process in a release build on a caller's empty/whitespace-only event name — the exact
/// "must not abort the host app" property #972 shipped for a rejected API key, but which
/// never got applied here.
final class TrackEventNameTests: XCTestCase {
    private static let hex = String(repeating: "a", count: 64)
    private let suiteName = "ai.goatech.sdk"

    /// `SheepitClient` hardcodes its `UserDefaults` suite, so a session left behind by an
    /// earlier test would be resumed and `$session_start` would not fire from `start()` —
    /// making the "queue grew by exactly one" assertions below flaky depending on run order.
    /// Clearing just the two session keys (not the whole domain, which holds device
    /// identity) forces every client here onto a fresh session, so `start()` always queues
    /// exactly one `$session_start` before the test's own `track()` call. Mirrors
    /// `SessionStartEmissionTests.clearStoredSession()`.
    private func clearStoredSession() {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        defaults.removeObject(forKey: StorageKeys.sessionId)
        defaults.removeObject(forKey: StorageKeys.sessionLastSeen)
    }

    override func setUp() {
        super.setUp()
        clearStoredSession()
    }

    override func tearDown() {
        clearStoredSession()
        super.tearDown()
    }

    final class EventSink: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [DiagnosticEvent] = []
        func append(_ event: DiagnosticEvent) { lock.lock(); events.append(event); lock.unlock() }
        var codes: [String] { lock.lock(); defer { lock.unlock() }; return events.map(\.code) }
    }

    private func makeClient(collecting sink: EventSink) -> SheepitClient {
        SheepitClient.create(config: SheepitConfig(
            apiKey: "lp_pub_xxx_\(Self.hex)",
            apiUrl: "https://stub.invalid",
            crashes: CrashConfig(enabled: false),
            onDiagnostic: { @Sendable event in sink.append(event) }
        ))
    }

    func testEmptyEventNameIsDroppedRatherThanCrashing() {
        let sink = EventSink()
        let sdk = makeClient(collecting: sink)
        // `start()` already queued its own `$session_start` on this fresh session — assert
        // against that baseline rather than an absolute 0, which #973 made incorrect.
        let depthAfterStart = sdk.status().queueDepth

        sdk.track("")

        XCTAssertEqual(
            sdk.status().queueDepth, depthAfterStart,
            "An empty event name must not be queued."
        )
        XCTAssertTrue(sink.codes.contains("transport.invalid_event_name"))
        sdk.destroy()
    }

    func testWhitespaceOnlyEventNameIsDroppedRatherThanCrashing() {
        let sink = EventSink()
        let sdk = makeClient(collecting: sink)
        let depthAfterStart = sdk.status().queueDepth

        sdk.track("   \n\t  ")

        XCTAssertEqual(sdk.status().queueDepth, depthAfterStart)
        XCTAssertTrue(sink.codes.contains("transport.invalid_event_name"))
        sdk.destroy()
    }

    func testNonEmptyEventNameStillQueuesNormally() {
        let sink = EventSink()
        let sdk = makeClient(collecting: sink)
        let depthAfterStart = sdk.status().queueDepth

        sdk.track("real_event")

        XCTAssertEqual(sdk.status().queueDepth, depthAfterStart + 1)
        XCTAssertFalse(sink.codes.contains("transport.invalid_event_name"))
        sdk.destroy()
    }
}
