import Foundation

#if canImport(UIKit) && !os(watchOS)
import UIKit
#endif

/// Flushes queued events when the app is backgrounded.
///
/// Counterpart to `packages/sdk-js/src/lifecycle.ts`, which flushes on
/// `pagehide` / `visibilitychange`. Without this the periodic flush task
/// simply stops being scheduled once the app suspends, so everything
/// queued since the last tick is lost when the process is later killed.
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

    init(
        log: Logger,
        diagnostics: DiagnosticBus?,
        backgroundTaskHost: (@Sendable () -> BackgroundTaskHost)? = nil,
        onBackground: @escaping @Sendable () async -> Void
    ) {
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
            self?.handleDidEnterBackground()
        }
        observers.append(token)
        log.debug("Lifecycle observer registered (background flush)")
        #endif
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
