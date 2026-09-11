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
final class ConnectivityMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var _isOnline = true
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "ai.goatech.sdk.connectivity")
    private var onOnlineCallbacks: [@Sendable () -> Void] = []
    private var _isMonitoring = false

    /// Whether the underlying `NWPathMonitor` is still running. `NWPathMonitor`
    /// is not released by dealloc alone — it needs an explicit `cancel()` — so
    /// this is the signal a test uses to prove a client actually let it go.
    var isMonitoring: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isMonitoring
    }

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
    }

    /// Begin watching the network path.
    ///
    /// Deliberately NOT done in `init`. A component that starts work in its own initializer
    /// runs before its owner has decided whether it should exist at all — that is how a
    /// client built with a rejected API key ended up holding a live `NWPathMonitor` it could
    /// never release, and it made every short-lived client pay for a real monitor. Idempotent.
    func start() {
        lock.lock()
        let alreadyRunning = _isMonitoring
        _isMonitoring = true
        lock.unlock()
        guard !alreadyRunning else { return }
        monitor.start(queue: queue)
    }

    func onOnline(_ callback: @escaping @Sendable () -> Void) {
        lock.lock()
        onOnlineCallbacks.append(callback)
        lock.unlock()
    }

    func destroy() {
        lock.lock()
        let wasRunning = _isMonitoring
        _isMonitoring = false
        lock.unlock()
        if wasRunning { monitor.cancel() }
        lock.lock()
        onOnlineCallbacks.removeAll()
        lock.unlock()
    }

}
