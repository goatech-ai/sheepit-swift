import Foundation

/// Makes a `flag()` decision and the experiment assignments its `$flag_exposure` carries one
/// snapshot of ONE applied config. `FlagManager` and `ExperimentManager` lock separately, and
/// `/v1/config` applies flags then assignments, so without this a read could pair the previous
/// config's flag value with the next config's arms.
///
/// Held around the two writes in `apply` (every `/v1/config`) and `reset()`, and around
/// `FlagManager.evaluate` plus `ExperimentManager.capture()` in `flag()`. 🔴 Never around
/// synchronous host code: `track`, diagnostics and `onEvent` run after `withLock` returns, so a
/// host closure that reads a flag cannot deadlock on this non-recursive lock. `flagChanges()`
/// continuations are yielded inside it, which resumes their consumers later, never inline.
/// Lock order: `ConfigResetGate` → this → the managers' own locks.
final class ExposureDecisionGate: @unchecked Sendable {
    private let lock = NSLock()
    /// Test-only: called just before `withLock` takes the lock, so a test can see a writer reach
    /// the gate. Nil in production.
    let willLockHookForTesting = LockedHook<String>()

    func withLock<T>(_ body: () -> T) -> T {
        willLockHookForTesting.value?("")
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// Performance sampling never waits for config or identity writers.
    func tryWithLock<T>(_ body: () -> T?) -> T? {
        guard lock.try() else { return nil }
        defer { lock.unlock() }
        return body()
    }

    /// Test-only: whether the lock is held, by any thread. Never blocks.
    func isHeldForTesting() -> Bool {
        guard lock.try() else { return true }
        lock.unlock()
        return false
    }

    /// One config's flags and assignments, applied as one step. The only writer `onConfig` uses.
    /// Flag exposures sent marked during a wait that this config ends are forgotten, so they fire
    /// again, attributed (`ExperimentManager.setAssignments`).
    /// The crash-identity publication results are deliberately not reported (`recordIdentityPublication`
    /// emits a diagnostic, which runs host callbacks): both callers run inside `ConfigResetGate`, where a
    /// host `reset()` from that callback would deadlock. `reset()` and `identify()` report theirs, outside
    /// every lock, and a failed publish here leaves the cohort unavailable, never wrong (it is cleared first).
    func apply(
        flags: [String: AnyCodable],
        assignments: [String: SDKExperimentAssignment],
        appliedUnder: ConfigIdentity,
        origin: ConfigApplyOrigin,
        assignmentToken: Any? = nil,
        context: ContextManager? = nil,
        crashReporter: CrashReporter? = nil,
        to flagManager: FlagManager,
        _ experimentManager: ExperimentManager
    ) {
        withLock {
            let snapshot = context?.eventContext()
            // A signal during the two manager writes must see no attributable receipt.
            if let snapshot { crashReporter?.publishIdentity(snapshot) }
            let drained = experimentManager.setAssignments(
                assignments, appliedUnder: appliedUnder, origin: origin, assignmentToken: assignmentToken,
                eventIdentity: snapshot.map { .fetchedUnder($0.userId) })
            flagManager.setEvaluatedFlags(flags)
            flagManager.forgetExposures(drained)
            if let snapshot {
                let receipt = experimentManager.receipt(eventUserId: snapshot.userId).receipt
                crashReporter?.publishIdentity(snapshot, assignmentToken: receipt.token,
                    identityChanged: receipt.status == "identity_changed")
            }
        }
    }
}
