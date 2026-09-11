import XCTest
@testable import SheepitKit

/// Regression coverage for the 2026-09 security follow-up (round 3), finding MF-1.
///
/// The round-2 fix clamped `maxQueueSize`/`flushInterval`/`configRefreshInterval` only in
/// `SheepitConfig.init` — but every one of those is a public `var`, so
/// `var cfg = ...; cfg.maxQueueSize = 0` (or `.flushInterval = .infinity`) reaches the actual
/// consumer (`EventQueue.add`, `Task.sleep(for: .seconds(_:))`) completely unclamped. The
/// shipped M2 test passed `maxQueueSize: 0` THROUGH the initializer, so it structurally could
/// not catch this. Every test below exercises the BYPASS — mutate the public var AFTER
/// construction — not just the initializer.
final class SleepIntervalSanitizationTests: XCTestCase {
    private static let hex = String(repeating: "a", count: 64)

    private func makeConfig(crashesEnabled: Bool = false) -> SheepitConfig {
        SheepitConfig(
            apiKey: "lp_pub_xxx_\(Self.hex)",
            apiUrl: "https://stub.invalid",
            crashes: CrashConfig(enabled: crashesEnabled)
        )
    }

    // MARK: - TimeInterval.sanitizedForSleep() — pure function

    func testFiniteValueWithinRangeIsUnchanged() {
        XCTAssertEqual(TimeInterval(5.0).sanitizedForSleep(), 5.0)
    }

    func testInfinityIsFlooredRatherThanTrapping() {
        XCTAssertEqual(TimeInterval.infinity.sanitizedForSleep(), .sleepFloor)
    }

    func testNegativeInfinityIsFlooredRatherThanTrapping() {
        XCTAssertEqual((-TimeInterval.infinity).sanitizedForSleep(), .sleepFloor)
    }

    func testNaNIsFlooredRatherThanTrapping() {
        XCTAssertEqual(TimeInterval.nan.sanitizedForSleep(), .sleepFloor)
    }

    func testZeroIsFlooredToAvoidACPUSpinLoop() {
        XCTAssertEqual(TimeInterval(0).sanitizedForSleep(), .sleepFloor)
    }

    func testNegativeValueIsFlooredToAvoidACPUSpinLoop() {
        XCTAssertEqual(TimeInterval(-1).sanitizedForSleep(), .sleepFloor)
    }

    func testAnAstronomicalFiniteValueIsCeiledRatherThanTrapping() {
        XCTAssertEqual(TimeInterval(1e30).sanitizedForSleep(), .sleepCeiling)
        XCTAssertEqual(TimeInterval(1e19).sanitizedForSleep(), .sleepCeiling)
    }

    // MARK: - EventQueue — the actual consumer of maxQueueSize

    /// The M2-era test (`SheepitConfigClampTests`) only proves `SheepitConfig.init` clamps.
    /// This proves `EventQueue.init` ALSO clamps, independent of what the config struct did —
    /// the layer that actually matters, since `maxQueueSize` is a mutable public `var`.
    func testEventQueueClampsMaxSizeZeroEvenWhenConstructedDirectly() {
        let queue = EventQueue(maxSize: 0)
        // Reaching the assertion at all is the proof: `add(_:)` calls `removeFirst()` once
        // `count >= maxSize`, which traps on an empty array at the unclamped `maxSize == 0`.
        queue.add(makeStubEvent(name: "should_not_trap"))
        XCTAssertEqual(queue.size(), 1)
    }

    func testEventQueueClampsNegativeMaxSize() {
        let queue = EventQueue(maxSize: -5)
        queue.add(makeStubEvent(name: "should_not_trap"))
        XCTAssertEqual(queue.size(), 1)
    }

    /// The full bypass: `SheepitConfig.init` clamps `maxQueueSize` to 1, but a host mutating
    /// the public var straight back to 0 after construction must still not trap `create()`.
    func testCreateDoesNotTrapWhenMaxQueueSizeIsMutatedToZeroAfterConstruction() {
        let defaults = UserDefaults(suiteName: "ai.goatech.sdk")!
        let originalSessionId = defaults.string(forKey: StorageKeys.sessionId)
        let originalLastSeen = defaults.string(forKey: StorageKeys.sessionLastSeen)
        defer {
            defaults.set(originalSessionId, forKey: StorageKeys.sessionId)
            defaults.set(originalLastSeen, forKey: StorageKeys.sessionLastSeen)
        }
        // A NEW session is required to reach the `$session_start` enqueue that traps
        // `EventQueue.add` at `maxSize == 0` — see `SheepitConfigClampTests`'s doc.
        defaults.set("session-expired-for-mf1-test", forKey: StorageKeys.sessionId)
        defaults.set("1000000.0", forKey: StorageKeys.sessionLastSeen)

        var config = makeConfig()
        config.maxQueueSize = 0 // bypasses SheepitConfig.init's clamp entirely
        let sdk = SheepitClient.create(config: config)
        XCTAssertTrue(sdk.status().initialized)
        sdk.destroy()
    }

    // MARK: - The periodic flush loop (SheepitClient.start())

    func testCreateDoesNotCrashWhenFlushIntervalIsMutatedToInfinityAfterConstruction() async {
        var config = makeConfig()
        config.flushInterval = .infinity
        let sdk = SheepitClient.create(config: config)
        // Give the periodic-flush Task a scheduling window to reach
        // `Task.sleep(for: .seconds(flushInterval))` — the unfixed code traps here almost
        // immediately, since `Duration.seconds(.infinity)` is asserted eagerly, not lazily.
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(sdk.status().initialized, "the periodic flush loop must not have crashed the process.")
        sdk.destroy()
    }

    func testCreateDoesNotCrashWhenFlushIntervalIsMutatedToNaNAfterConstruction() async {
        var config = makeConfig()
        config.flushInterval = .nan
        let sdk = SheepitClient.create(config: config)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(sdk.status().initialized)
        sdk.destroy()
    }

    func testCreateDoesNotCrashWhenFlushIntervalIsAnAstronomicalFiniteValue() async {
        var config = makeConfig()
        config.flushInterval = 1e30
        let sdk = SheepitClient.create(config: config)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(sdk.status().initialized)
        sdk.destroy()
    }

    // MARK: - ConfigSync's periodic refresh loop

    func testCreateDoesNotCrashWhenConfigRefreshIntervalIsMutatedToInfinityAfterConstruction() async {
        var config = makeConfig()
        config.configRefreshInterval = .infinity
        let sdk = SheepitClient.create(config: config)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(sdk.status().initialized)
        sdk.destroy()
    }

    func testCreateDoesNotCrashWhenConfigRefreshIntervalIsMutatedToAnAstronomicalValue() async {
        var config = makeConfig()
        config.configRefreshInterval = 1e19
        let sdk = SheepitClient.create(config: config)
        try? await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(sdk.status().initialized)
        sdk.destroy()
    }

    // MARK: - PerformanceMonitor's periodic flush loop

    /// Constructed standalone (not through `SheepitClient`) so this doesn't also start the
    /// frame/memory/network trackers or a real crash handler — the flush-interval Task.sleep
    /// site is the only thing under test.
    func testPerformanceMonitorDoesNotCrashWhenFlushIntervalIsMutatedToNaNAfterConstruction() async {
        let http = HTTPClient(
            config: SheepitConfig(apiKey: "lp_pub_xxx_\(Self.hex)", apiUrl: "https://stub.invalid"),
            log: Logger(debug: false)
        )
        let context = ContextManager(storage: InMemoryStorage())
        var perfConfig = PerformanceConfig(
            enabled: true,
            startupTrackingEnabled: false,
            frameTrackingEnabled: false,
            networkTrackingEnabled: false,
            memoryTrackingEnabled: false
        )
        perfConfig.flushInterval = .nan // bypasses PerformanceConfig.init's clamp

        let monitor = PerformanceMonitor(http: http, context: context, config: perfConfig, log: Logger(debug: false))
        await monitor.start()
        try? await Task.sleep(for: .milliseconds(200))
        // Reaching here is the proof — the unfixed code traps inside the flush Task.
        await monitor.stop()
    }
}
