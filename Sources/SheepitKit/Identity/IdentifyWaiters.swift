import Foundation

/// The waits behind `identify(userId:timeout:)` and `awaitConfig(timeout:)`: a lock-guarded table
/// of continuations, each resumed exactly once, by whichever comes first of a signal (identify
/// ladder, config apply, `reset()`, `destroy()`), its timeout, or its caller's cancellation.
///
/// An identify wait is `.ready` when the server's row is known to hold the user AND the config
/// applied in memory was fetched under that user (`ConfigIdentity.fetchedUnder`), so `flag()`
/// answers for them. It is decided from state, re-read on every signal, so a signal that lands
/// before the wait is armed is never lost: `arm` checks the same state.
///
/// 🔴 Lock order: `ConfigResetGate` → this registry's lock → `ContextManager`'s lock (read through
/// `serverHeldUser`). `configApplied` and `configCleared` run inside the reset gate; nothing else
/// here is called with any lock held, and `SheepitClient.identifyLock` is never held while calling
/// in. No continuation is resumed while a lock is held: resumes are collected and run after
/// unlocking. Inside the reset gate `configApplied` only records the label; `configAppliedOutsideGate()`
/// decides the waits after it, while they are still in the table, so a timeout can always end one.
///
/// An outcome decided before its caller installed a continuation (`early`) is not delivered yet,
/// so a later `reset()` still overrides an undelivered `.ready`: it would describe a config and a
/// user that are gone by the time the caller reads it. A decided outcome is only ever replaced by
/// another decided one, never un-decided.
///
/// `@unchecked Sendable` is sound: every stored property is read and written only under `lock`
/// (`serverHeldUser` is an immutable `@Sendable` closure). `Mutex` would say so to the compiler,
/// but it needs iOS 18 and the SDK's floor is iOS 16.
final class IdentifyWaiters: @unchecked Sendable {
    enum Wait: Sendable, Equatable {
        case identify(String)
        case config
    }

    private struct Waiter {
        let wait: Wait
        /// Identify waits only: a non-bound end of an identify POST with this sequence or later
        /// fails the wait. Nil until `arm`; an unarmed wait is not resolved by a state change.
        var failingFrom: UInt64?
        /// The highest sequence of a failed POST for this user seen before `arm`.
        var failedBeforeArm: UInt64?
        var continuation: CheckedContinuation<IdentifyOutcome, Never>?
        /// The outcome decided before the continuation was installed.
        var early: IdentifyOutcome?

        var isResolved: Bool { early != nil }
    }

    private typealias Resume = (CheckedContinuation<IdentifyOutcome, Never>, IdentifyOutcome)

    private let lock = NSLock()
    private var waiters: [UInt64: Waiter] = [:]
    private var nextId: UInt64 = 0
    /// The label of the config applied in memory; nil while none is (fresh install, after `reset()`).
    private var applied: ConfigIdentity?
    private var closed = false
    /// Per user, the last identify POST that ended without binding, so a wait registered just after
    /// it (its user identified again while it was finishing) still fails at `arm`. A bind clears the
    /// user's entry; at most `lastFailureCap` users are kept (the oldest failure goes first).
    private var lastFailure: [String: UInt64] = [:]
    private static let lastFailureCap = 32
    private let serverHeldUser: @Sendable () -> ServerHeldUser

    init(serverHeldUser: @escaping @Sendable () -> ServerHeldUser) {
        self.serverHeldUser = serverHeldUser
    }

    // MARK: - Waits

    /// A new wait; nil once `close()` ran. A config wait resolves at once if a config is applied.
    func register(_ wait: Wait) -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return nil }
        nextId &+= 1
        var waiter = Waiter(wait: wait)
        if wait == .config, applied != nil { waiter.early = .ready }
        waiters[nextId] = waiter
        return nextId
    }

    /// Arm an identify wait once its POST is queued (or none needs to be), then decide it from state.
    func arm(_ id: UInt64, failingFrom sequence: UInt64) {
        let resumes: [Resume] = locked {
            guard var waiter = waiters[id], !waiter.isResolved, case .identify(let userId) = waiter.wait else {
                return []
            }
            waiter.failingFrom = sequence
            waiters[id] = waiter
            let failedBefore = max(waiter.failedBeforeArm ?? 0, lastFailure[userId] ?? 0)
            if failedBefore >= sequence, failedBefore > 0 { return settle(id, .failed) }
            return isReady(userId) ? settle(id, .ready) : []
        }
        run(resumes)
    }

    func isResolved(_ id: UInt64) -> Bool {
        locked { waiters[id].map(\.isResolved) ?? true }
    }

    /// Resolve one wait (its timeout, its caller's cancellation, a refusal). The first outcome wins.
    func resolve(_ id: UInt64, _ outcome: IdentifyOutcome) {
        run(locked { settle(id, outcome) })
    }

    /// Suspend until the wait resolves. `timeout <= 0` decides it from what is already known.
    /// Cancelling the calling task ends the wait as `.timedOut`, and nothing else.
    func wait(_ id: UInt64, timeout: Duration) async -> IdentifyOutcome {
        var timer: Task<Void, Never>?
        if timeout <= .zero {
            resolve(id, .timedOut)
        } else {
            timer = Task { [self] in
                guard (try? await Task.sleep(for: timeout)) != nil else { return }
                resolve(id, .timedOut)
            }
        }
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<IdentifyOutcome, Never>) in
                install(id, continuation)
            }
        } onCancel: { [self] in
            resolve(id, .timedOut)
        }
        timer?.cancel()
        return outcome
    }

    // MARK: - Signals

    /// A config was applied in memory under `identity`. 🔴 Runs INSIDE the reset gate: records only.
    /// `configAppliedOutsideGate()` follows it.
    func configApplied(_ identity: ConfigIdentity) {
        lock.lock()
        applied = identity
        lock.unlock()
    }

    /// `reset()` cleared the config in memory. Runs inside the reset gate; resumes nothing. A config
    /// wait decided `.ready` but not yet delivered becomes `.timedOut` (`awaitConfig` → `false`).
    /// 🔴 Never back to undecided: its timeout may already have fired, or been `.zero`, and then
    /// nothing would ever end it.
    func configCleared() {
        lock.lock()
        defer { lock.unlock() }
        applied = nil
        for (id, var waiter) in waiters where waiter.wait == .config && waiter.early == .ready {
            waiter.early = .timedOut
            waiters[id] = waiter
        }
    }

    /// Decide every wait against what is applied now. Outside the reset gate, after `configApplied`.
    func configAppliedOutsideGate() {
        run(locked {
            var resumes: [Resume] = []
            for (id, waiter) in waiters where !waiter.isResolved {
                switch waiter.wait {
                case .config:
                    if applied != nil { resumes += settle(id, .ready) }
                case .identify(let userId):
                    if waiter.failingFrom != nil, isReady(userId) { resumes += settle(id, .ready) }
                }
            }
            return resumes
        })
    }

    /// An identify POST bound `userId` to the current device row.
    func identifyBound(_ userId: String) {
        run(locked {
            lastFailure[userId] = nil
            // Whatever POST this was, the row now holds the user, and `isReady` re-checks that.
            var resumes: [Resume] = []
            for (id, waiter) in waiters
            where !waiter.isResolved && waiter.wait == .identify(userId) && waiter.failingFrom != nil {
                if isReady(userId) { resumes += settle(id, .ready) }
            }
            return resumes
        })
    }

    /// An identify POST for `userId` ended without binding the current row (rejected, not found,
    /// exhausted, stale, or answered for a device rotated away).
    func identifyFailed(_ userId: String, sequence: UInt64) {
        run(locked {
            lastFailure[userId] = max(lastFailure[userId] ?? 0, sequence)
            if lastFailure.count > Self.lastFailureCap,
               let oldest = lastFailure.min(by: { $0.value < $1.value })?.key {
                lastFailure[oldest] = nil
            }
            var resumes: [Resume] = []
            for (id, var waiter) in waiters where !waiter.isResolved && waiter.wait == .identify(userId) {
                if let from = waiter.failingFrom {
                    if sequence >= from { resumes += settle(id, .failed) }
                } else {
                    waiter.failedBeforeArm = max(waiter.failedBeforeArm ?? 0, sequence)
                    waiters[id] = waiter
                }
            }
            return resumes
        })
    }

    /// The app identified `userId`: every identify wait for another user is superseded.
    func supersede(by userId: String) {
        failIdentifyWaits { $0 != userId }
    }

    /// `reset()`: every identify wait fails. Config waits keep waiting for the next applied config.
    func resetHappened() {
        failIdentifyWaits { _ in true }
    }

    /// `destroy()`: every wait ends (identify `.failed`, config `false`), no new one starts, and the
    /// table is left empty. A wait whose caller has not installed its continuation yet finds no
    /// entry in `install` and ends `.failed` there.
    func close() {
        run(locked {
            closed = true
            let resumes: [Resume] = waiters.values.compactMap { waiter in
                waiter.continuation.map { ($0, .failed) }
            }
            waiters = [:]
            return resumes
        })
    }

    /// Runs in `install` before it takes the lock, so a test can land a `reset()` between a wait's
    /// registration and its continuation.
    let beforeInstallHookForTesting = LockedHook<UInt64>()

    /// Entries still in the table, for tests.
    var countForTesting: Int { locked { waiters.count } }

    // MARK: - Private (call with `lock` held unless noted)

    /// Also overrides an undelivered `.ready`: the user it was ready for is gone.
    private func failIdentifyWaits(_ matches: (String) -> Bool) {
        run(locked {
            var resumes: [Resume] = []
            for (id, var waiter) in waiters {
                guard case .identify(let userId) = waiter.wait, matches(userId) else { continue }
                if waiter.early == .ready {
                    waiter.early = .failed
                    waiters[id] = waiter
                } else if !waiter.isResolved {
                    resumes += settle(id, .failed)
                }
            }
            return resumes
        })
    }

    private func isReady(_ userId: String) -> Bool {
        applied == .fetchedUnder(userId) && serverHeldUser() == .known(userId)
    }

    /// The first outcome wins: with a continuation installed, remove the waiter and hand back the
    /// resume; without one, record it for `install`.
    private func settle(_ id: UInt64, _ outcome: IdentifyOutcome) -> [Resume] {
        guard var waiter = waiters[id], !waiter.isResolved else { return [] }
        if let continuation = waiter.continuation {
            waiters[id] = nil
            return [(continuation, outcome)]
        }
        waiter.early = outcome
        waiters[id] = waiter
        return []
    }

    /// Takes the lock itself.
    private func install(_ id: UInt64, _ continuation: CheckedContinuation<IdentifyOutcome, Never>) {
        beforeInstallHookForTesting.value?(id)
        let immediate: IdentifyOutcome? = locked {
            guard var waiter = waiters[id] else { return .failed }
            if let early = waiter.early {
                waiters[id] = nil
                return early
            }
            waiter.continuation = continuation
            waiters[id] = waiter
            return nil
        }
        if let immediate { continuation.resume(returning: immediate) }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    /// No lock held.
    private func run(_ resumes: [Resume]) {
        for (continuation, outcome) in resumes { continuation.resume(returning: outcome) }
    }
}
