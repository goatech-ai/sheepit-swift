import Foundation

#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Flushes queued events when the app is backgrounded, and closes / opens
/// analytics sessions when it returns to the foreground.
///
/// Counterpart to `packages/sdk-js/src/lifecycle.ts`, which flushes on
/// `pagehide` / `visibilitychange`. Without this the periodic flush task
/// simply stops being scheduled once the app suspends, so everything
/// queued since the last tick is lost when the process is later killed.
///
/// 🔴 `applicationWillTerminate` / `UIApplication.willTerminateNotification`
/// is deliberately NOT observed and must not be added. iOS routinely kills
/// a suspended, background-capable app without ever calling it, so nothing
/// load-bearing may hang off it — not a flush, and not a session-end event.
/// `didEnterBackgroundNotification` is the last reliably-delivered signal,
/// which is why the flush lives there.
///
/// The background flush runs inside `beginBackgroundTask(withName:)` so
/// the system grants the request time to finish instead of suspending
/// mid-POST, and the task is always ended — on completion or on the
/// expiration handler — because leaking one gets the app killed.
///
/// Platform note: the observer is a no-op wherever `UIApplication`'s
/// background-task API is unavailable (macOS, watchOS, Linux). Host apps
/// that link the SDK into an **app extension**
/// (`APPLICATION_EXTENSION_API_ONLY=YES`) cannot use `UIApplication.shared`;
/// the SDK is intended for the containing app, not extensions.
final class AppLifecycleObserver: @unchecked Sendable {
    /// Performs the flush. Async so the background task stays alive for
    /// the whole network round-trip.
    private let onBackground: @Sendable () async -> Void
    private let log: Logger
    private let diagnostics: DiagnosticBus?
    private let backgroundTaskHost: @Sendable () -> BackgroundTaskHost
    private var observers: [NSObjectProtocol] = []
    /// Foreground or background, written by the notifications below and read by `track()`
    /// (0.6-C). See `AppForegroundState` for the premises.
    let appState: AppForegroundState

    /// Runs when the app returns to the foreground: flush whatever the
    /// previous session left queued, then roll the session over and announce
    /// it if the idle window elapsed while suspended.
    ///
    /// Assigned by `SheepitClient.start()` rather than passed to `init`,
    /// because the closure needs a `self` that does not exist until the
    /// client is fully initialized. It is written exactly once, before
    /// `register()` installs the observer that reads it.
    var onForeground: (@Sendable () async -> Void)?

    init(
        log: Logger,
        diagnostics: DiagnosticBus?,
        // Defaulted for the observer-only tests; `SheepitClient` always passes its own.
        appState: AppForegroundState = AppForegroundState(launchedInBackground: false, tracksAppState: false),
        backgroundTaskHost: (@Sendable () -> BackgroundTaskHost)? = nil,
        onBackground: @escaping @Sendable () async -> Void
    ) {
        self.appState = appState
        self.log = log
        self.diagnostics = diagnostics
        self.backgroundTaskHost = backgroundTaskHost ?? {
            #if canImport(UIKit) && !os(watchOS)
            return UIKitBackgroundTaskHost()
            #else
            return NoBackgroundTaskHost()
            #endif
        }
        self.onBackground = onBackground
    }

    func register() {
        #if canImport(UIKit) && !os(watchOS)
        let token = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.appDidEnterBackground()
            self?.handleDidEnterBackground()
        }
        observers.append(token)

        let foregroundToken = NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // No background-execution window needed: the app is coming back
            // to life, not suspending, so the ordinary flush loop is about to
            // resume on its own. The state flips here, synchronously, so a `track()` racing
            // the Task below already counts as foreground.
            self?.appState.markForeground()
            Task { [weak self] in await self?.performForegroundCheck() }
        }
        observers.append(foregroundToken)

        // The second foreground signal (0.6-C). It acts only while the state still says
        // background, i.e. when `willEnterForeground` never arrived for this transition, which
        // Firebase saw after a background launch. Every other activation is a no-op here.
        let activeToken = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.appState.markForeground() else { return }
            Task { [weak self] in await self?.performForegroundCheck() }
        }
        observers.append(activeToken)

        // The notifications above report transitions after this point. If the app is already
        // active while the state says background (a `.background` read at construction, then an
        // activation before this registration), no notification would ever correct it, and the
        // process would run with no session until its next foreground.
        if Thread.isMainThread, UIApplication.shared.applicationState == .active, appState.markForeground() {
            Task { [weak self] in await self?.performForegroundCheck() }
        }

        log.debug("Lifecycle observer registered (background flush, foreground session check)")
        #endif
    }

    /// What `didEnterBackgroundNotification` does to the state, before its flush.
    func appDidEnterBackground() {
        appState.markBackground()
    }

    /// What `willEnterForegroundNotification` triggers, as one call the macOS test host can
    /// drive: the state flips, then the session check runs.
    func appWillEnterForeground() async {
        appState.markForeground()
        await performForegroundCheck()
    }

    /// What `didBecomeActiveNotification` triggers: the session check, only when this is the
    /// app's first foreground since the state last said background.
    func appDidBecomeActive() async {
        guard appState.markForeground() else { return }
        await performForegroundCheck()
    }

    /// The work the foreground notification triggers, factored out for the
    /// same reason as `performBackgroundFlush()`: the package's tests run on
    /// macOS, where the UIKit registration above is compiled out entirely.
    func performForegroundCheck() async {
        diagnostics?.emit(
            .info,
            .lifecycle,
            code: "lifecycle.will_enter_foreground",
            message: "App returning to foreground — checking session freshness"
        )
        await onForeground?()
    }

    /// The work the background notification triggers, factored out so it
    /// can be exercised on platforms where the UIKit path is compiled
    /// out (the package's tests run on macOS).
    func performBackgroundFlush() async {
        diagnostics?.emit(
            .info,
            .lifecycle,
            code: "lifecycle.did_enter_background",
            message: "App entered background — flushing queued events"
        )
        await onBackground()
        log.debug("Background flush complete")
        diagnostics?.emit(
            .debug,
            .lifecycle,
            code: "lifecycle.background_flush_complete",
            message: "Background flush finished"
        )
    }

    /// Take a background-execution window SYNCHRONOUSLY, then flush, then
    /// always give the window back — on completion or on expiration,
    /// exactly once.
    ///
    /// The window must be requested before this function's first suspension
    /// point. Hopping to the main actor first (the only option on the
    /// iOS 16 floor, which lacks `MainActor.assumeIsolated`) returns control
    /// to UIKit, which is then free to suspend the app before
    /// `beginBackgroundTask` ever runs — skipping the whole flush this type
    /// exists to perform.
    func beginBackgroundWindow() -> BackgroundTaskToken {
        let host = backgroundTaskHost()
        let box = PendingTokenBox()
        let raw = host.beginTask(name: "ai.goatech.sdk.background-flush") {
            box.token?.end()
        }
        let token = BackgroundTaskToken(host: host, token: raw)
        box.token = token
        return token
    }

    /// Convenience for tests and for the non-UIKit path: take the window,
    /// flush, release the window.
    func runBackgroundFlushInTask() async {
        let token = beginBackgroundWindow()
        await performBackgroundFlush()
        token.end()
    }

    func destroy() {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
        observers = []
    }

    deinit {
        for token in observers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    #if canImport(UIKit) && !os(watchOS)
    /// Runs on the main thread (the observer registers with
    /// `queue: .main`), which is where `UIApplication.shared` must be
    /// touched. The window is taken here, synchronously, BEFORE the async
    /// flush is spawned.
    private func handleDidEnterBackground() {
        let token = beginBackgroundWindow()
        Task { [weak self] in
            await self?.performBackgroundFlush()
            token.end()
        }
    }

    #endif
}

/// Breaks the chicken-and-egg between `beginTask` and its own expiration
/// handler: the handler has to be able to end a token that `beginTask`
/// has not returned yet.
///
/// The write happens on the same (main) thread that called `beginTask`,
/// before that thread returns to UIKit, so it always happens-before any
/// handler invocation. `BackgroundTaskToken.end()` is itself lock-guarded,
/// so a handler arriving from another thread is still exactly-once.
private final class PendingTokenBox: @unchecked Sendable {
    var token: BackgroundTaskToken?
}
