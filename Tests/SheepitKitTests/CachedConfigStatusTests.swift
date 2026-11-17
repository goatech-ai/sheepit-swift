import XCTest
@testable import SheepitKit

/// The cache-age limits through a real `SheepitClient`: `status().configFreshness`, the
/// `config_source` / `config_age_ms` exposure properties, `reset()`, and validation of
/// `configStaleAfter` / `configOfflineMaxAge`, including after a direct mutation of the `var`s.
final class CachedConfigStatusTests: XCTestCase {
    private static let hour: TimeInterval = 3600
    private static let launch = Date(timeIntervalSince1970: 1_800_000_000)
    private static let body = #"""
    {"data":{"config_version":"7","etag":"\"v7\"","flags":{"native_home":true},"experiments":{
      "home_layout":{"variant_key":"native","payload":{},"experiment_id":"33333333-3333-4333-8333-333333333333","subject_kind":"device","bucketing_version":1,"assignment_revision":"7"}}}}
    """#

    override func setUp() {
        super.setUp()
        SharedSDKStorage.clear()
        TeardownFlushes.install()
    }

    override func tearDown() async throws {
        await TeardownFlushes.drain(context: name)
        SharedSDKStorage.clear()
        try await super.tearDown()
    }

    private func seedCache(ageHours: Double) throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: SharedSDKStorage.suite))
        defaults.set(Data(Self.body.utf8), forKey: SharedSDKStorage.slot(StorageKeys.sdkConfig))
        defaults.set(String(Self.launch.timeIntervalSince1970 - ageHours * Self.hour),
                     forKey: SharedSDKStorage.slot(StorageKeys.sdkConfigCachedAt))
    }

    private func makeConfig(events: LockedBox<[(String, [String: Any]?)]>? = nil) -> SheepitConfig {
        SheepitConfig(
            apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64),
            apiUrl: "https://stub.invalid",
            flushInterval: 3600,
            configRefreshInterval: 3600,
            retryAttempts: 1,
            onEvent: events.map { box in { name, properties in box.mutate { $0.append((name, properties)) } } },
            // Real crash handlers in the test process crash a later test with signal 11.
            crashes: CrashConfig(enabled: false))
    }

    private func makeClient(_ config: SheepitConfig, clock: LockedBox<Date>) -> SheepitClient {
        SheepitClient.createForTesting(config: config, now: { clock.get() },
                                       urlProtocolClasses: [OfflineURLProtocol.self])
    }

    /// For what still happens after `createForTesting` returns (exposure events). The launch cache
    /// itself is applied before it returns (`ConfigSync.applyLaunchCache()`).
    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private func properties(of event: String, in events: LockedBox<[(String, [String: Any]?)]>) -> [String: Any]? {
        events.get().last { $0.0 == event }?.1 ?? nil
    }

    // MARK: - status() and exposures

    /// Offline, 30 hours after the last fetch: flags keep their cached values, `status()` reports
    /// the cache and its age, and both exposure events say so.
    func testAnOfflineLaunchOnA30HourCacheReportsItsAgeAndStampsExposures() async throws {
        try seedCache(ageHours: 30)
        let events = LockedBox<[(String, [String: Any]?)]>([])
        let clock = LockedBox(Self.launch)
        let client = makeClient(makeConfig(events: events), clock: clock)
        defer { client.destroy() }
        let loaded = await waitUntil { client.status().configFreshness != nil }
        XCTAssertTrue(loaded, "a 30 h cache was not applied")

        XCTAssertEqual(client.flag("native_home", default: .bool(false)), .bool(true))
        XCTAssertEqual(client.experiment("home_layout").variant, "native")

        let freshness = try XCTUnwrap(client.status().configFreshness)
        XCTAssertEqual(freshness.source, .cache)
        XCTAssertEqual(freshness.age, 30 * Self.hour, accuracy: 0.001)
        XCTAssertTrue(freshness.isStale)
        XCTAssertEqual(freshness.fetchedAt, Self.launch.addingTimeInterval(-30 * Self.hour))

        for event in ["$flag_exposure", "$experiment_exposure"] {
            let props = try XCTUnwrap(properties(of: event, in: events), "\(event) was not tracked")
            XCTAssertEqual(props["config_source"] as? String, "cache", event)
            XCTAssertEqual(props["config_age_ms"] as? Int, 108_000_000, event)
        }

        clock.set(Self.launch.addingTimeInterval(Self.hour))
        XCTAssertEqual(try XCTUnwrap(client.status().configFreshness).age, 31 * Self.hour, accuracy: 0.001,
                       "the age is measured when status() is called")
    }

    func testResetClearsTheReportedFreshness() async throws {
        try seedCache(ageHours: 30)
        let client = makeClient(makeConfig(), clock: LockedBox(Self.launch))
        defer { client.destroy() }
        let loaded = await waitUntil { client.status().configFreshness != nil }
        XCTAssertTrue(loaded, "precondition: the cache was applied")

        client.reset()

        XCTAssertNil(client.status().configFreshness)
        XCTAssertEqual(client.flag("native_home", default: .bool(false)), .bool(false))
    }

    func testNothingCachedReportsNoFreshness() async throws {
        let client = makeClient(makeConfig(), clock: LockedBox(Self.launch))
        defer { client.destroy() }
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertNil(client.status().configFreshness)
    }

    func testAnInertClientReportsNoFreshness() async throws {
        try seedCache(ageHours: 1)
        let client = SheepitClient.createForTesting(
            config: SheepitConfig(apiKey: "not-a-key", apiUrl: "https://stub.invalid", crashes: CrashConfig(enabled: false)),
            now: { Self.launch }, urlProtocolClasses: [OfflineURLProtocol.self])
        defer { client.destroy() }
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertNil(client.status().configFreshness)
    }

    // MARK: - Validation

    func testTheDefaultsAreTwentyFourHoursAndNoOfflineLimit() {
        let config = SheepitConfig(apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64))
        XCTAssertEqual(config.configStaleAfter, 86_400)
        XCTAssertEqual(config.configOfflineMaxAge, TimeInterval.infinity)
        XCTAssertFalse(CachedConfigLimits.default.hasOfflineLimit)
        XCTAssertEqual(config.configStaleAfter, SDKDefaults.configStaleAfter, "the init default drifted from SDKDefaults")
        XCTAssertEqual(config.configOfflineMaxAge, SDKDefaults.configOfflineMaxAge, "the init default drifted from SDKDefaults")
    }

    func testAnInvalidLimitFallsBackToItsDefault() {
        for bad: TimeInterval in [.nan, -.infinity, 0, -1] {
            let limits = CachedConfigLimits(staleAfter: bad, offlineMaxAge: bad)
            XCTAssertEqual(limits, .default, "\(bad)")
            XCTAssertEqual(limits.issues.count, 2, "\(bad)")
        }
        // `.infinity` is valid for both (sdk-js parity): no offline limit, never stale by age.
        let infinite = CachedConfigLimits(staleAfter: .infinity, offlineMaxAge: .infinity)
        XCTAssertEqual(infinite.staleAfter, .infinity)
        XCTAssertEqual(infinite.offlineMaxAge, .infinity)
        XCTAssertEqual(infinite.issues, [])
        // A finite offline limit still lowers an infinite stale limit to it.
        let bounded = CachedConfigLimits(staleAfter: .infinity, offlineMaxAge: 3600)
        XCTAssertEqual(bounded.staleAfter, 3600)
    }

    /// `configStaleAfter = .infinity`: a 30-day cache is applied and NOT reported stale.
    func testAnInfiniteStaleLimitNeverReportsStaleByAge() async throws {
        try seedCache(ageHours: 30 * 24)
        var config = makeConfig()
        config.configStaleAfter = .infinity
        let client = makeClient(config, clock: LockedBox(Self.launch))
        defer { client.destroy() }

        let freshness = try XCTUnwrap(client.status().configFreshness)
        XCTAssertEqual(freshness.source, .cache)
        XCTAssertFalse(freshness.isStale, "an infinite configStaleAfter reported a cache stale by age")
    }

    /// A shorter offline limit is a request for less retention: `configStaleAfter` comes down to it.
    func testAnOfflineLimitBelowTheStaleLimitLowersTheStaleLimit() {
        let limits = CachedConfigLimits(staleAfter: 86_400, offlineMaxAge: 3600)
        XCTAssertEqual(limits.offlineMaxAge, 3600)
        XCTAssertEqual(limits.staleAfter, 3600)
        XCTAssertEqual(limits.issues.count, 1)

        let config = SheepitConfig(apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64), configOfflineMaxAge: 3600)
        XCTAssertEqual(config.configStaleAfter, 3600)
    }

    /// 🔴 Both limits are public `var`s: a mutation after init bypasses the initializer's
    /// validation, so the client validates again. A finite limit set after init is honoured.
    func testAMutatedFiniteOfflineLimitIsHonouredByTheClient() async throws {
        try seedCache(ageHours: 10 * 24)
        var config = makeConfig()
        config.configOfflineMaxAge = 7 * 24 * Self.hour
        let client = makeClient(config, clock: LockedBox(Self.launch))
        defer { client.destroy() }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: SharedSDKStorage.suite))

        XCTAssertNil(defaults.data(forKey: SharedSDKStorage.slot(StorageKeys.sdkConfig)),
                     "a host-set 7-day limit kept a 10-day cache on disk")
        XCTAssertNil(client.status().configFreshness)
        XCTAssertEqual(client.flag("native_home", default: .bool(false)), .bool(false))
    }

    /// A mutated NaN falls back to the default, which is no limit: the 10-day cache is applied.
    func testAMutatedNaNOfflineLimitFallsBackToNoLimit() async throws {
        try seedCache(ageHours: 10 * 24)
        var config = makeConfig()
        config.configOfflineMaxAge = .nan
        let client = makeClient(config, clock: LockedBox(Self.launch))
        defer { client.destroy() }

        XCTAssertEqual(client.flag("native_home", default: .bool(false)), .bool(true))
        XCTAssertEqual(client.status().configFreshness?.isStale, true)
    }
}
