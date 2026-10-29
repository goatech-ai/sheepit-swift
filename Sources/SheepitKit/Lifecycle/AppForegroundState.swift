import Foundation

#if canImport(UIKit) && !os(watchOS)
@preconcurrency import UIKit
#endif

/// Whether the app is in the foreground, so sessions begin and extend only while someone is
/// looking (0.6-C).
///
/// iOS launches an app with no UI for a `content-available` or VoIP push and for a
/// `BGAppRefreshTask`. Before this type, such a launch minted and announced a session, and every
/// background `track()` rolled one over and extended it, so sessions began with nobody looking
/// and per-session rates were biased. Firebase (firebase-ios-sdk#12219) and Amplitude start
/// sessions only in the foreground.
///
/// Lock-guarded: the lifecycle notifications write it on the main thread, `track()` reads it on
/// any thread.
///
/// Measured on the simulator (founder, 2026-10-28, `scripts/probes/sdk-swift-foreground-sessions/`):
/// `applicationState` read `.background` in `didFinishLaunching` on EVERY launch, a normal user
/// launch included, and the session started at the first `willEnterForeground` about 20 ms later.
/// So events tracked in that window carry `app_state=background`. A true background launch (a
/// silent push to a killed app) was not reproducible on the simulator and still needs a
/// real-device check (PENDING_WORK). The premises below come from two shipping SDKs, and the
/// design is built so that being wrong about the first one delays a session start rather than
/// losing it:
/// - `applicationState` reads `.background` in `didFinishLaunching` for a background launch.
///   Amplitude-Swift's `IOSLifecycleMonitor` branches on the same read at setup, and treats
///   `.background` as "wait for the next activation".
/// - `willEnterForegroundNotification` may not arrive on the first foreground of a
///   background-launched process. Firebase 12.5.0 fixed exactly that ("session_start events not
///   consistently being reported on app foreground if the app was initially launched in the
///   background"). So `AppLifecycleObserver` also treats `didBecomeActiveNotification` as a
///   foreground signal, but only when this type still says background: an ordinary
///   re-activation (Control Center, a call) does nothing new.
final class AppForegroundState: @unchecked Sendable {
    /// The value every event carries as `app_state`.
    enum Value: String {
        case foreground
        case background
    }

    private let lock = NSLock()
    private var foreground: Bool
    /// Told every new value, under `lock`. See `setOnChange(_:)`.
    private var onChange: (@Sendable (Bool) -> Void)?
    /// False where there is no `UIApplication` lifecycle to follow (macOS, watchOS). There the
    /// app is always treated as foreground, as before 0.6-C, and events carry no `app_state`.
    let tracksAppState: Bool

    init(launchedInBackground: Bool, tracksAppState: Bool) {
        self.foreground = !launchedInBackground
        self.tracksAppState = tracksAppState
    }

    /// The state at SDK construction.
    ///
    /// Read only on the main thread, where `UIApplication.shared` must be touched. Off the main
    /// thread it assumes foreground, which is the pre-0.6-C behaviour: blocking on the main
    /// thread here could deadlock a host that waits on `initialize()` from main.
    static func live() -> AppForegroundState {
        #if canImport(UIKit) && !os(watchOS)
        let background = Thread.isMainThread && UIApplication.shared.applicationState == .background
        return AppForegroundState(launchedInBackground: background, tracksAppState: true)
        #else
        return AppForegroundState(launchedInBackground: false, tracksAppState: false)
        #endif
    }

    var isForeground: Bool {
        lock.lock()
        defer { lock.unlock() }
        return foreground
    }

    /// `app_state` for an event tracked now; nil where the state is not tracked.
    var wireValue: String? {
        guard tracksAppState else { return nil }
        return (isForeground ? Value.foreground : Value.background).rawValue
    }

    /// `body` runs with the new value on every `markBackground()` / `markForeground()`, while the
    /// lock is held. `CrashReporter` mirrors the state into the crash context with it.
    ///
    /// Under the lock so that a mirror is never overtaken: a writer that read `true` just before
    /// the app backgrounded cannot store it after the transition stored `false`, which would leave
    /// a background crash reporting the foreground. Keep `body` to a plain store; it must not call
    /// back into this type.
    func setOnChange(_ body: (@Sendable (Bool) -> Void)?) {
        lock.lock()
        defer { lock.unlock() }
        onChange = body
    }

    /// `body` with the current value, under the same lock as the transitions. For a mirror whose
    /// destination is reset outside them: the crash handler zeroes its context at install.
    func withCurrentValue(_ body: (Bool) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(foreground)
    }

    func markBackground() {
        lock.lock()
        defer { lock.unlock() }
        foreground = false
        onChange?(false)
    }

    /// Returns whether this changed the state, i.e. the app was in the background until now.
    @discardableResult
    func markForeground() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let changed = !foreground
        foreground = true
        onChange?(true)
        return changed
    }
}
