import XCTest
@testable import SheepitKit

/// The Swift half of `packages/conformance/sessions/timelines.json`: the same foreground/background
/// timeline gives SheepitKit and the Android SDK (`SessionConformanceTest.kt`) the same session
/// boundaries. Read in place via `#filePath`, never copied (see `ConformanceTests`).
///
/// The macOS test host has no `UIApplication`, so each process gets an `AppForegroundState` that
/// tracks state, and the observer's entry points stand in for the notifications, as in
/// `ForegroundSessionTests`. Events are read off the live queue, drained before every step that
/// could flush it (a foreground, a relaunch), so a flush to the stub host never takes one.
final class SessionConformanceTests: XCTestCase {
    private let suiteName = "ai.goatech.sdk"
    private var defaults: UserDefaults { UserDefaults(suiteName: suiteName)! }
    private let storedId = "stored-session-id"

    private static var corpusURL: URL {
        // <repo>/packages/sdk-swift/Tests/SheepitKitTests/SessionConformanceTests.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("conformance/sessions/timelines.json")
    }

    /// Also clears what makes a client rotate the device on the stub host (see `ForegroundSessionTests`).
    private func clearStoredSession() {
        for key in [StorageKeys.sessionId, StorageKeys.sessionLastSeen, StorageKeys.serverHeldUser,
                    StorageKeys.identity, StorageKeys.deviceBindAttempted,
                    // This suite's launches persist an hour-long window (the retry delay below);
                    // tearDown must not hand it to the next suite (SharedSDKStorage's contract).
                    StorageKeys.deviceRegistrationBackoff] {
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

    private func corpus() throws -> [String: Any] {
        let data = try Data(contentsOf: Self.corpusURL)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testTheTimeoutIsTheOneThisImplementationUses() throws {
        let timeout = try XCTUnwrap(try corpus()["session_timeout_ms"] as? Int)
        XCTAssertEqual(TimeInterval(timeout) / 1000, SDKDefaults.sessionTimeoutSeconds)
    }

    func testEveryCaseGivesTheSessionsTheAndroidSDKGives() async throws {
        let cases = try XCTUnwrap(try corpus()["cases"] as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(cases.count, 10, "an empty corpus tests nothing")
        for testCase in cases {
            clearStoredSession()
            let id = try XCTUnwrap(testCase["id"] as? String)
            let actual = try await run(testCase)
            XCTAssertEqual(actual, try expected(testCase), id)
        }
    }

    private func line(_ event: String, _ session: String?, _ appState: String?) -> String {
        "\(event) session=\(session ?? "nil") app_state=\(appState ?? "nil")"
    }

    private func expected(_ testCase: [String: Any]) throws -> [String] {
        let expect = try XCTUnwrap(testCase["expect"] as? [[String: Any]])
        return try expect.map {
            line(try XCTUnwrap($0["event"] as? String), $0["session"] as? String,
                 try XCTUnwrap($0["app_state"] as? String, "every expectation names its app_state"))
        }
    }

    private func run(_ testCase: [String: Any]) async throws -> [String] {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = ConformanceClock(t0)
        let stored = testCase["stored_session"] as? [String: Any]
        if let stored {
            let lastSeenMs = try XCTUnwrap(stored["last_seen_ms"] as? Int)
            defaults.set(storedId, forKey: StorageKeys.sessionId)
            defaults.set(
                String(t0.addingTimeInterval(TimeInterval(lastSeenMs) / 1000).timeIntervalSince1970),
                forKey: StorageKeys.sessionLastSeen
            )
        }
        var client: SheepitClient?
        // Killed clients: never destroyed while the case runs (see "kill"), only after it.
        var dead: [SheepitClient] = []
        var collected: [EnrichedEvent] = []
        var tracked = Set<String>()
        for step in try XCTUnwrap(testCase["steps"] as? [[String: Any]]) {
            let atMs = try XCTUnwrap(step["at_ms"] as? Int)
            clock.set(t0.addingTimeInterval(TimeInterval(atMs) / 1000))
            switch step["op"] as? String {
            case "launch":
                if let old = client {
                    collected += old.drainQueuedEventsForTesting()
                    old.destroy()
                }
                let background = (step["app_state"] as? String) == "background"
                // A short backoff window left open (by an earlier suite) defers the first registration
                // attempt and, at or under the identify wait budget, arms the gate with it
                // (SheepitClient.swift:2421-2431), so a foreground can wait on it. Registration is
                // outside this corpus: each launch starts with no window.
                SharedSDKStorage.remove(StorageKeys.deviceRegistrationBackoff, from: defaults)
                client = SheepitClient.createForTesting(
                    config: SheepitConfig(
                        apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))",
                        apiUrl: "https://stub.invalid",
                        // No timer flush mid-case: the live queue is what this suite reads.
                        flushInterval: 3600,
                        retryAttempts: 1,
                        crashes: CrashConfig(enabled: false)
                    ),
                    now: { clock.now },
                    // With one attempt, fails at once: a foreground otherwise waits ~6 s on registration retries.
                    urlProtocolClasses: [OfflineURLProtocol.self],
                    appState: AppForegroundState(launchedInBackground: background, tracksAppState: true),
                    // The failed launch registration re-arms in 1-2 s; push it past any case, so a
                    // killed client held below never retries while the next process runs.
                    launchRegistrationRetryDelay: { _ in .seconds(3600) }
                )
            case "track":
                let name = try XCTUnwrap(step["event"] as? String)
                tracked.insert(name)
                try XCTUnwrap(client).track(name)
            case "foreground":
                let live = try XCTUnwrap(client)
                collected += live.drainQueuedEventsForTesting()
                await live.lifecycleObserver.appWillEnterForeground()
            case "background":
                try XCTUnwrap(client).lifecycleObserver.appDidEnterBackground()
            case "kill":
                // A dead process runs no teardown, so no destroy(): the drain reads the tracked
                // events out of memory and writes nothing to storage. The client is held until the
                // case ends and destroyed there, so no task of its outlives the test. Until then its
                // only armed task is the registration retry, pushed an hour out above, and its flush
                // timer, at the 3600 s interval: neither fires inside a case.
                let killed = try XCTUnwrap(client)
                collected += killed.drainQueuedEventsForTesting()
                dead.append(killed)
                client = nil
            default:
                // Fail closed: an op this suite does not know would otherwise pass unchecked.
                XCTFail("unknown op \(String(describing: step["op"]))")
            }
        }
        if let client {
            collected += client.drainQueuedEventsForTesting()
            client.destroy()
        }
        dead.forEach { $0.destroy() }

        var labels: [String: String] = [:]
        if let stored { labels[storedId] = stored["label"] as? String }
        var minted = 0
        return collected
            .filter { $0.eventName == "$session_start" || tracked.contains($0.eventName) }
            .map { event in
                let label = event.sessionId.map { id -> String in
                    if let known = labels[id] { return known }
                    minted += 1
                    labels[id] = "S\(minted)"
                    return "S\(minted)"
                }
                return line(event.eventName, label, event.eventProperties?["app_state"]?.value as? String)
            }
    }
}

private final class ConformanceClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ start: Date) { _now = start }
    var now: Date {
        lock.lock(); defer { lock.unlock() }; return _now
    }
    func set(_ date: Date) {
        lock.lock(); defer { lock.unlock() }; _now = date
    }
}
