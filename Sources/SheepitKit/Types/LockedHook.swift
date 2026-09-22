import Foundation

/// A lock-guarded optional callback. Test seams on `SheepitClient` use it: a test installs the
/// callback from its own thread while the SDK fires it from a background task.
final class LockedHook<Argument>: @unchecked Sendable {
    private let lock = NSLock()
    private var callback: (@Sendable (Argument) -> Void)?

    var value: (@Sendable (Argument) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return callback }
        set { lock.lock(); callback = newValue; lock.unlock() }
    }
}
