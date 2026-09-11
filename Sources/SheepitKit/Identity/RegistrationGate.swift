import Foundation

/// Thread-safe holder for the in-flight device-registration `Task`, so SDK-internal
/// auto-flush triggers can await its outcome without needing `self`.
///
/// `SheepitClient.init` wires several long-lived closures (the app-background flush
/// handler, in particular) BEFORE `self` is fully initialized — Swift will not let a
/// closure literal inside an initializer capture `self`, even weakly, until every stored
/// property has a value, and the closure in question is itself part of assigning one of
/// those properties. Those closures capture referenced dependencies directly instead (see
/// `transportRef` in `init`); this type exists so "wait for registration to settle" can
/// join that same list, rather than being unreachable from exactly the call site — app
/// backgrounding on the very first launch — where the race it closes is real.
///
/// `SheepitClient.start()` (which DOES have a fully-initialized `self`) is the only writer,
/// via `setTask(_:)`, once per process — called at most once, since `start()` creates
/// `registrationTask` at most once per client. Every reader just calls `awaitSettlement()`.
final class RegistrationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func setTask(_ task: Task<Void, Never>?) {
        lock.lock()
        self.task = task
        lock.unlock()
    }

    /// Waits for whatever task was set, if any — a no-op if `setTask` was never called
    /// (registration wasn't attempted this launch) or if the task has already resolved
    /// (Swift caches a `Task`'s result, so awaiting `.value` post-completion is
    /// synchronous). The actual `await` happens OUTSIDE the lock, via the SYNCHRONOUS
    /// `currentTask()` — Swift 6 flags `NSLock.lock()/unlock()` called directly inside an
    /// `async` function body as unsafe (a real `error` under strict concurrency, not just
    /// this package's own `-warnings-as-errors` gate), and holding a lock across a
    /// suspension point would be wrong regardless.
    func awaitSettlement() async {
        await currentTask()?.value
    }

    private func currentTask() -> Task<Void, Never>? {
        lock.lock()
        defer { lock.unlock() }
        return task
    }
}
