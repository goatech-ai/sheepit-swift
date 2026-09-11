import XCTest
@testable import SheepitKit

/// Regression coverage for the 2026-09 security follow-up (round 2), finding M2:
/// `EventQueue.add` does `events.removeFirst()` once `count >= maxSize`, which traps on an
/// empty array ("Can't remove first element from an empty collection", signal 5) at
/// `maxSize == 0`. This was reachable from `SheepitClient.create()` itself, because #973's
/// `start() -> emitSessionStartIfOwed() -> track("$session_start")` enqueues an event during
/// construction — so `SheepitConfig(maxQueueSize: 0)` aborted the host process from inside
/// `create()`, exactly the class of defect this whole PR series exists to close.
final class SheepitConfigClampTests: XCTestCase {
    private static let hex = String(repeating: "a", count: 64)

    func testMaxQueueSizeZeroIsClampedToOne() {
        let config = SheepitConfig(apiKey: "lp_pub_xxx_\(Self.hex)", maxQueueSize: 0)
        XCTAssertEqual(config.maxQueueSize, 1, "maxQueueSize must be clamped to a floor of 1.")
    }

    func testNegativeMaxQueueSizeIsAlsoClamped() {
        let config = SheepitConfig(apiKey: "lp_pub_xxx_\(Self.hex)", maxQueueSize: -5)
        XCTAssertEqual(config.maxQueueSize, 1)
    }

    func testOrdinaryMaxQueueSizeIsUnaffected() {
        let config = SheepitConfig(apiKey: "lp_pub_xxx_\(Self.hex)", maxQueueSize: 1000)
        XCTAssertEqual(config.maxQueueSize, 1000)
    }

    /// The end-to-end regression: `maxQueueSize: 0` must not trap `create()`. Reaching the
    /// final assertion at all IS the proof — the unclamped path aborts the whole process
    /// before `create()` returns, which fails the test binary rather than this one test.
    ///
    /// The trap is only reachable when `start()` actually enqueues `$session_start` — which
    /// requires a NEW session. This is the REAL, hardcoded `ai.goatech.sdk` suite every live
    /// client in this test target shares, so a session another test left live moments ago
    /// (well inside the 30-minute idle window) would otherwise make `$session_start` a no-op
    /// and this test pass for the wrong reason even without the M2 fix. Seeding an expired
    /// session forces a genuinely new one.
    func testCreateWithMaxQueueSizeZeroDoesNotTrap() {
        let defaults = UserDefaults(suiteName: "ai.goatech.sdk")!
        let originalSessionId = defaults.string(forKey: StorageKeys.sessionId)
        let originalLastSeen = defaults.string(forKey: StorageKeys.sessionLastSeen)
        defer {
            defaults.set(originalSessionId, forKey: StorageKeys.sessionId)
            defaults.set(originalLastSeen, forKey: StorageKeys.sessionLastSeen)
        }
        defaults.set("session-expired-for-m2-test", forKey: StorageKeys.sessionId)
        defaults.set("1000000.0", forKey: StorageKeys.sessionLastSeen)

        let config = SheepitConfig(
            apiKey: "lp_pub_xxx_\(Self.hex)",
            apiUrl: "https://stub.invalid",
            maxQueueSize: 0,
            crashes: CrashConfig(enabled: false)
        )
        let sdk = SheepitClient.create(config: config)
        XCTAssertTrue(sdk.status().initialized)
        sdk.destroy()
    }
}
