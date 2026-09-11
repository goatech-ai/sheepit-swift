import XCTest
@testable import SheepitKit

/// Coverage for the automatic `$session_start` event and the session-rollover
/// rules behind it.
///
/// Before this existed, an iOS app that launched and did nothing produced ZERO
/// events and therefore zero DAU — while `$session_start` was already the unit
/// that `end-users/summary.ts`, the retention cohorts in `insights.ts`, the
/// admin launch dashboard and ten dashboard-template widgets all count. An
/// iOS-only project rendered zeroes everywhere while appearing to work.
///
/// Coverage boundary, same as `BackgroundFlushTests`: the package's tests run
/// on macOS, where the `#if canImport(UIKit)` NOTIFICATION REGISTRATION is
/// compiled out. Nothing here proves `willEnterForegroundNotification` fires
/// on a real device — that needs an Xcode run. What IS covered: the session
/// state machine (via an injected clock), that the observer's foreground
/// action runs, and that a real client emits the event on a fresh session.
final class SessionRolloverTests: XCTestCase {
    private func makeContext(
        storage: StorageProvider = InMemoryStorage(),
        clock: TestClock
    ) -> ContextManager {
        ContextManager(storage: storage, now: { clock.now })
    }

    private var beyondTimeout: TimeInterval { SDKDefaults.sessionTimeoutSeconds + 1 }
    private var withinTimeout: TimeInterval { SDKDefaults.sessionTimeoutSeconds - 1 }

    // MARK: - The init-time flag

    func testColdStartWithNoStoredSessionOwesASessionStart() {
        let clock = TestClock(Date())
        let context = makeContext(clock: clock)

        XCTAssertTrue(
            context.takeNewSessionFlag(),
            "a first-ever launch mints a session, so $session_start is owed"
        )
    }

    func testTheNewSessionFlagIsConsumedExactlyOnce() {
        let clock = TestClock(Date())
        let context = makeContext(clock: clock)

        XCTAssertTrue(context.takeNewSessionFlag())
        XCTAssertFalse(
            context.takeNewSessionFlag(),
            "the flag must latch off so $session_start cannot double-fire for one session"
        )
    }

    func testResumingAFreshStoredSessionOwesNothing() {
        let clock = TestClock(Date())
        let storage = InMemoryStorage()
        storage.set("stored-session", forKey: StorageKeys.sessionId)
        storage.set(
            String(clock.now.addingTimeInterval(-withinTimeout).timeIntervalSince1970),
            forKey: StorageKeys.sessionLastSeen
        )

        let context = makeContext(storage: storage, clock: clock)

        XCTAssertEqual(context.sessionId, "stored-session", "a live session must be reused")
        XCTAssertFalse(
            context.takeNewSessionFlag(),
            "resuming inside the idle window is not a new session"
        )
    }

    func testAStoredSessionThatAgedOutWhileTheProcessWasDeadOwesASessionStart() {
        let clock = TestClock(Date())
        let storage = InMemoryStorage()
        storage.set("stale-session", forKey: StorageKeys.sessionId)
        storage.set(
            String(clock.now.addingTimeInterval(-beyondTimeout).timeIntervalSince1970),
            forKey: StorageKeys.sessionLastSeen
        )

        let context = makeContext(storage: storage, clock: clock)

        XCTAssertNotEqual(context.sessionId, "stale-session", "an expired session must not be reused")
        XCTAssertTrue(context.takeNewSessionFlag())
    }

    // MARK: - touchSession() is bump-only

    func testTouchSessionNeverRotatesTheSessionIdEvenPastTheIdleWindow() {
        let clock = TestClock(Date())
        let context = makeContext(clock: clock)
        _ = context.takeNewSessionFlag()
        let original = context.sessionId

        clock.advance(beyondTimeout)
        context.touchSession()

        XCTAssertEqual(
            context.sessionId,
            original,
            """
            touchSession() must be bump-only, matching sdk-js context.ts:175. \
            Rotating here mints a session boundary that nothing announces, and \
            can land the boundary mid-batch — Transport stamps one batch-level \
            session id from events[0], so later events would be filed under the \
            previous session.
            """
        )
        XCTAssertFalse(
            context.takeNewSessionFlag(),
            "a bump is not a boundary, so it must not owe a $session_start"
        )
    }

    func testTouchSessionKeepsTheSessionAliveSoItDoesNotExpire() {
        let clock = TestClock(Date())
        let context = makeContext(clock: clock)

        clock.advance(withinTimeout)
        context.touchSession()
        clock.advance(withinTimeout)

        XCTAssertFalse(
            context.isSessionExpired,
            "activity inside the window must slide the deadline forward"
        )
    }

    // MARK: - rolloverIfExpired()

    func testRolloverMintsANewSessionAndOwesAStartWhenIdleTooLong() {
        let clock = TestClock(Date())
        let context = makeContext(clock: clock)
        _ = context.takeNewSessionFlag()
        let original = context.sessionId

        clock.advance(beyondTimeout)
        context.rolloverIfExpired()

        XCTAssertNotEqual(context.sessionId, original)
        XCTAssertTrue(context.takeNewSessionFlag(), "a real boundary owes a $session_start")
    }

    func testRolloverIsANoOpInsideTheIdleWindow() {
        let clock = TestClock(Date())
        let context = makeContext(clock: clock)
        _ = context.takeNewSessionFlag()
        let original = context.sessionId

        clock.advance(withinTimeout)
        context.rolloverIfExpired()

        XCTAssertEqual(context.sessionId, original, "a warm resume continues the same session")
        XCTAssertFalse(context.takeNewSessionFlag())
    }

    func testRolloverPersistsTheNewSessionSoTheNextLaunchResumesIt() {
        let clock = TestClock(Date())
        let storage = InMemoryStorage()
        let context = makeContext(storage: storage, clock: clock)

        clock.advance(beyondTimeout)
        context.rolloverIfExpired()

        XCTAssertEqual(
            storage.string(forKey: StorageKeys.sessionId),
            context.sessionId,
            "the rolled-over id must reach storage, or the next launch resurrects the old one"
        )
    }

    func testResetIdentityMintsASessionWithoutOwingAStart() {
        let clock = TestClock(Date())
        let context = makeContext(clock: clock)
        _ = context.takeNewSessionFlag()
        let original = context.sessionId

        context.resetIdentity()

        XCTAssertNotEqual(context.sessionId, original, "reset() rotates the session, as on web")
        XCTAssertFalse(
            context.takeNewSessionFlag(),
            """
            reset() must not announce a session. sdk-js rotates the id in \
            resetIdentity() too and emits nothing — counting a logout as a \
            session would inflate DAU.
            """
        )
    }
}

/// The foreground trigger, at the seam the macOS test host can reach.
final class ForegroundSessionCheckTests: XCTestCase {
    func testForegroundCheckRunsTheInjectedAction() async {
        let ran = ActorFlag()
        let observer = AppLifecycleObserver(
            log: Logger(debug: false),
            diagnostics: nil,
            onBackground: {}
        )
        observer.onForeground = { await ran.set() }

        await observer.performForegroundCheck()

        let didRun = await ran.value
        XCTAssertTrue(didRun, "returning to the foreground must run the session check")
    }

    func testForegroundCheckEmitsALifecycleDiagnostic() async {
        let bus = DiagnosticBus()
        let observer = AppLifecycleObserver(
            log: Logger(debug: false),
            diagnostics: bus,
            onBackground: {}
        )

        await observer.performForegroundCheck()

        XCTAssertEqual(bus.getRecentDiagnostics().map(\.code), ["lifecycle.will_enter_foreground"])
    }

    func testForegroundCheckWithNoActionAssignedIsHarmless() async {
        let observer = AppLifecycleObserver(
            log: Logger(debug: false),
            diagnostics: nil,
            onBackground: {}
        )

        await observer.performForegroundCheck()
    }

    /// A foreground return after a long suspension must announce the new
    /// session, and the announcement must carry the NEW session id — not the
    /// one the app was suspended on.
    func testForegroundAfterALongSuspensionAnnouncesTheNewSessionId() async {
        let clock = TestClock(Date())
        let context = ContextManager(storage: InMemoryStorage(), now: { clock.now })
        _ = context.takeNewSessionFlag()  // consume the cold-start mint
        let suspendedOn = context.sessionId

        let announced = SessionRecorder()
        let observer = AppLifecycleObserver(
            log: Logger(debug: false),
            diagnostics: nil,
            onBackground: {}
        )
        observer.onForeground = {
            context.rolloverIfExpired()
            if context.takeNewSessionFlag() {
                await announced.record(context.sessionId)
            }
        }

        // The app sat suspended past the idle window.
        clock.advance(SDKDefaults.sessionTimeoutSeconds + 1)
        await observer.performForegroundCheck()

        let recorded = await announced.recorded
        XCTAssertNotNil(recorded, "a suspension longer than the idle window opens a new session")
        XCTAssertEqual(
            recorded,
            context.sessionId,
            "the announcement must carry the new session id, not the suspended one"
        )
        XCTAssertNotEqual(recorded, suspendedOn)
    }

    /// A quick app switch is not a new session — the common case, and the one
    /// that would flood DAU with duplicates if it were mishandled.
    func testAShortForegroundRoundTripDoesNotAnnounceASession() async {
        let clock = TestClock(Date())
        let context = ContextManager(storage: InMemoryStorage(), now: { clock.now })
        _ = context.takeNewSessionFlag()
        let original = context.sessionId

        let announced = SessionRecorder()
        let observer = AppLifecycleObserver(
            log: Logger(debug: false),
            diagnostics: nil,
            onBackground: {}
        )
        observer.onForeground = {
            context.rolloverIfExpired()
            if context.takeNewSessionFlag() {
                await announced.record(context.sessionId)
            }
        }

        clock.advance(SDKDefaults.sessionTimeoutSeconds - 1)
        await observer.performForegroundCheck()

        let recorded = await announced.recorded
        XCTAssertNil(recorded, "a warm resume inside the window continues the same session")
        XCTAssertEqual(context.sessionId, original)
    }
}

/// A clock the test moves by hand. `ContextManager` takes this so session
/// rollover can be exercised without waiting out the 30-minute idle window —
/// the package has no other time seam, so before this the rule was untestable.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ start: Date) { self._now = start }
    var now: Date {
        lock.lock(); defer { lock.unlock() }; return _now
    }
    func advance(_ interval: TimeInterval) {
        lock.lock(); defer { lock.unlock() }; _now = _now.addingTimeInterval(interval)
    }
}

private actor ActorFlag {
    private(set) var value = false
    func set() { value = true }
}

private actor SessionRecorder {
    private(set) var recorded: String?
    func record(_ id: String) { recorded = id }
}

/// End-to-end: a real client on a fresh session must emit `$session_start`
/// without the host app calling `track()` at all.
///
/// 🔴 A live client MUST pin `apiUrl` at the stub host and disable crash
/// capture. Otherwise it installs crash-reporter signal handlers into the test
/// process and fires device-registration traffic at the production API, which
/// crashed the suite ~20-30% of runs — in whichever file happened to run next.
/// See `SecretKeyGuardTests.swift:29-34`.
final class SessionStartEmissionTests: XCTestCase {
    private let suiteName = "ai.goatech.sdk"

    /// `SheepitClient` hardcodes its `UserDefaults` suite, so a session left
    /// behind by an earlier run (or by another test) would be resumed and no
    /// `$session_start` would be owed. Clear the two session keys around each
    /// test rather than the whole domain, which holds the device identity.
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

    func testAFreshSessionEmitsSessionStartWithNoHostAppTrackCall() {
        let recorder = EventNameRecorder()
        let client = SheepitClient.create(
            config: SheepitConfig(
                apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))",
                apiUrl: "https://stub.invalid",
                onEvent: { name, _ in recorder.record(name) },
                crashes: CrashConfig(enabled: false)
            )
        )
        defer { client.destroy() }

        XCTAssertEqual(
            recorder.names.filter { $0 == "$session_start" }.count,
            1,
            """
            An app that launches and does nothing must still produce a session. \
            $session_start is the DAU/MAU unit and the retention-cohort anchor; \
            without it an iOS-only project renders zeroes across every dashboard.
            """
        )
    }

    func testSessionStartCarriesOnlyTheIsFirstSessionProperty() {
        let recorder = EventNameRecorder()
        let client = SheepitClient.create(
            config: SheepitConfig(
                apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))",
                apiUrl: "https://stub.invalid",
                onEvent: { name, props in recorder.record(name, props) },
                crashes: CrashConfig(enabled: false)
            )
        )
        defer { client.destroy() }

        // Assert the event was recorded FIRST. Without this the property
        // assertion below is vacuous — an absent event also has no properties,
        // so the test would stay green with the whole feature removed.
        XCTAssertTrue(
            recorder.wasRecorded("$session_start"),
            "precondition: $session_start must have been emitted"
        )

        XCTAssertTrue(
            recorder.hasProperties("$session_start"),
            "is_first_session makes the install cohort queryable without a join to $app_install"
        )
        XCTAssertNotNil(
            recorder.boolProperty("is_first_session", on: "$session_start"),
            """
            The web SDK's UTM / referrer / landing_page keys are browser-only and are \
            deliberately NOT synthesised here — they would put unusable values in the \
            columns analysts read for web. is_first_session is the one property iOS adds.
            """
        )
    }

    func testASecondClientOnTheSameLiveSessionDoesNotReAnnounceIt() {
        let first = SheepitClient.create(
            config: SheepitConfig(
                apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))",
                apiUrl: "https://stub.invalid",
                crashes: CrashConfig(enabled: false)
            )
        )
        first.destroy()

        let recorder = EventNameRecorder()
        let second = SheepitClient.create(
            config: SheepitConfig(
                apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))",
                apiUrl: "https://stub.invalid",
                onEvent: { name, _ in recorder.record(name) },
                crashes: CrashConfig(enabled: false)
            )
        )
        defer { second.destroy() }

        XCTAssertEqual(
            recorder.names.filter { $0 == "$session_start" }.count,
            0,
            "re-creating the SDK inside a live session must not mint a second session"
        )
    }
}

/// `is_first_session` — the property `$session_start` carries (§8, "Decided without
/// escalation"). Must control `StorageKeys.deviceId` directly in the REAL `ai.goatech.sdk`
/// suite: `didMintDeviceId` is fixed at `ContextManager.init` from whatever that key held
/// at construction time, and `SheepitClient` always uses that real suite, never
/// `InMemoryStorage` — the same reason `BeginWorkDiskAndDestroyRaceTests` seeds/restores
/// keys directly rather than injecting a test double.
final class IsFirstSessionPropertyTests: XCTestCase {
    private let suiteName = "ai.goatech.sdk"

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

    func testAGenuinelyFreshDeviceReportsIsFirstSessionTrue() {
        let defaults = UserDefaults(suiteName: suiteName)!
        let originalDeviceId = defaults.string(forKey: StorageKeys.deviceId)
        defer {
            if let originalDeviceId {
                defaults.set(originalDeviceId, forKey: StorageKeys.deviceId)
            } else {
                defaults.removeObject(forKey: StorageKeys.deviceId)
            }
        }
        defaults.removeObject(forKey: StorageKeys.deviceId) // forces didMintDeviceId == true

        let recorder = EventNameRecorder()
        let client = SheepitClient.create(
            config: SheepitConfig(
                apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))",
                apiUrl: "https://stub.invalid",
                onEvent: { name, props in recorder.record(name, props) },
                crashes: CrashConfig(enabled: false)
            )
        )
        defer { client.destroy() }

        XCTAssertEqual(
            recorder.boolProperty("is_first_session", on: "$session_start"),
            true,
            "a device that just minted its id for the first time is on its first session"
        )
    }

    func testAnExistingDeviceReportsIsFirstSessionFalse() {
        let defaults = UserDefaults(suiteName: suiteName)!
        let originalDeviceId = defaults.string(forKey: StorageKeys.deviceId)
        defer {
            if let originalDeviceId {
                defaults.set(originalDeviceId, forKey: StorageKeys.deviceId)
            } else {
                defaults.removeObject(forKey: StorageKeys.deviceId)
            }
        }
        defaults.set(UUID().uuidString, forKey: StorageKeys.deviceId) // forces didMintDeviceId == false

        let recorder = EventNameRecorder()
        let client = SheepitClient.create(
            config: SheepitConfig(
                apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))",
                apiUrl: "https://stub.invalid",
                onEvent: { name, props in recorder.record(name, props) },
                crashes: CrashConfig(enabled: false)
            )
        )
        defer { client.destroy() }

        XCTAssertEqual(
            recorder.boolProperty("is_first_session", on: "$session_start"),
            false,
            """
            an install that already had a device id is not on its first session, even \
            though this IS its first $session_start under a freshly-minted session id
            """
        )
    }
}

/// `onEvent` fires on whatever thread called `track()`, so the recorder is
/// lock-guarded rather than actor-isolated (the assertions are synchronous).
/// Deliberately optional-free. An earlier version returned `[String: Any]??`
/// from a properties lookup, which compiles locally but is an ERROR under the
/// CI lane's `swift test -Xswiftc -warnings-as-errors`.
private final class EventNameRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _names: [String] = []
    private var _withProperties: Set<String> = []
    /// Last-seen properties per event name — sufficient for these tests, which never
    /// record the same name twice with properties they need to tell apart individually.
    private var _propertiesByName: [String: [String: Any]] = [:]

    func record(_ name: String, _ properties: [String: Any]? = nil) {
        lock.lock(); defer { lock.unlock() }
        _names.append(name)
        if let properties, !properties.isEmpty {
            _withProperties.insert(name)
            _propertiesByName[name] = properties
        }
    }

    var names: [String] {
        lock.lock(); defer { lock.unlock() }; return _names
    }

    func wasRecorded(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; return _names.contains(name)
    }

    func hasProperties(_ name: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; return _withProperties.contains(name)
    }

    func boolProperty(_ key: String, on name: String) -> Bool? {
        lock.lock(); defer { lock.unlock() }; return _propertiesByName[name]?[key] as? Bool
    }
}

/// A drained batch can legitimately span two sessions, and the wire format has
/// no per-event session field — `buildPayload` stamps one batch-level
/// `context.session.id` from `events[0]`. So the flush must split by session or
/// the tail of the batch is filed under the wrong one, unrecoverably.
final class SessionBatchGroupingTests: XCTestCase {
    private func event(_ name: String, session: String) -> EnrichedEvent {
        EnrichedEvent(
            eventId: UUID().uuidString,
            eventName: name,
            eventProperties: nil,
            deviceId: "device-1",
            anonymousId: "anon-1",
            sessionId: session,
            userId: nil,
            platform: "ios",
            sdkVersion: SDKDefaults.sdkVersion,
            locale: "en_US",
            timezone: "UTC",
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
    }

    func testASingleSessionStaysOneBatch() {
        let groups = Transport.groupedBySession([
            event("a", session: "s1"),
            event("b", session: "s1"),
        ])

        XCTAssertEqual(groups.count, 1, "one session must not be split into several requests")
        XCTAssertEqual(groups[0].map(\.eventName), ["a", "b"])
    }

    func testAnEmptyBatchProducesNoGroups() {
        XCTAssertTrue(Transport.groupedBySession([]).isEmpty)
    }

    /// The offline-drain case: `SheepitClient.start()` emits `$session_start`
    /// for the new session, and the `onOnline` handler then re-queues events a
    /// PREVIOUS PROCESS persisted. Ungrouped, `events[0]` is `$session_start`
    /// and every stale event inherits the new session's id.
    func testEventsFromAPreviousSessionAreNotFiledUnderTheNewOne() {
        let groups = Transport.groupedBySession([
            event("$session_start", session: "new"),
            event("stale_from_last_launch", session: "old"),
        ])

        XCTAssertEqual(groups.count, 2, "a batch spanning two sessions must become two requests")
        XCTAssertEqual(groups[0].first?.sessionId, "new")
        XCTAssertEqual(
            groups[1].first?.sessionId,
            "old",
            """
            The stale event must keep its own session id. Transport stamps the \
            batch from events[0], so leaving these in one batch would relabel \
            a previous launch's events as part of this session and inflate it.
            """
        )
    }

    func testOrderIsPreservedAndNonAdjacentRunsOfOneSessionAreNotMerged() {
        let groups = Transport.groupedBySession([
            event("a", session: "s1"),
            event("b", session: "s2"),
            event("c", session: "s1"),
        ])

        XCTAssertEqual(groups.count, 3, "FIFO order outranks merging non-adjacent runs")
        XCTAssertEqual(groups.map { $0.map(\.eventName) }, [["a"], ["b"], ["c"]])
    }

    /// Every event must survive the split — a grouping bug that dropped one
    /// would be silent data loss.
    func testGroupingIsLossless() {
        let events = (0..<20).map { event("e\($0)", session: "s\($0 % 3)") }

        let regrouped = Transport.groupedBySession(events).flatMap { $0 }

        XCTAssertEqual(regrouped.map(\.eventId), events.map(\.eventId))
    }
}

/// `track()` is the only rollover trigger that reaches macOS and watchOS —
/// `Package.swift` ships both, and the foreground notification lives behind
/// `#if canImport(UIKit) && !os(watchOS)`. Without this a session there would
/// last the whole process lifetime.
final class PlatformIndependentRolloverTests: XCTestCase {
    private let suiteName = "ai.goatech.sdk"

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

    func testTrackAnnouncesANewSessionAfterTheIdleWindowWithNoForegroundNotification() {
        // The session must age out while the client is ALIVE. Seeding a stale
        // session in storage instead would only exercise the launch path —
        // `ContextManager.init` would mint it and `start()` would announce it,
        // and the test would pass with the track() rollover entirely removed.
        let clock = TestClock(Date())
        let recorder = EventNameRecorder()
        let client = SheepitClient.createForTesting(
            config: SheepitConfig(
                apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))",
                apiUrl: "https://stub.invalid",
                onEvent: { name, _ in recorder.record(name) },
                crashes: CrashConfig(enabled: false)
            ),
            now: { clock.now }
        )
        defer { client.destroy() }

        XCTAssertEqual(
            recorder.names.filter { $0 == "$session_start" }.count, 1,
            "precondition: the launch announced its own session"
        )

        clock.advance(SDKDefaults.sessionTimeoutSeconds + 1)
        client.track("user_returns_much_later")

        XCTAssertEqual(
            recorder.names.filter { $0 == "$session_start" }.count,
            2,
            """
            track() is the only rollover trigger that reaches macOS and watchOS \
            — Package.swift ships both, and the foreground notification is \
            behind #if canImport(UIKit) && !os(watchOS). Without it a session \
            on those platforms lasts the whole process lifetime.
            """
        )
    }

    func testTheSecondSessionsEventsCarryTheNewSessionId() {
        let clock = TestClock(Date())
        let client = SheepitClient.createForTesting(
            config: SheepitConfig(
                apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))",
                apiUrl: "https://stub.invalid",
                crashes: CrashConfig(enabled: false)
            ),
            now: { clock.now }
        )
        defer { client.destroy() }

        let firstSession = client.context.sessionId
        clock.advance(SDKDefaults.sessionTimeoutSeconds + 1)
        client.track("after_the_gap")

        XCTAssertNotEqual(
            client.context.sessionId, firstSession,
            "the event after the gap belongs to a new session"
        )
    }

    func testSessionStartPrecedesTheEventThatTriggeredIt() {
        let recorder = EventNameRecorder()
        let client = SheepitClient.create(
            config: SheepitConfig(
                apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))",
                apiUrl: "https://stub.invalid",
                onEvent: { name, _ in recorder.record(name) },
                crashes: CrashConfig(enabled: false)
            )
        )
        defer { client.destroy() }

        client.track("first_user_event")

        let names = recorder.names
        guard let startIndex = names.firstIndex(of: "$session_start"),
              let eventIndex = names.firstIndex(of: "first_user_event")
        else {
            return XCTFail("expected both events, got \(names)")
        }
        XCTAssertLessThan(startIndex, eventIndex, "$session_start must open the session")
    }

    /// The recursion guard: `emitSessionStartIfOwed()` calls `track()`, which
    /// calls `emitSessionStartIfOwed()` again. It must terminate at depth 1 and
    /// emit exactly one `$session_start`, not two and not infinitely many.
    func testSessionStartIsNotEmittedTwiceByItsOwnTrackCall() {
        let recorder = EventNameRecorder()
        let client = SheepitClient.create(
            config: SheepitConfig(
                apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))",
                apiUrl: "https://stub.invalid",
                onEvent: { name, _ in recorder.record(name) },
                crashes: CrashConfig(enabled: false)
            )
        )
        defer { client.destroy() }

        client.track("a")
        client.track("b")

        XCTAssertEqual(recorder.names.filter { $0 == "$session_start" }.count, 1)
    }

    /// `destroy()` removes the notification observers but cannot cancel a
    /// foreground `Task` already in flight. That task must not roll the session
    /// over on a dead client — it would persist a session id whose
    /// `$session_start` is then silently dropped by `track()`'s own guard.
    func testAForegroundCheckAfterDestroyDoesNotStrandASession() async {
        // The session must be EXPIRED, or `rolloverIfExpired()` is a no-op and
        // the test passes with the destroyed-guard removed.
        let clock = TestClock(Date())
        let client = SheepitClient.createForTesting(
            config: SheepitConfig(
                apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))",
                apiUrl: "https://stub.invalid",
                crashes: CrashConfig(enabled: false)
            ),
            now: { clock.now }
        )
        let sessionAtDestroy = client.context.sessionId
        client.destroy()

        clock.advance(SDKDefaults.sessionTimeoutSeconds + 1)
        await client.handleWillEnterForeground()

        XCTAssertEqual(
            client.context.sessionId,
            sessionAtDestroy,
            """
            destroy() removes the notification observers but cannot cancel a \
            foreground Task already in flight. Without the destroyedFlag guard \
            that task rolls the session over and persists a fresh id, then \
            consumes the new-session flag whose track() the destroyed client \
            silently drops — stranding a session that never announces itself.
            """
        )
    }

}
