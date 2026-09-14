import Foundation

/// Serializes `SheepitClient.reset()` against config writes, synchronously and outside any actor.
///
/// `reset()` wipes the cached config on disk and the evaluated config in memory. A `/v1/config`
/// fetch that started before it must never write or apply afterwards, or the logged-out user's
/// config comes back. `ConfigSync` is an actor, and a clear sent to it from `reset()` ran at an
/// arbitrary later time: it could miss a response that landed first, and it deleted whatever was
/// on disk when it finally ran, including a cache written after the reset (measured deleting one
/// seeded 42 µs later).
///
/// So the check and the write share one lock: `reset(_:)` bumps the token and clears inside it;
/// `ifNotReset(since:_:)` writes and applies inside it, only if the token has not moved since the
/// fetch started. Neither closure may call host code: the lock is not recursive.
final class ConfigResetGate: @unchecked Sendable {
    private let lock = NSLock()
    private var token: UInt64 = 0

    /// The current reset token. A fetch captures it before its request.
    var current: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    /// Invalidate every fetch in flight and run `clear` in the same critical section.
    func reset(_ clear: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        token &+= 1
        clear()
    }

    /// Run `body` only if no reset happened since `startToken`, holding resets off while it runs.
    /// Returns whether it ran.
    @discardableResult
    func ifNotReset(since startToken: UInt64, _ body: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard token == startToken else { return false }
        body()
        return true
    }
}
