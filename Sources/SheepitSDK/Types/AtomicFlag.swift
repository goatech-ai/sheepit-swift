import Foundation

/// A one-way boolean latch, safe to read and set from any thread.
///
/// Backs `Sheepit.destroyed`. The plain `var` it replaced allowed two
/// concurrent `destroy()` calls to both pass `guard !destroyed` before
/// either set it, double-running teardown (double flush, a
/// `NotificationCenter` observer walk racing the array clear, and a
/// double `Sheepit.instance = nil`).
final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return flag
    }

    /// Set the latch. Returns true only for the caller that flipped it,
    /// so exactly one of N concurrent callers runs the guarded work.
    func testAndSet() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if flag { return false }
        flag = true
        return true
    }
}
