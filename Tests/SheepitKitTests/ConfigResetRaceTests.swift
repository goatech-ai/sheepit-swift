import XCTest
@testable import SheepitKit

/// `reset()` against config fetches (`ConfigResetGate`).
///
/// `reset()` used to wipe the cache synchronously and then send `clearCache()` to the `ConfigSync`
/// actor in a detached Task. That Task ran at an arbitrary later time: a response landing first
/// wrote the logged-out user's config back, and the Task deleted whatever was on disk when it ran,
/// including a cache written after the reset (measured: 42 µs after the next write).
final class ConfigResetRaceTests: XCTestCase {
    private static let suite = "ai.goatech.sdk"
    private static let body = #"{"data":{"config_version":"7","etag":"\"v7\"","flags":{},"experiments":{"pricing_test":{"variant_key":"treatment","payload":{}}}}}"#

    private static func clearConfigStorage() {
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        for key in [StorageKeys.sdkConfig, StorageKeys.sdkConfigCachedAt,
                    StorageKeys.sdkConfigFetchedUnder, StorageKeys.serverHeldUser, StorageKeys.identity] {
            defaults.removeObject(forKey: key)
        }
    }

    override func setUp() {
        super.setUp()
        Self.clearConfigStorage()
        AttributionCaptureProtocol.reset()
    }

    override func tearDown() {
        Self.clearConfigStorage()
        AttributionCaptureProtocol.reset()
        super.tearDown()
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    private func makeSync(storage: StorageProvider, gate: ConfigResetGate, applied: LockedBox<Int>) -> ConfigSync {
        ConfigSync(
            http: HTTPClient(
                config: SheepitConfig(apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64),
                                      apiUrl: "https://stub.invalid", retryAttempts: 1),
                log: Logger(debug: false),
                urlProtocolClasses: [AttributionCaptureProtocol.self]),
            storage: storage,
            refreshInterval: 3600,
            log: Logger(debug: false),
            resetGate: gate,
            identityProvider: { (.fetchedUnder(nil), 0) },
            onConfig: { _, _ in applied.mutate { $0 += 1 } }
        )
    }

    private func makeClient() -> SheepitClient {
        SheepitClient.createForTesting(
            config: SheepitConfig(
                apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64),
                apiUrl: "https://stub.invalid",
                flushInterval: 3600,
                configRefreshInterval: 3600,
                retryAttempts: 1,
                crashes: CrashConfig(enabled: false)),
            now: { Date() },
            urlProtocolClasses: [AttributionCaptureProtocol.self])
    }

    func testAFetchInFlightAcrossAResetWritesNothingAndAppliesNothing() async {
        let storage = InMemoryStorage()
        let gate = ConfigResetGate()
        let applied = LockedBox(0)
        AttributionCaptureProtocol.scriptConfig([(Self.body, 0.4)])
        let sync = makeSync(storage: storage, gate: gate, applied: applied)

        let inFlight = Task { await sync.refresh(deviceId: "device-1") }
        let onWire = await waitUntil { AttributionCaptureProtocol.configRequestCount >= 1 }
        XCTAssertTrue(onWire, "precondition: the fetch is on the wire")
        // What `SheepitClient.reset()` does: bump the gate and wipe inside it.
        gate.reset {
            storage.removeObject(forKey: StorageKeys.sdkConfig)
            storage.removeObject(forKey: StorageKeys.sdkConfigCachedAt)
        }
        await inFlight.value

        XCTAssertNil(storage.data(forKey: StorageKeys.sdkConfig), "the logged-out user's body came back on disk")
        XCTAssertNil(storage.string(forKey: StorageKeys.sdkConfigCachedAt))
        XCTAssertEqual(applied.get(), 0, "the logged-out user's config was applied after reset()")
    }

    func testAnETagFromBeforeAResetIsNeverSent() async {
        let gate = ConfigResetGate()
        AttributionCaptureProtocol.serveConfig(Self.body)
        let sync = makeSync(storage: InMemoryStorage(), gate: gate, applied: LockedBox(0))

        await sync.refresh(deviceId: "device-1")
        gate.reset {}
        await sync.refresh(deviceId: "device-1")

        XCTAssertEqual(AttributionCaptureProtocol.configIfNoneMatch, [nil, nil],
                       "a pre-reset ETag 304s the next fetch against the logged-out user's body")
    }

    /// `reset()` must leave nothing queued that deletes the cache later: a newer client (or this
    /// one, after a fetch) may already have written one.
    func testResetLeavesNothingQueuedThatDeletesALaterCache() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suite))
        let client = makeClient()
        defer { client.destroy() }
        let started = await waitUntil { AttributionCaptureProtocol.configRequestCount >= 1 }
        XCTAssertTrue(started, "precondition: the start-up fetch ran, so the cache load is behind us")

        client.reset()
        defaults.set(Data("{}".utf8), forKey: StorageKeys.sdkConfig)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertNotNil(defaults.data(forKey: StorageKeys.sdkConfig),
                        "something queued by reset() deleted a cache written after it")
    }

    /// DESIGN GUARD for the wiring: on the old code the actor clear usually won this race (actors
    /// re-enter at the fetch's await), so only the synchronous gate makes it certain.
    func testAClientFetchInFlightAcrossResetWritesNothingAndAppliesNothing() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: Self.suite))
        let client = makeClient()
        defer { client.destroy() }
        let started = await waitUntil { AttributionCaptureProtocol.configRequestCount >= 1 }
        XCTAssertTrue(started, "precondition: the start-up fetch ran")
        AttributionCaptureProtocol.scriptConfig([(Self.body, 0.4)])

        let inFlight = Task { await client.refreshConfigForTesting() }
        let onWire = await waitUntil { AttributionCaptureProtocol.configRequestCount >= 2 }
        XCTAssertTrue(onWire, "precondition: the refresh is on the wire")
        client.reset()
        await inFlight.value

        XCTAssertNil(defaults.data(forKey: StorageKeys.sdkConfig))
        XCTAssertEqual(client.status().experimentCount, 0)
    }
}
