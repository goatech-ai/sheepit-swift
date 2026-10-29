import XCTest
@testable import SheepitKit

/// 0.6-C: sessions start only in the foreground. iOS launches an app with no UI for a silent
/// push or a background refresh task; such a launch used to mint and announce a session, and
/// every background `track()` extended it. The macOS test host has no `UIApplication`, so each
/// test passes an `AppForegroundState` that tracks state, which is what iOS and tvOS run.
///
/// 🔴 A live client pins `apiUrl` at the stub host and disables crash capture; see
/// `SessionStartEmissionTests` for why.
final class ForegroundSessionTests: XCTestCase {
    private let suiteName = "ai.goatech.sdk"
    private var defaults: UserDefaults { UserDefaults(suiteName: suiteName)! }

    /// Also clears what makes `reset()` rotate the device. An earlier test that identified a
    /// user leaves the device "maybe bound"; `reset()` then rotates it against the stub host,
    /// and `handleWillEnterForeground()` waits on that rotation for good (it hung the full suite).
    private func clearStoredSession() {
        for key in [StorageKeys.sessionId, StorageKeys.sessionLastSeen, StorageKeys.serverHeldUser,
                    StorageKeys.identity, StorageKeys.deviceBindAttempted] {
            SharedSDKStorage.remove(key, from: defaults)
        }
    }

    override func setUp() {
        super.setUp()
        clearStoredSession()
    }

    override func tearDown() {
        clearStoredSession()
        super.tearDown()
    }

    private func seedSession(_ id: String, lastSeen: Date) {
        defaults.set(id, forKey: StorageKeys.sessionId)
        defaults.set(String(lastSeen.timeIntervalSince1970), forKey: StorageKeys.sessionLastSeen)
    }

    private var storedLastSeen: String? { defaults.string(forKey: StorageKeys.sessionLastSeen) }

    private func makeClient(
        clock: Clock,
        launchedInBackground: Bool,
        recorder: Recorder
    ) -> SheepitClient {
        SheepitClient.createForTesting(
            config: SheepitConfig(
                apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))",
                apiUrl: "https://stub.invalid",
                onEvent: { name, _ in recorder.record(name) },
                crashes: CrashConfig(enabled: false)
            ),
            now: { clock.now },
            appState: AppForegroundState(launchedInBackground: launchedInBackground, tracksAppState: true)
        )
    }

    private func appState(_ event: EnrichedEvent) -> String? {
        event.eventProperties?["app_state"]?.value as? String
    }

    // MARK: - Background launch

    func testABackgroundLaunchWithAnExpiredSessionMintsAndAnnouncesNothing() {
        let clock = Clock(Date())
        let expiredAt = clock.now.addingTimeInterval(-2 * 3600)
        seedSession("expired-session", lastSeen: expiredAt)
        let recorder = Recorder()
        let client = makeClient(clock: clock, launchedInBackground: true, recorder: recorder)
        defer { client.destroy() }
        let lastSeenAtLaunch = storedLastSeen

        clock.advance(10)
        client.track("feed_refreshed")

        XCTAssertEqual(recorder.count("$session_start"), 0, "nobody is looking: no session begins")
        XCTAssertNil(client.context.sessionId, "no session is minted in memory")
        XCTAssertEqual(
            defaults.string(forKey: StorageKeys.sessionId), "expired-session",
            "no new session id is persisted"
        )
        XCTAssertEqual(
            storedLastSeen, lastSeenAtLaunch,
            "a background track() must not move sessionLastSeen"
        )
        let events = client.drainQueuedEventsForTesting()
        let refresh = events.first { $0.eventName == "feed_refreshed" }
        XCTAssertNotNil(refresh, "precondition: the background event was queued")
        XCTAssertNil(refresh?.sessionId, "an expired session is not joined")
        XCTAssertEqual(refresh.map(appState), "background")
    }

    func testTheFirstForegroundAfterABackgroundLaunchAnnouncesExactlyOnceAndTheNextEventJoinsIt() async {
        let clock = Clock(Date())
        seedSession("expired-session", lastSeen: clock.now.addingTimeInterval(-2 * 3600))
        let recorder = Recorder()
        let client = makeClient(clock: clock, launchedInBackground: true, recorder: recorder)
        defer { client.destroy() }
        client.track("feed_refreshed")
        XCTAssertEqual(recorder.count("$session_start"), 0, "precondition: nothing announced yet")

        // Both foreground signals arrive, as they do on an ordinary foreground.
        await client.lifecycleObserver.appWillEnterForeground()
        await client.lifecycleObserver.appDidBecomeActive()
        client.track("opened_feed")

        XCTAssertEqual(recorder.count("$session_start"), 1, "exactly one session opens")
        let session = client.context.sessionId
        XCTAssertNotNil(session)
        XCTAssertNotEqual(session, "expired-session")
        let events = client.drainQueuedEventsForTesting()
        let opened = events.first { $0.eventName == "opened_feed" }
        XCTAssertEqual(opened?.sessionId, session, "the next event joins the new session")
        XCTAssertEqual(opened.map(appState), "foreground")
        let names = recorder.names
        XCTAssertLessThan(
            names.firstIndex(of: "$session_start") ?? .max,
            names.firstIndex(of: "opened_feed") ?? .min,
            "$session_start opens the session before its first foreground event"
        )
    }

    func testDidBecomeActiveAloneOpensTheSessionWhenWillEnterForegroundNeverArrives() async {
        // Firebase 12.5.0 fixed session_start missing on the first foreground after a
        // background launch; `didBecomeActive` is the second signal for that case.
        let clock = Clock(Date())
        let recorder = Recorder()
        let client = makeClient(clock: clock, launchedInBackground: true, recorder: recorder)
        defer { client.destroy() }

        await client.lifecycleObserver.appDidBecomeActive()

        XCTAssertEqual(recorder.count("$session_start"), 1)
        XCTAssertTrue(client.appState.isForeground)
    }

    func testABackgroundEventInsideALiveSessionCarriesItWithoutExtendingIt() {
        let clock = Clock(Date())
        seedSession("live-session", lastSeen: clock.now.addingTimeInterval(-60))
        let recorder = Recorder()
        let client = makeClient(clock: clock, launchedInBackground: true, recorder: recorder)
        defer { client.destroy() }
        let lastSeenAtLaunch = storedLastSeen

        client.track("push_received")
        // 60 s before launch + 1750 s = 1810 s since last seen: past the 1800 s window,
        // unless the first background event had extended the session.
        clock.advance(1750)
        client.track("push_received_later")

        let events = client.drainQueuedEventsForTesting()
        let first = events.first { $0.eventName == "push_received" }
        let later = events.first { $0.eventName == "push_received_later" }
        XCTAssertEqual(first?.sessionId, "live-session", "a live session is joined")
        XCTAssertEqual(first.map(appState), "background")
        XCTAssertNil(later?.sessionId, "the background event did not extend the session")
        XCTAssertEqual(storedLastSeen, lastSeenAtLaunch, "sessionLastSeen is not moved")
        XCTAssertEqual(recorder.count("$session_start"), 0)
    }

    func testEnteringTheBackgroundStopsTrackFromExtendingTheSession() {
        let clock = Clock(Date())
        let recorder = Recorder()
        let client = makeClient(clock: clock, launchedInBackground: false, recorder: recorder)
        defer { client.destroy() }
        client.track("in_foreground")
        let lastSeen = storedLastSeen

        client.lifecycleObserver.appDidEnterBackground()
        clock.advance(60)
        client.track("in_background")

        XCTAssertEqual(storedLastSeen, lastSeen, "a background track() does not touch the session")
        let events = client.drainQueuedEventsForTesting()
        XCTAssertEqual(events.first { $0.eventName == "in_background" }.map(appState), "background")
    }

    func testResetInTheBackgroundDropsTheSessionAndTheFirstForegroundAnnouncesTheNextOne() async {
        // Review of #1319: `reset()` minted a session unconditionally. In the background that
        // session was never announced, and the first foreground found it live, so no
        // `$session_start` ever fired for it.
        let clock = Clock(Date())
        seedSession("live-session", lastSeen: clock.now.addingTimeInterval(-60))
        let recorder = Recorder()
        let client = makeClient(clock: clock, launchedInBackground: true, recorder: recorder)
        defer { client.destroy() }

        client.reset()

        XCTAssertNil(client.context.sessionId, "no session is minted in the background")
        XCTAssertNil(defaults.string(forKey: StorageKeys.sessionId), "the old user's session is dropped on disk")
        client.track("after_logout")
        XCTAssertNil(client.drainQueuedEventsForTesting().first { $0.eventName == "after_logout" }?.sessionId)

        await client.lifecycleObserver.appWillEnterForeground()
        XCTAssertEqual(recorder.count("$session_start"), 1, "the first foreground opens and announces it")
        XCTAssertNotNil(client.context.sessionId)
    }

    func testEveryNewSessionRefreshesTheCrashContext() async {
        // Review of #1319: the crash context was written at install and on a device-id change
        // only, so a crash after the first foreground of a background launch shipped no session.
        let clock = Clock(Date())
        let recorder = Recorder()
        let client = makeClient(clock: clock, launchedInBackground: true, recorder: recorder)
        defer { client.destroy() }
        let refreshed = SessionLog()
        client.sessionChangeHookForTesting.value = { refreshed.append($0) }

        await client.lifecycleObserver.appWillEnterForeground()
        let opened = client.context.sessionId
        XCTAssertEqual(refreshed.values, [opened ?? "?"], "the first foreground's session reaches the crash context")

        clock.advance(SDKDefaults.sessionTimeoutSeconds + 1)
        client.track("after_idle")
        XCTAssertEqual(refreshed.values.count, 2, "a rollover in track() refreshes it too")
        XCTAssertEqual(refreshed.values.last, client.context.sessionId)

        client.track("same_session")
        XCTAssertEqual(refreshed.values.count, 2, "an event inside the session does not")
    }

    // MARK: - Foreground launch

    func testAForegroundLaunchStillOpensItsSessionFirstAndTagsEventsForeground() {
        let clock = Clock(Date())
        let recorder = Recorder()
        let client = makeClient(clock: clock, launchedInBackground: false, recorder: recorder)
        defer { client.destroy() }

        client.track("first_user_event")

        XCTAssertEqual(recorder.count("$session_start"), 1)
        let names = recorder.names
        XCTAssertLessThan(
            names.firstIndex(of: "$session_start") ?? .max,
            names.firstIndex(of: "first_user_event") ?? .min
        )
        let events = client.drainQueuedEventsForTesting()
        XCTAssertTrue(events.allSatisfy { appState($0) == "foreground" }, "\(events.map(appState))")
        XCTAssertTrue(events.allSatisfy { $0.sessionId == client.context.sessionId })
    }

    // MARK: - Observer and wire

    func testDidBecomeActiveActsOnlyAfterTheBackground() async {
        let state = AppForegroundState(launchedInBackground: false, tracksAppState: true)
        let observer = AppLifecycleObserver(
            log: Logger(debug: false),
            diagnostics: nil,
            appState: state,
            onBackground: {}
        )
        let checks = Counter()
        observer.onForeground = { await checks.increment() }

        await observer.appDidBecomeActive()
        let afterReactivation = await checks.value
        XCTAssertEqual(afterReactivation, 0, "a re-activation in the foreground (Control Center, a call) does nothing")

        observer.appDidEnterBackground()
        await observer.appDidBecomeActive()
        await observer.appDidBecomeActive()
        let afterReturn = await checks.value
        XCTAssertEqual(afterReturn, 1, "the return from the background runs the session check once")
    }

    func testAnEventWithNoSessionCarriesNoSessionIdOnTheWire() throws {
        // `ingestContextSchema.session.id` is `.optional()`, not nullable: a JSON null fails the
        // whole batch, while an absent id is stored as NULL.
        let json = try JSONEncoder().encode(IngestSession(id: nil))
        XCTAssertEqual(String(data: json, encoding: .utf8), "{}")
    }

    func testATransportPayloadForASessionlessEventHasNoSessionId() throws {
        let event = EnrichedEvent(
            eventId: UUID().uuidString,
            eventName: "feed_refreshed",
            eventProperties: ["app_state": AnyCodable("background")],
            deviceId: "device-1",
            anonymousId: "anon-1",
            sessionId: nil,
            userId: nil,
            platform: "ios",
            sdkVersion: SDKDefaults.sdkVersion,
            locale: "en_US",
            timezone: "UTC",
            timestamp: SheepitClient.formatEventTimestamp(Date())
        )
        let body = try JSONEncoder().encode(Transport.buildPayload([event]))
        let json = String(data: body, encoding: .utf8) ?? ""
        XCTAssertTrue(json.contains("\"feed_refreshed\""), "precondition: the event is in the payload")
        XCTAssertFalse(json.contains("\"session\":{\"id\""), "no session id is sent: \(json)")
        XCTAssertFalse(json.contains("null"), "and never a JSON null, which fails the whole batch: \(json)")
    }

    func testAnOfflineQueueWrittenByAnOlderSDKStillDecodes() throws {
        // `OfflineQueue` decodes the whole array under one `try?`; a field that stops decoding
        // drops every queued event. Older SDKs always wrote `sessionId` as a string.
        let event = EnrichedEvent(
            eventId: "e1", eventName: "queued", eventProperties: nil, deviceId: "d", anonymousId: "a",
            sessionId: "old-session", userId: nil, platform: "ios", sdkVersion: "0.7.0",
            locale: "en_US", timezone: "UTC", timestamp: "2026-10-21T00:00:00.000Z"
        )
        let decoded = try JSONDecoder().decode([EnrichedEvent].self, from: JSONEncoder().encode([event]))
        XCTAssertEqual(decoded.first?.sessionId, "old-session")

        let sessionless = EnrichedEvent(
            eventId: "e2", eventName: "queued", eventProperties: nil, deviceId: "d", anonymousId: "a",
            sessionId: nil, userId: nil, platform: "ios", sdkVersion: "0.8.0",
            locale: "en_US", timezone: "UTC", timestamp: "2026-10-21T00:00:00.000Z"
        )
        let roundTrip = try JSONDecoder().decode([EnrichedEvent].self, from: JSONEncoder().encode([sessionless]))
        XCTAssertEqual(roundTrip.count, 1)
        XCTAssertNil(roundTrip.first?.sessionId)
    }

    func testAHostAppStatePropertyIsKept() {
        let wire = SheepitClient.withAppState(["app_state": "host-value", "n": 1], "background")
        XCTAssertEqual(wire?["app_state"]?.value as? String, "host-value")
        XCTAssertEqual(
            SheepitClient.withAppState(nil, "foreground")?["app_state"]?.value as? String,
            "foreground"
        )
        XCTAssertNil(SheepitClient.withAppState(nil, nil), "untracked platforms add nothing")
    }
}

private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ start: Date) { _now = start }
    var now: Date {
        lock.lock(); defer { lock.unlock() }; return _now
    }
    func advance(_ seconds: TimeInterval) {
        lock.lock(); defer { lock.unlock() }; _now = _now.addingTimeInterval(seconds)
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _names: [String] = []
    func record(_ name: String) {
        lock.lock(); defer { lock.unlock() }; _names.append(name)
    }
    var names: [String] {
        lock.lock(); defer { lock.unlock() }; return _names
    }
    func count(_ name: String) -> Int { names.filter { $0 == name }.count }
}

private final class SessionLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _values: [String] = []
    func append(_ value: String) {
        lock.lock(); defer { lock.unlock() }; _values.append(value)
    }
    var values: [String] {
        lock.lock(); defer { lock.unlock() }; return _values
    }
}

private actor Counter {
    private(set) var value = 0
    func increment() { value += 1 }
}
