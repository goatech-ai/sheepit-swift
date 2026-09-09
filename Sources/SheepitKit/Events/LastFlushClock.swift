import Foundation

/// Thread-safe holder for the timestamp of the last successful flush.
///
/// `Transport` is an actor, so its `lastFlushAt` can only be read from an
/// async context — but `SheepitClient.status()` is a synchronous public API and
/// making it `async` would be a source break for every caller. The
/// Transport writes here on each successful flush; `status()` reads it.
final class LastFlushClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date?

    var date: Date? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func mark(_ date: Date) {
        lock.lock()
        value = date
        lock.unlock()
    }
}
