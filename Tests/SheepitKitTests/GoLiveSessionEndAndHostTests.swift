import XCTest
@testable import SheepitKit

private final class StepClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ start: Date) { _now = start }
    var now: Date { lock.lock(); defer { lock.unlock() }; return _now }
    func advance(_ seconds: TimeInterval) { lock.lock(); defer { lock.unlock() }; _now = _now.addingTimeInterval(seconds) }
}

/// `$session_end`: one per finished session, with the session's own id, its last activity as the
/// timestamp and the time between start and that activity as `duration_ms`.
final class SessionEndTests: XCTestCase {
    private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private static let timeout = SDKDefaults.sessionTimeoutSeconds

    override func setUp() { super.setUp(); SharedSDKStorage.clear() }
    override func tearDown() { SharedSDKStorage.clear(); super.tearDown() }

    // MARK: ContextManager

    func testRolloverOwesOneEndWithTheLastActivityAsItsDuration() throws {
        let clock = StepClock(Self.t0)
        let context = ContextManager(storage: InMemoryStorage(), now: { clock.now })
        let first = try XCTUnwrap(context.sessionId)
        clock.advance(100)
        context.touchSession()
        clock.advance(Self.timeout + 1)

        XCTAssertTrue(context.rolloverIfExpired())

        let ended = try XCTUnwrap(context.takeEndedSession())
        XCTAssertEqual(ended.id, first)
        XCTAssertEqual(ended.durationMs, 100_000)
        XCTAssertEqual(ended.endedAt, Self.t0.addingTimeInterval(100))
        XCTAssertNil(context.takeEndedSession(), "announced once")
    }

    func testAnInsideTheWindowResumeEndsNothing() {
        let clock = StepClock(Self.t0)
        let context = ContextManager(storage: InMemoryStorage(), now: { clock.now })
        clock.advance(Self.timeout - 1)
        XCTAssertFalse(context.rolloverIfExpired())
        XCTAssertNil(context.takeEndedSession())
    }

    func testLeavingTheForegroundExtendsALiveSessionButNeverRevivesAnExpiredOne() throws {
        let clock = StepClock(Self.t0)
        let context = ContextManager(storage: InMemoryStorage(), now: { clock.now })
        clock.advance(500)
        context.touchSessionIfLive()
        clock.advance(Self.timeout + 1)
        context.touchSessionIfLive()
        context.rolloverIfExpired()
        XCTAssertEqual(try XCTUnwrap(context.takeEndedSession()).durationMs, 500_000)
    }

    func testASessionThatAgedOutWhileTheProcessWasDeadIsEndedAtItsLastActivity() throws {
        let storage = InMemoryStorage()
        storage.set("old", forKey: StorageKeys.sessionId)
        storage.set(String(Self.t0.timeIntervalSince1970 + 60), forKey: StorageKeys.sessionLastSeen)
        storage.set(String(Self.t0.timeIntervalSince1970), forKey: StorageKeys.sessionStartedAt)
        storage.set("1.0", forKey: StorageKeys.sessionAppVersion)
        storage.set("7", forKey: StorageKeys.sessionAppBuild)
        let context = ContextManager(storage: storage, now: { Self.t0.addingTimeInterval(Self.timeout * 3) })

        let ended = try XCTUnwrap(context.takeEndedSession())
        XCTAssertEqual(ended.id, "old")
        XCTAssertEqual(ended.durationMs, 60_000)
        // A relaunch before anything stored the new session must not announce it twice.
        context.markSessionEndQueued(ended.id)
        let again = ContextManager(storage: storage, now: { Self.t0.addingTimeInterval(Self.timeout * 3) })
        XCTAssertNil(again.takeEndedSession())
    }

    func testASessionStoredByAnOlderSDKHasNoStartAndSoNoEnd() {
        let storage = InMemoryStorage()
        storage.set("old", forKey: StorageKeys.sessionId)
        storage.set(String(Self.t0.timeIntervalSince1970), forKey: StorageKeys.sessionLastSeen)
        let context = ContextManager(storage: storage, now: { Self.t0.addingTimeInterval(Self.timeout * 3) })
        XCTAssertNil(context.takeEndedSession())
    }

    func testResetOwesTheAnnouncedOutgoingSessionItsEndButNeverEndsTheOneItOpens() throws {
        let clock = StepClock(Self.t0)
        let context = ContextManager(storage: InMemoryStorage(), now: { clock.now }, appIdentity: { ("1.0", "7") })
        let outgoing = try XCTUnwrap(context.sessionId)
        _ = context.takeNewSessionFlag()  // announced, as start() does
        clock.advance(40)
        context.touchSession()

        context.resetIdentity()

        let ended = try XCTUnwrap(context.takeEndedSession(), "a logout orphaned its $session_start")
        XCTAssertEqual(ended.id, outgoing)
        XCTAssertEqual(ended.durationMs, 40_000)
        clock.advance(Self.timeout + 1)
        context.rolloverIfExpired()
        XCTAssertNil(context.takeEndedSession(), "the session reset() opened was never announced")
    }

    func testTheEndKeepsTheAppIdentityTheSessionBeganUnder() throws {
        let clock = StepClock(Self.t0)
        let identity = LockedBox<(version: String?, build: String?)>(("1.0", "7"))
        let context = ContextManager(storage: InMemoryStorage(), now: { clock.now }, appIdentity: { identity.get() })
        identity.set(("2.0", "8"))   // the app was updated while the session sat idle
        clock.advance(Self.timeout + 1)
        context.rolloverIfExpired()
        let ended = try XCTUnwrap(context.takeEndedSession())
        XCTAssertEqual(ended.appVersion, "1.0")
        XCTAssertEqual(ended.appBuild, "7")
    }

    func testAPoisonedStoredStartNeverTrapsAndEndsNothing() {
        for poison in ["nan", "inf", "-inf", "1e300", "-5", "0"] {
            let storage = InMemoryStorage()
            storage.set("old", forKey: StorageKeys.sessionId)
            storage.set(String(Self.t0.timeIntervalSince1970), forKey: StorageKeys.sessionLastSeen)
            storage.set(poison, forKey: StorageKeys.sessionStartedAt)
            storage.set("1.0", forKey: StorageKeys.sessionAppVersion)
            storage.set("7", forKey: StorageKeys.sessionAppBuild)
            let context = ContextManager(storage: storage, now: { Self.t0.addingTimeInterval(Self.timeout * 3) })
            XCTAssertNil(context.takeEndedSession(), poison)
        }
        let huge = EndedSession(id: "s", startedAt: Date(timeIntervalSince1970: 1), endedAt: Date(timeIntervalSince1970: 3e9))
        XCTAssertGreaterThan(huge.durationMs, 0)
        XCTAssertEqual(EndedSession(id: "s", startedAt: Self.t0, endedAt: Date(timeIntervalSince1970: .nan)).durationMs, 0)
    }

    func testAPendingEndSurvivesAResetAndAFreshlyMintedSessionIsNotEnded() throws {
        let clock = StepClock(Self.t0)
        let context = ContextManager(storage: InMemoryStorage(), now: { clock.now }, appIdentity: { ("1.0", "7") })
        let first = try XCTUnwrap(context.sessionId)
        clock.advance(Self.timeout + 1)
        context.rolloverIfExpired()
        context.resetIdentity()
        XCTAssertEqual(context.takeEndedSession()?.id, first)
    }

    func testANegativeSpanReportsZero() {
        let ended = EndedSession(id: "s", startedAt: Self.t0, endedAt: Self.t0.addingTimeInterval(-5))
        XCTAssertEqual(ended.durationMs, 0)
    }

    // MARK: Client

    func testOneEndAcrossBackgroundAndForegroundWithTheSessionsOwnIdAndTimestamp() throws {
        let clock = StepClock(Self.t0)
        let client = SheepitClient.createForTesting(
            config: SheepitConfig(
                apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64),
                apiUrl: "https://stub.invalid",
                flushInterval: 3600,
                crashes: CrashConfig(enabled: false)),
            now: { clock.now },
            appState: AppForegroundState(launchedInBackground: false, tracksAppState: true))
        defer { client.destroy() }
        let first = try XCTUnwrap(client.context.sessionId)

        clock.advance(120)
        client.track("a")
        clock.advance(30)
        client.lifecycleObserver.appDidEnterBackground()
        clock.advance(Self.timeout + 60)
        client.lifecycleObserver.appState.markForeground()
        client.track("b")
        client.track("c")

        let events = client.drainQueuedEventsForTesting()
        let ends = events.filter { $0.eventName == "$session_end" }
        XCTAssertEqual(ends.count, 1)
        let end = try XCTUnwrap(ends.first)
        XCTAssertEqual(end.sessionId, first)
        XCTAssertEqual(end.eventProperties?["duration_ms"]?.value as? Int, 150_000)
        let stamp = try XCTUnwrap(ISO8601DateFormatter.fractional.date(from: end.timestamp))
        XCTAssertEqual(stamp.timeIntervalSince1970, Self.t0.timeIntervalSince1970 + 150, accuracy: 0.001)
        let names = events.map(\.eventName)
        let endIndex = try XCTUnwrap(names.firstIndex(of: "$session_end"))
        let secondStart = try XCTUnwrap(names.lastIndex(of: "$session_start"))
        XCTAssertLessThan(endIndex, secondStart, "the end precedes its successor's start")
        XCTAssertNotEqual(events.first { $0.eventName == "b" }?.sessionId, first)
    }
}

private extension ISO8601DateFormatter {
    static var fractional: ISO8601DateFormatter {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }
}

final class ScreenAppearanceGateTests: XCTestCase {
    func testARepeatedAppearAloneTracksOnce() {
        let gate = ScreenAppearanceGate()
        XCTAssertTrue(gate.appeared())
        XCTAssertFalse(gate.appeared(), "a re-render's second onAppear")
        XCTAssertFalse(gate.appeared())
    }

    func testLeavingAndReturningTracksAgain() {
        let gate = ScreenAppearanceGate()
        XCTAssertTrue(gate.appeared())
        gate.disappeared()
        XCTAssertTrue(gate.appeared())
    }

    func testDisappearingWithoutAnAppearanceIsHarmless() {
        let gate = ScreenAppearanceGate()
        gate.disappeared()
        XCTAssertTrue(gate.appeared())
    }
}

final class DefaultHostTests: XCTestCase {
    private let key = "lp_pub_tst_" + String(repeating: "a", count: 64)

    func testAConfigWithNoApiUrlIsOnTheHostedDefault() {
        XCTAssertTrue(SheepitConfig(apiKey: key).isUsingDefaultHost)
        XCTAssertTrue(SheepitConfig(apiKey: key, apiUrl: "HTTPS://API.sheepit.ai/_x").isUsingDefaultHost)
    }

    func testAnInfoPlistWithoutSheepitAPIURLIsOnTheHostedDefault() {
        XCTAssertTrue(SheepitConfig(infoDictionary: ["SheepitAPIKey": key]).isUsingDefaultHost)
        XCTAssertFalse(SheepitConfig(infoDictionary: ["SheepitAPIKey": key, "SheepitAPIURL": "sheepit.example.com"]).isUsingDefaultHost)
    }

    func testASelfHostedOrEmptyUrlIsNot() {
        XCTAssertFalse(SheepitConfig(apiKey: key, apiUrl: "https://sheepit.example.com").isUsingDefaultHost)
        XCTAssertFalse(SheepitConfig(apiKey: key, apiUrl: "http://sheepit_api:3000").isUsingDefaultHost)
        XCTAssertFalse(SheepitConfig(apiKey: key, apiUrl: "").isUsingDefaultHost)
    }

    func testBothHostedDomainsCountAsHosted() {
        XCTAssertTrue(SheepitConfig(apiKey: key, apiUrl: "https://api.goatech.ai").isUsingDefaultHost)
    }

    func testOnlyAnAbsentPlistKeyProducesTheFaultNotice() {
        XCTAssertNotNil(SheepitConfig(infoDictionary: ["SheepitAPIKey": key]).activeInfoPlistNotice)
        XCTAssertNotNil(SheepitConfig(apiKey: key).hostedDefaultNotice, "apiUrl omitted in code is as silent as a missing plist key")
        XCTAssertNil(SheepitConfig(apiKey: key, apiUrl: SheepitConfig.defaultAPIUrl).hostedDefaultNotice, "naming the hosted API is a choice")
        XCTAssertNil(SheepitConfig(apiKey: key, apiUrl: "https://sheepit.example.com").hostedDefaultNotice)
        XCTAssertNil(SheepitConfig(infoDictionary: ["SheepitAPIKey": key, "SheepitAPIURL": "api.sheepit.ai"]).hostedDefaultNotice)
    }

    func testAnUnderscoreHostParsesAndIsAccepted() {
        XCTAssertEqual(URLComponents(string: "http://sheepit_api:3000")?.host, "sheepit_api")
        XCTAssertNil(SheepitClient.apiURLRejectionReason(for: "http://sheepit_api:3000"))
    }
}

/// The cached `/v1/config` body is decoded on the launch thread and no longer expires, so its size
/// is bounded both ways.
final class ConfigCacheSizeCapTests: XCTestCase {
    override func setUp() { super.setUp(); AttributionCaptureProtocol.reset() }
    override func tearDown() { AttributionCaptureProtocol.reset(); super.tearDown() }

    private func body(padding: Int) -> String {
        #"{"data":{"config_version":"7","etag":"\"v7\"","flags":{"pad":"\#(String(repeating: "x", count: padding))"},"experiments":{}}}"#
    }

    func testAnOversizeBodyOnDiskIsDroppedUnread() {
        let storage = InMemoryStorage()
        storage.set(Data(body(padding: SDKDefaults.configCacheMaxBytes).utf8), forKey: StorageKeys.sdkConfig)
        storage.set("1800000000", forKey: StorageKeys.sdkConfigCachedAt)
        guard case .drop(.oversize) = LaunchConfigCache.evaluate(
            storage: storage, limits: .default, now: Date(timeIntervalSince1970: 1_800_000_100), deviceId: "d")
        else { return XCTFail("an oversize cache was decoded") }

        storage.set(Data(body(padding: 100).utf8), forKey: StorageKeys.sdkConfig)
        guard case .apply = LaunchConfigCache.evaluate(
            storage: storage, limits: .default, now: Date(timeIntervalSince1970: 1_800_000_100), deviceId: "d")
        else { return XCTFail("a small cache must still apply") }
    }

    private func sync(storage: StorageProvider, bus: DiagnosticBus, applied: LockedBox<Int>) -> ConfigSync {
        ConfigSync(
            http: HTTPClient(
                config: SheepitConfig(apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64),
                                      apiUrl: "https://stub.invalid", retryAttempts: 1),
                log: Logger(debug: false),
                urlProtocolClasses: [AttributionCaptureProtocol.self]),
            storage: storage,
            refreshInterval: 3600,
            log: Logger(debug: false),
            diagnostics: bus,
            identityProvider: { (.fetchedUnder(nil), 0) },
            onConfig: { _, _, _ in applied.mutate { $0 += 1 } })
    }

    func testAnOversizeServerBodyIsAppliedButNotPersistedAndTheOlderCacheIsRemoved() async {
        let storage = InMemoryStorage()
        storage.set(Data(body(padding: 10).utf8), forKey: StorageKeys.sdkConfig)
        storage.set("1", forKey: StorageKeys.sdkConfigCachedAt)
        let bus = DiagnosticBus()
        let applied = LockedBox(0)
        let s = sync(storage: storage, bus: bus, applied: applied)

        AttributionCaptureProtocol.serveConfig(body(padding: SDKDefaults.configCacheMaxBytes))
        await s.refresh(deviceId: "device-1")

        XCTAssertEqual(applied.get(), 1, "the live app still gets the config")
        XCTAssertNil(storage.data(forKey: StorageKeys.sdkConfig))
        XCTAssertNil(storage.string(forKey: StorageKeys.sdkConfigCachedAt))
        XCTAssertTrue(bus.getRecentDiagnostics().contains { $0.code == "config.cache_too_large" })
    }

    func testAnUnderTheCapServerBodyIsPersisted() async {
        let storage = InMemoryStorage()
        let bus = DiagnosticBus()
        let s = sync(storage: storage, bus: bus, applied: LockedBox(0))
        AttributionCaptureProtocol.serveConfig(body(padding: 1000))
        await s.refresh(deviceId: "device-1")
        XCTAssertNotNil(storage.data(forKey: StorageKeys.sdkConfig))
        XCTAssertFalse(bus.getRecentDiagnostics().contains { $0.code == "config.cache_too_large" })
    }
}
