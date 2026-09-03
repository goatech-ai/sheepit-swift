import Foundation

#if canImport(UIKit) && !os(watchOS)
// @preconcurrency: UIApplication is @MainActor in the overlay, but this
// host is only ever invoked from the main thread inside the
// didEnterBackground notification callback, and the call must happen
// SYNCHRONOUSLY there — hopping to the main actor first returns control to
// UIKit, which is then free to suspend the app before the background task
// is ever requested. `MainActor.assumeIsolated` would express this, but it
// is iOS 17+ and this package's floor is iOS 16.
@preconcurrency import UIKit
#endif

/// The slice of `UIApplication`'s background-task API the SDK uses.
///
/// Exists so the begin/end pairing — the part that gets an app killed
/// when it leaks, or crashes when a task is ended twice — is testable on
/// macOS, where the real `UIApplication` path is compiled out entirely.
/// Without this seam the only automated check on that logic was "it
/// compiles" (`scripts/typecheck-ios.sh`).
///
/// Callers must be on the main thread; implementations assert it. Not
/// `@MainActor`, because the whole point is to run synchronously inside a
/// main-thread notification callback without an actor hop that would let
/// the app suspend first.
protocol BackgroundTaskHost {
    /// Request background execution time. Returns an opaque token, or
    /// `nil` when the system refuses (already suspended, over budget).
    /// The expiration handler fires if the window runs out first.
    func beginTask(name: String, expirationHandler: @escaping () -> Void) -> UInt64?
    func endTask(_ token: UInt64)
}

/// Ends a background task exactly once, whichever of the expiration
/// handler or the flush completion gets there first. Leaking one gets the
/// app killed by the watchdog; ending one twice traps.
///
/// Lock-guarded rather than main-actor isolated: the expiration handler is
/// delivered by UIKit and the completion path resumes from a `Task`, and
/// the exactly-once guarantee must hold even if those two ever land on
/// different threads.
final class BackgroundTaskToken: @unchecked Sendable {
    private let lock = NSLock()
    private let host: BackgroundTaskHost
    private var token: UInt64?

    init(host: BackgroundTaskHost, token: UInt64?) {
        self.host = host
        self.token = token
    }

    /// True when the system actually granted a window.
    var isActive: Bool {
        lock.lock()
        defer { lock.unlock() }
        return token != nil
    }

    func end() {
        lock.lock()
        let pending = token
        token = nil
        lock.unlock()
        guard let pending else { return }
        host.endTask(pending)
    }
}

#if canImport(UIKit) && !os(watchOS)
/// Production host.
struct UIKitBackgroundTaskHost: BackgroundTaskHost {
    func beginTask(name: String, expirationHandler: @escaping () -> Void) -> UInt64? {
        dispatchPrecondition(condition: .onQueue(.main))
        let identifier = UIApplication.shared.beginBackgroundTask(
            withName: name,
            expirationHandler: expirationHandler
        )
        return identifier == .invalid ? nil : UInt64(identifier.rawValue)
    }

    func endTask(_ token: UInt64) {
        let identifier = UIBackgroundTaskIdentifier(rawValue: Int(token))
        if Thread.isMainThread {
            UIApplication.shared.endBackgroundTask(identifier)
        } else {
            DispatchQueue.main.async {
                UIApplication.shared.endBackgroundTask(identifier)
            }
        }
    }
}
#endif

/// No-op host for platforms without the API (macOS, watchOS, Linux).
struct NoBackgroundTaskHost: BackgroundTaskHost {
    func beginTask(name: String, expirationHandler: @escaping () -> Void) -> UInt64? {
        nil
    }

    func endTask(_ token: UInt64) {}
}
