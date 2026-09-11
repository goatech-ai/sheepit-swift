import XCTest
@testable import SheepitKit

/// Regression coverage for FIX 6 in the 2026-09 security follow-up to #972: two lifecycle
/// correctness bugs that don't crash anything but silently leak or corrupt state.
final class LifecycleSafetyTests: XCTestCase {
    private static let hex = String(repeating: "a", count: 64)

    private func makeConfig(apiKey: String) -> SheepitConfig {
        SheepitConfig(
            apiKey: apiKey,
            apiUrl: "https://stub.invalid",
            // Device registration now actually runs (see SheepitClient.start()'s D-1 fix) —
            // no URLProtocol stub is registered here, so a live client's registrationTask
            // hits real DNS resolution against a host that can never resolve. The default
            // retryAttempts: 3 backs off 1s then 5s between attempts, which strongly
            // retains `self` for that whole window (the Task's `guard let self` capture) —
            // long enough to blow past this file's bounded polls. retryAttempts: 1 fails
            // the lookup once and lets the Task release promptly, same as it always did
            // before registration was dead code.
            retryAttempts: 1,
            crashes: CrashConfig(enabled: false)
        )
    }

    /// Regression: the periodic-flush `Task` in `start()` referenced `config`/`transport`
    /// without a capture list — an implicit strong capture of `self` inside an instance
    /// method's escaping closure — so `self -> flushTask -> this closure -> self` was a real
    /// reference cycle. A host that drops its client without calling `destroy()` (e.g. it
    /// falls out of scope during a screen transition) leaked it, and everything it owns
    /// (HTTPClient's URLSession, the connectivity monitor, the offline queue), forever.
    ///
    /// This is probabilistic in the sense that a handful of OTHER setup `Task`s (config
    /// sync, performance/crash wiring) also transiently capture `self` and need a moment to
    /// unwind — none of them are retain CYCLES (`self` isn't reachable back from anything
    /// they store), so they release quickly on their own. The bounded poll below tolerates
    /// that without tolerating an actual cycle, which would never clear within the deadline.
    func testLiveClientDeallocatesWithoutRetainCycleWhenDroppedWithoutDestroy() async {
        weak var weakClient: SheepitClient?

        func makeAndDrop() {
            let client = SheepitClient.create(config: makeConfig(apiKey: "lp_pub_xxx_\(Self.hex)"))
            weakClient = client
        }
        makeAndDrop()

        var attempts = 0
        while weakClient != nil && attempts < 100 {
            try? await Task.sleep(for: .milliseconds(20))
            attempts += 1
        }

        XCTAssertNil(
            weakClient,
            "A live client dropped without destroy() must still deallocate — a retained " +
            "flushTask closure would keep it (and everything it owns) alive forever."
        )
    }

    /// Regression: `initialize()` did an unsynchronized check-then-act on `static var
    /// instance` — two concurrent callers could both observe it as nil and each construct
    /// (and start) a live client, with only one ever winning the final assignment. The
    /// loser's caller still gets back a live, started, network-active client that `shared`
    /// will never point to and `destroy()` will therefore never naturally reach.
    ///
    /// High concurrency (50 racers, no `await` before the check) is the best a unit test can
    /// do to provoke the race deterministically; see the PR description for the revert-and-
    /// rerun evidence this was verified against.
    func testConcurrentInitializeNeverProducesTwoDistinctLiveInstances() async {
        SheepitClient.shared?.destroy()
        let config = makeConfig(apiKey: "lp_pub_xxx_\(Self.hex)")

        let ids = await withTaskGroup(of: ObjectIdentifier.self) { group in
            for _ in 0..<50 {
                group.addTask {
                    ObjectIdentifier(SheepitClient.initialize(config: config))
                }
            }
            var collected: [ObjectIdentifier] = []
            for await id in group { collected.append(id) }
            return collected
        }

        XCTAssertEqual(ids.count, 50)
        XCTAssertEqual(
            Set(ids).count, 1,
            "Every concurrent initialize() call must observe the same singleton instance."
        )
        SheepitClient.shared?.destroy()
    }

    /// Thread-safe box for handing a result out of a `Thread.detachNewThread` closure. The
    /// deadlock under test is a blocked `NSLock`, not an `await` suspension, so it must be
    /// reproduced on a real OS thread — parking it on a `Task` would tie up the cooperative
    /// thread pool that the rest of the (async) test suite shares.
    private final class ResultBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: T?
        var value: T? {
            get { lock.lock(); defer { lock.unlock() }; return _value }
            set { lock.lock(); defer { lock.unlock() }; _value = newValue }
        }
    }

    /// Regression: `initialize()` used to hold `instanceLock` across the whole of
    /// `create(config:)`. The INERT path emits `lifecycle.api_key_rejected` via
    /// `diagnosticBus.emit(...)`, which invokes every `onDiagnostic` subscriber
    /// SYNCHRONOUSLY on the calling thread — so a host subscriber reading
    /// `SheepitClient.shared` on that same thread self-deadlocked on the non-recursive lock.
    /// Against the pre-fix code this test times out rather than failing an assertion — see
    /// the PROCESS REQUIREMENT note in the PR: verified red by reverting `initialize()` to
    /// its lock-across-construction form and observing the 5s wait expire.
    func testInitializeDoesNotDeadlockWhenOnDiagnosticReadsSharedOnTheSameThread() {
        SheepitClient.shared?.destroy()
        let box = ResultBox<SheepitClient>()
        let done = DispatchSemaphore(value: 0)
        let config = makeConfig(apiKey: "lp_sec_xxx_\(Self.hex)") // rejected -> inert
        var configWithDiagnostic = config
        configWithDiagnostic.onDiagnostic = { @Sendable _ in
            // Read on the SAME thread `initialize()` is running on. Under the bug this
            // thread already holds `instanceLock` here — `shared` wants it too.
            _ = SheepitClient.shared
        }

        Thread.detachNewThread {
            box.value = SheepitClient.initialize(config: configWithDiagnostic)
            done.signal()
        }

        let outcome = done.wait(timeout: .now() + 5)
        XCTAssertEqual(
            outcome, .success,
            "initialize() deadlocked when a host onDiagnostic callback read SheepitClient.shared."
        )
        XCTAssertNotNil(box.value)
        XCTAssertFalse(box.value?.status().initialized ?? true)
    }

    /// Regression: the LIVE path deadlocks the same way. `create()` -> `start()` ->
    /// `emitSessionStartIfOwed()` -> `track()` calls `config.onEvent?(name, properties)`
    /// SYNCHRONOUSLY, still on the thread `initialize()` was called from, before the old code
    /// ever released `instanceLock`. A host `onEvent` that reads `SheepitClient.shared` (a
    /// realistic pattern — logging the current device id alongside every tracked event)
    /// self-deadlocked the same way as the diagnostic case above.
    func testInitializeDoesNotDeadlockWhenOnEventReadsSharedDuringAutoEmittedSessionStart() {
        SheepitClient.shared?.destroy()

        // Force a fresh session so `start()` -> `emitSessionStartIfOwed()` -> `track()` ->
        // `config.onEvent?` actually fires. This is the REAL, hardcoded `ai.goatech.sdk` suite
        // every live client in this test target shares — a session another test left live
        // moments ago (well inside the 30-minute idle window) would otherwise make
        // `$session_start` a no-op and this test pass for the wrong reason. Save/restore so
        // this doesn't leak a fixed session id into unrelated tests.
        let defaults = UserDefaults(suiteName: "ai.goatech.sdk")!
        let originalSessionId = defaults.string(forKey: StorageKeys.sessionId)
        let originalLastSeen = defaults.string(forKey: StorageKeys.sessionLastSeen)
        defer {
            defaults.set(originalSessionId, forKey: StorageKeys.sessionId)
            defaults.set(originalLastSeen, forKey: StorageKeys.sessionLastSeen)
        }
        defaults.set("session-expired-for-deadlock-test", forKey: StorageKeys.sessionId)
        defaults.set("1000000.0", forKey: StorageKeys.sessionLastSeen)

        let box = ResultBox<SheepitClient>()
        let done = DispatchSemaphore(value: 0)
        var config = makeConfig(apiKey: "lp_pub_xxx_\(Self.hex)") // admitted -> live -> start()
        config.onEvent = { @Sendable _, _ in
            _ = SheepitClient.shared
        }

        Thread.detachNewThread {
            box.value = SheepitClient.initialize(config: config)
            done.signal()
        }

        let outcome = done.wait(timeout: .now() + 5)
        XCTAssertEqual(
            outcome, .success,
            "initialize() deadlocked when a host onEvent callback read SheepitClient.shared " +
            "during the auto-emitted $session_start."
        )
        XCTAssertNotNil(box.value)
        box.value?.destroy()
    }
}
