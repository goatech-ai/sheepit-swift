import Foundation
import Network

/// Monitors network connectivity using NWPathMonitor.
///
/// `isOnline` is written from `NWPathMonitor`'s private dispatch queue and
/// read from the `Transport` actor's executor, so both sides are
/// lock-guarded. ThreadSanitizer flagged the unguarded version as a real
/// data race on the live `Transport.flush()` path.
///
/// Callbacks are invoked OUTSIDE the lock — same discipline as
/// `DiagnosticBus` — so a callback that re-enters the monitor cannot
/// deadlock it.
final class GTConnectivityMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var _isOnline = true
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ai.goatech.sdk.connectivity")
    private var onOnlineCallbacks: [@Sendable () -> Void] = []

    var isOnline: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isOnline
    }

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let satisfied = path.status == .satisfied

            self.lock.lock()
            let wasOffline = self._isOnline == false
            self._isOnline = satisfied
            let callbacks = wasOffline && satisfied ? self.onOnlineCallbacks : []
            self.lock.unlock()

            guard !callbacks.isEmpty else { return }
            DispatchQueue.main.async {
                for callback in callbacks { callback() }
            }
        }
        monitor.start(queue: queue)
    }

    func onOnline(_ callback: @escaping @Sendable () -> Void) {
        lock.lock()
        onOnlineCallbacks.append(callback)
        lock.unlock()
    }

    func destroy() {
        monitor.cancel()
        lock.lock()
        onOnlineCallbacks.removeAll()
        lock.unlock()
    }
}
