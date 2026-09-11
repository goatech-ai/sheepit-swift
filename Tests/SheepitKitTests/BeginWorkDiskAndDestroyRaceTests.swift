import XCTest
@testable import SheepitKit

/// Regression coverage for the 2026-09 security follow-up (round 4), findings MF3-1 and
/// MF3-2 — both are things the round-3 `constructOnly`/`beginWork()` split NEWLY ENABLED by
/// making "a constructed-but-unpublished client" a routine object nobody had audited for
/// side effects, rather than bugs the split missed fixing.
///
/// MF3-1: `constructOnly(config:)` built `ContextManager` with `persistOnInit: inertReason ==
/// nil` — true for any ACCEPTED key, including a concurrent `initialize()` LOSER that is
/// `destroy()`ed unpublished and never calls `beginWork()`. That candidate's `init` alone
/// persisted device/session ids to disk, clobbering whatever the WINNER had already written.
///
/// MF3-2: `beginWork()` guarded only on `inertReason`, not `destroyedFlag`. `initialize()`
/// publishes the singleton under `instanceLock` and calls `beginWork()` OUTSIDE that lock, so
/// a thread that read `shared` in that window and called `destroy()` could finish (one-shot)
/// before `beginWork()` ever checked — which then started device registration, config sync,
/// the flush loop, and a crash-handler install on a client nothing would ever tear down again.
final class BeginWorkDiskAndDestroyRaceTests: XCTestCase {
    private static let hex = String(repeating: "a", count: 64)

    private func makeConfig() -> SheepitConfig {
        SheepitConfig(
            apiKey: "lp_pub_xxx_\(Self.hex)",
            apiUrl: "https://stub.invalid",
            crashes: CrashConfig(enabled: false)
        )
    }

    // MARK: - MF3-1: a candidate that never begins work must write nothing to disk

    /// The direct, mechanical proof — mirrors
    /// `ConcurrentInitializeSideEffectTests.testAConstructedButUnpublishedCandidateNeverBeginsWorkEvenAfterDestroy`,
    /// but for DISK rather than `didBeginWork`. Must exercise the REAL `ai.goatech.sdk` suite
    /// (not a fresh `InMemoryStorage`, which would trivially pass whether or not `init` calls
    /// `ContextManager` with `persistOnInit: false` for THIS reason specifically) and must seed
    /// an EXPIRED session so construction would mint — and, on unfixed code, immediately
    /// persist — a NEW session id: the mutation this test needs to be able to observe. A live
    /// (non-expired) session read back unchanged would pass whether or not the write happened,
    /// exactly the round-2 finding S2 vacuous-test trap.
    func testConstructedButUnpublishedCandidateMakesNoPersistentWrites() {
        let defaults = UserDefaults(suiteName: "ai.goatech.sdk")!
        func snapshot() -> [String?] {
            [
                defaults.string(forKey: StorageKeys.deviceId),
                defaults.string(forKey: StorageKeys.sessionId),
                defaults.string(forKey: StorageKeys.sessionLastSeen),
                defaults.string(forKey: StorageKeys.anonymousId),
            ]
        }
        let originalSessionId = defaults.string(forKey: StorageKeys.sessionId)
        let originalLastSeen = defaults.string(forKey: StorageKeys.sessionLastSeen)
        defer {
            defaults.set(originalSessionId, forKey: StorageKeys.sessionId)
            defaults.set(originalLastSeen, forKey: StorageKeys.sessionLastSeen)
        }
        defaults.set("session-fixed-mf3-1", forKey: StorageKeys.sessionId)
        defaults.set("1000000.0", forKey: StorageKeys.sessionLastSeen)

        let before = snapshot()
        let candidate = SheepitClient.constructOnlyForTesting(config: makeConfig())
        XCTAssertNil(candidate.inertReason, "this candidate must be legitimately live-shaped, not inert.")
        XCTAssertEqual(
            before, snapshot(),
            "construction alone must never write to disk — that used to happen unconditionally " +
            "for any accepted key, before `beginWork()` was ever in the picture (MF3-1)."
        )

        candidate.destroy() // exactly what a real initialize() loser has done to it
        XCTAssertEqual(
            before, snapshot(),
            "destroy()ing an unpublished candidate that never began work must not write to " +
            "disk either."
        )
    }

    /// The end-to-end repro from the review: two SEQUENTIAL (not concurrent — this reproduces
    /// deterministically, no race needed) `initialize()` calls, aging the session in between so
    /// the second call's internally-constructed LOSER mints a different session id than the
    /// published winner. On unfixed code the loser's `init` persists that fresh id to disk,
    /// clobbering the winner's — so the next launch would resume a session the live process
    /// never announced (`$session_start`), making one device look like two DAU units.
    func testSecondInitializeCallDoesNotClobberTheWinnersPersistedSession() {
        SheepitClient.shared?.destroy()
        let defaults = UserDefaults(suiteName: "ai.goatech.sdk")!
        let originalDeviceId = defaults.string(forKey: StorageKeys.deviceId)
        let originalAnonymousId = defaults.string(forKey: StorageKeys.anonymousId)
        let originalSessionId = defaults.string(forKey: StorageKeys.sessionId)
        let originalLastSeen = defaults.string(forKey: StorageKeys.sessionLastSeen)
        defer {
            defaults.set(originalDeviceId, forKey: StorageKeys.deviceId)
            defaults.set(originalAnonymousId, forKey: StorageKeys.anonymousId)
            defaults.set(originalSessionId, forKey: StorageKeys.sessionId)
            defaults.set(originalLastSeen, forKey: StorageKeys.sessionLastSeen)
        }

        let config = makeConfig()
        let winner = SheepitClient.initialize(config: config)
        let winnerSessionId = winner.context.sessionId

        // Age the ON-DISK session so a freshly-constructed ContextManager (the loser the
        // second initialize() call is about to build) sees it as expired and mints a new one.
        // The winner's OWN in-memory session is untouched by this — only disk is shared state.
        defaults.set("1000000.0", forKey: StorageKeys.sessionLastSeen)

        // A second initialize() call against an existing singleton always loses
        // deterministically (see ConcurrentInitializeSideEffectTests) — no concurrency needed.
        // It still constructs a full, non-inert candidate before losing the publish check.
        let second = SheepitClient.initialize(config: config)
        XCTAssertTrue(second === winner, "a second initialize() call must return the SAME instance.")

        XCTAssertEqual(
            defaults.string(forKey: StorageKeys.sessionId), winnerSessionId,
            "a concurrent initialize() LOSER must not overwrite the winner's persisted " +
            "session id — construction alone used to do this before beginWork() ever ran " +
            "(MF3-1). A device hitting this window resumed the LOSER's un-announced session " +
            "on its next launch, invisible to DAU."
        )
        XCTAssertEqual(
            winner.context.sessionId, winnerSessionId,
            "the live winner's own in-memory session must be unaffected by a losing candidate."
        )

        winner.destroy()
    }

    // MARK: - MF3-2: beginWork() must never run start() on an already-destroyed client

    /// Deterministic version of "a thread that reads `shared` in the publish-but-not-yet-
    /// begun window and calls `destroy()` gets there first" — no race needed: simulate the
    /// window having already closed in destroy()'s favor by calling `destroy()` BEFORE
    /// `beginWork()` ever runs, exactly what `initialize()`'s winner-path effectively risks
    /// when another thread wins that race. Uses `beginWorkForTesting()` because `initialize()`
    /// itself has no pause point a test can land in.
    func testBeginWorkIsANoOpOnAClientAlreadyDestroyedBeforeItRan() {
        let candidate = SheepitClient.constructOnlyForTesting(config: makeConfig())
        XCTAssertNil(candidate.inertReason)
        candidate.destroy() // simulate: another thread's destroy() already won, fully.
        SheepitClient.resetBeginWorkCallCountForTesting()

        candidate.beginWorkForTesting() // what initialize()'s winner path calls next

        XCTAssertFalse(
            candidate.didBeginWork,
            "beginWork() must be a no-op once the client is already destroyed — otherwise it " +
            "starts device registration, config sync, the flush loop and a crash-handler " +
            "install on a client nothing will ever tear down again (destroy() is one-shot)."
        )
        XCTAssertEqual(
            SheepitClient.beginWorkCallCountForTesting, 0,
            "an already-destroyed client's beginWork() must not count as having begun work."
        )
    }

    /// The deterministic, no-race variant the review calls out explicitly: `start()` calls
    /// host code SYNCHRONOUSLY — `emitSessionStartIfOwed() -> track() -> config.onEvent?` —
    /// and `LifecycleSafetyTests` already treats a host callback calling `destroy()` on that
    /// SAME thread as a supported shape. By the time that callback fires, `start()` has
    /// already set up everything except `connectivity.onOnline { ... }`, which runs AFTER the
    /// callback returns — on an already-`destroy()`ed client that will never be torn down
    /// again. `beginWork()`'s post-`start()` recheck must catch that by re-running teardown,
    /// which is directly observable as a SECOND `releaseSelfStartingComponentsCallCount`.
    func testHostCallbackDestroyingClientMidStartStillGetsFullyTornDown() {
        SheepitClient.shared?.destroy()

        // Force a fresh session so start() -> emitSessionStartIfOwed() -> track() ->
        // config.onEvent actually fires — see LifecycleSafetyTests's identical setup.
        let defaults = UserDefaults(suiteName: "ai.goatech.sdk")!
        let originalSessionId = defaults.string(forKey: StorageKeys.sessionId)
        let originalLastSeen = defaults.string(forKey: StorageKeys.sessionLastSeen)
        defer {
            defaults.set(originalSessionId, forKey: StorageKeys.sessionId)
            defaults.set(originalLastSeen, forKey: StorageKeys.sessionLastSeen)
        }
        defaults.set("session-expired-for-mf3-2-test", forKey: StorageKeys.sessionId)
        defaults.set("1000000.0", forKey: StorageKeys.sessionLastSeen)

        var config = makeConfig()
        config.onEvent = { @Sendable _, _ in
            // Same thread, nested inside start() — exactly the supported shape
            // LifecycleSafetyTests documents.
            SheepitClient.shared?.destroy()
        }

        let client = SheepitClient.initialize(config: config)

        XCTAssertFalse(
            client.status().initialized,
            "the nested destroy() call from inside start()'s host callout must have torn the " +
            "client down."
        )
        XCTAssertEqual(
            client.releaseSelfStartingComponentsCallCount, 2,
            "beginWork() must re-run teardown after start() returns when destroy() landed " +
            "mid-start() on the same thread — otherwise whatever start() does AFTER the host " +
            "callback (here: re-registering connectivity.onOnline on an already-destroyed " +
            "monitor) outlives a destroy() that can never fire again (MF3-2)."
        )
    }
}
