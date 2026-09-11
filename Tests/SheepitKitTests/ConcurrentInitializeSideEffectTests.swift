import XCTest
@testable import SheepitKit

/// Regression coverage for the 2026-09 security follow-up (round 3), findings MF-2/MF-3.
///
/// The round-2 deadlock fix moved construction of a candidate `SheepitClient` outside
/// `instanceLock`, so every concurrent `initialize()` caller built a FULL, STARTED client
/// before the publish race was decided — only one is ever published, but the losers had
/// already registered a device, opened a config-sync loop, emitted `$session_start`, and (if
/// crash reporting were enabled) installed process-global signal handlers. `destroy()`ing a
/// loser flushes it, so its `$session_start` reached the server anyway — manufacturing DAU —
/// and if a loser's `install()` happened to win the underlying C-level race, the WINNING
/// client's OWN `isInstalled` stayed false, so the loser's `destroy()` -> `uninstall()` then
/// ripped the crash handler out of the process for the survivor's whole lifetime.
///
/// Real crash-handler installation is deliberately NOT exercised here — replacing the
/// process's signal handlers from inside the test runner is exactly the kind of live-signal
/// probe the review flagged as unsafe (a previous attempt died with signal 10). Instead this
/// proves the STRUCTURAL fix both findings share: `beginWork()` (the one and only thing that
/// calls `start()`, hence the one and only thing that would register a device, emit
/// `$session_start`, or call `crashReporter.start()` -> `install()`) runs AT MOST ONCE no
/// matter how many `initialize()` callers race — which forecloses both the DAU-manufacture
/// and the crash-handler race by construction, not by observing either outcome.
///
/// 🔴 `beginWorkCallCountForTesting` (a process-global counter incremented inside
/// `beginWork()`), not `$session_start` counting, is the assertion this suite relies on.
/// An earlier version counted real `$session_start` events via `config.onEvent` and was
/// flaky (0 or >1 across otherwise-identical runs) — that instability comes from a SEPARATE,
/// pre-existing, out-of-scope race: `ContextManager.init` does an unsynchronized
/// read-current-session / mint-if-expired / persist sequence, so 50 concurrently-constructed
/// `ContextManager` instances can race on the SAME `UserDefaults` keys and some can
/// observe a session another one just wrote as already-fresh. That race exists independent
/// of MF-2/MF-3 and is not one of the five findings this PR fixes — flagged here rather than
/// silently worked around.
final class ConcurrentInitializeSideEffectTests: XCTestCase {
    private static let hex = String(repeating: "a", count: 64)

    private func makeConfig() -> SheepitConfig {
        SheepitConfig(
            apiKey: "lp_pub_xxx_\(Self.hex)",
            apiUrl: "https://stub.invalid",
            crashes: CrashConfig(enabled: false)
        )
    }

    /// MF-2/MF-3's shared root cause: `beginWork()` — the one function that starts device
    /// registration, config sync, crash-handler install, and the `$session_start` announce —
    /// must run AT MOST ONCE across 50 concurrent `initialize()` callers, regardless of how
    /// many full candidate clients get constructed while the publish race is undecided.
    func testConcurrentInitializeCallsBeginWorkAtMostOnceRegardlessOfRacerCount() async {
        SheepitClient.shared?.destroy()
        SheepitClient.resetBeginWorkCallCountForTesting()
        let config = makeConfig()

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    _ = SheepitClient.initialize(config: config)
                }
            }
        }

        XCTAssertEqual(
            SheepitClient.beginWorkCallCountForTesting, 1,
            "50 concurrent initialize() calls must begin work exactly once — a loser " +
            "beginning work at all is what manufactures a spurious $session_start (MF-2) " +
            "and can win the crash-handler install race the winner then loses (MF-3)."
        )
        SheepitClient.shared?.destroy()
    }

    /// The direct, mechanical proof that a LOSER-shaped candidate never begins work: construct
    /// one exactly the way a concurrent `initialize()` loser is constructed
    /// (`constructOnlyForTesting`, mirroring `constructOnly(config:)`), without needing an
    /// actual race, and confirm `didBeginWork` stays `false` both before AND after
    /// `destroy()` runs on it — exactly what `initialize()` does to a real loser.
    func testAConstructedButUnpublishedCandidateNeverBeginsWorkEvenAfterDestroy() {
        let loser = SheepitClient.constructOnlyForTesting(config: makeConfig())
        XCTAssertNil(
            loser.inertReason,
            "this candidate must be a legitimately live-shaped one, not an inert/rejected one."
        )
        XCTAssertFalse(
            loser.didBeginWork,
            "a candidate that has not been published by initialize() must not have begun work."
        )

        loser.destroy() // exactly what initialize() does to a real loser

        XCTAssertFalse(
            loser.didBeginWork,
            "destroy() on an unpublished candidate must not retroactively start it."
        )
    }

    /// The direct, non-racing version of the same invariant through the public API: a second
    /// `initialize()` call against an already-published singleton always loses deterministically
    /// (no concurrency needed to provoke it) — it must return the SAME instance, and that
    /// instance's `didBeginWork` must stay exactly as it was, unaffected by the loser
    /// `initialize()` constructed and destroyed internally on this call.
    func testASecondInitializeCallAgainstAnExistingSingletonReturnsTheSameStillWorkingInstance() {
        SheepitClient.shared?.destroy()
        SheepitClient.resetBeginWorkCallCountForTesting()
        let config = makeConfig()

        let winner = SheepitClient.initialize(config: config)
        XCTAssertTrue(winner.didBeginWork)

        let second = SheepitClient.initialize(config: config)
        XCTAssertTrue(second === winner, "a second initialize() call must return the SAME instance.")
        XCTAssertTrue(second.didBeginWork, "the winner's own flag must remain true.")
        XCTAssertEqual(
            SheepitClient.beginWorkCallCountForTesting, 1,
            "the second call's internally-constructed loser must not have begun work either."
        )

        SheepitClient.shared?.destroy()
    }
}
