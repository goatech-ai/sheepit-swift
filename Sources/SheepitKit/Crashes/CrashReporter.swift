import Foundation
import SheepitCrashHandler

/// Orchestrates crash capture, persistence, and upload.
///
/// On initialization:
/// 1. Checks for a pending crash report from the previous session
/// 2. Uploads it to the server if found
/// 3. Installs signal handlers and NSException handler for the current session
/// 4. Maintains the mmap'd crash context with current user/device/flag state
actor CrashReporter {
    private let http: HTTPClient
    private let context: ContextManager
    private let config: CrashConfig
    private let storage: StorageProvider
    private let log: Logger

    private let crashFilePath: String
    private var isInstalled = false
    private var successfulLaunchTask: Task<Void, Never>?
    var onError: (@Sendable (Error, String) -> Void)?

    init(
        http: HTTPClient,
        context: ContextManager,
        config: CrashConfig,
        storage: StorageProvider,
        log: Logger
    ) {
        self.http = http
        self.context = context
        self.config = config
        self.storage = storage
        self.log = log

        // Crash file in the app's caches directory
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        let dir = caches.appendingPathComponent("ai.goatech.sdk/crashes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.crashFilePath = dir.appendingPathComponent("current.crash").path
    }

    func setOnError(_ handler: @escaping @Sendable (Error, String) -> Void) {
        self.onError = handler
    }

    // MARK: - Lifecycle

    /// Start the crash reporter: check for pending reports, then install handlers.
    func start() async {
        guard config.enabled else {
            log.debug("[Crashes] Disabled by configuration")
            return
        }

        guard CrashLoopProtection.shouldInstallHandlers(config: config, storage: storage) else {
            log.warn("[Crashes] Crash loop detected — skipping handler installation")
            return
        }

        // Check for and upload any crash from the previous session
        await checkAndUploadPendingReport()

        // Install handlers for the current session
        install()

        // Update crash context with current state
        updateContext()

        // After 10 seconds of runtime without crashing, mark a successful launch
        successfulLaunchTask = Task {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            CrashLoopProtection.recordSuccessfulLaunch(storage: storage)
            log.debug("[Crashes] Successful launch recorded")
        }
    }

    /// Stop the crash reporter and uninstall handlers.
    func stop() {
        successfulLaunchTask?.cancel()
        uninstall()
    }

    // MARK: - Handler Installation

    private func install() {
        guard !isInstalled else { return }

        let result = sheepit_crash_handler_install(crashFilePath)
        if result == 0 {
            sheepit_install_nsexception_handler()
            isInstalled = true
            log.debug("[Crashes] Signal and exception handlers installed")
        } else {
            log.error("[Crashes] Failed to install crash handler (mmap failed)")
        }
    }

    private func uninstall() {
        guard isInstalled else { return }
        sheepit_uninstall_nsexception_handler()
        sheepit_crash_handler_uninstall()
        isInstalled = false
        log.debug("[Crashes] Handlers uninstalled")
    }

    // MARK: - Pending Report Upload

    private func checkAndUploadPendingReport() async {
        guard sheepit_has_pending_crash_report(crashFilePath) else { return }

        log.debug("[Crashes] Found pending crash report from previous session")
        CrashLoopProtection.recordCrash(storage: storage)

        guard let payload = CrashReportReader.read(from: crashFilePath) else {
            log.error("[Crashes] Failed to parse pending crash report")
            sheepit_clear_pending_crash_report(crashFilePath)
            return
        }

        do {
            _ = try await http.postRaw(path: SDKEndpoints.crashReport, body: payload)
            log.debug("[Crashes] Crash report uploaded successfully")
        } catch {
            log.error("[Crashes] Failed to upload crash report: \(error.localizedDescription)")
            onError?(error, SDKEndpoints.crashReport)
            // Leave the file for next launch attempt on 5xx/network errors.
            // Delete on 4xx (malformed report won't succeed on retry).
            if let httpError = error as? HTTPClientError, httpError.isClientError {
                log.debug("[Crashes] Client error — deleting malformed report")
            } else {
                return  // Keep file for retry
            }
        }

        sheepit_clear_pending_crash_report(crashFilePath)
    }

    // MARK: - Context Updates

    /// Update the mmap'd crash context with current SDK state.
    /// Called after identity changes, flag evaluations, screen changes.
    ///
    /// The device/app fields were reserved in the C struct since it was written but never
    /// filled in — `CrashReportReader` already read them back, so a crash always shipped
    /// `app_version: ""` and `build_number`/`os_version`/`device_model: nil`, with no signal
    /// anywhere that the fields were silently empty.
    nonisolated func updateContext() {
        guard let ctx = sheepit_get_crash_context() else { return }

        writeString(context.userId ?? "", to: &ctx.pointee.user_id)
        writeString(context.deviceId, to: &ctx.pointee.device_id)
        writeString(context.sessionId, to: &ctx.pointee.session_id)
        writeString(DeviceProfile.appVersion() ?? "", to: &ctx.pointee.app_version)
        writeString(DeviceProfile.buildNumber() ?? "", to: &ctx.pointee.build_number)
        writeString(DeviceProfile.osVersion(), to: &ctx.pointee.os_version)
        writeString(DeviceProfile.deviceModel(), to: &ctx.pointee.device_model)

        ctx.pointee.magic = UInt32(SHEEPIT_CRASH_CONTEXT_MAGIC)
    }

    /// Update the screen name in the crash context.
    nonisolated func setScreen(_ name: String) {
        guard let ctx = sheepit_get_crash_context() else { return }
        writeString(name, to: &ctx.pointee.screen_name)
    }

    /// Update feature flag state in the crash context.
    nonisolated func setFlagState(_ flags: [String: Any]) {
        guard let ctx = sheepit_get_crash_context() else { return }
        let json = (try? JSONSerialization.data(withJSONObject: flags))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        writeString(json, to: &ctx.pointee.active_flags_json)
    }

    /// Update experiment state in the crash context.
    nonisolated func setExperimentState(_ experiments: [String: Any]) {
        guard let ctx = sheepit_get_crash_context() else { return }
        let json = (try? JSONSerialization.data(withJSONObject: experiments))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        writeString(json, to: &ctx.pointee.active_experiments_json)
    }

    /// Add a breadcrumb. Thread-safe (the C layer uses atomic writes).
    nonisolated func addBreadcrumb(category: String, message: String) {
        sheepit_add_breadcrumb(category, message)
    }

    // MARK: - Helpers

    /// Write a Swift string into a C fixed-size char array.
    private nonisolated func writeString<T>(_ string: String, to dest: inout T) {
        withUnsafeMutablePointer(to: &dest) { ptr in
            let size = MemoryLayout<T>.size
            ptr.withMemoryRebound(to: CChar.self, capacity: size) { cstr in
                string.withCString { src in
                    let len = min(strlen(src), size - 1)
                    memcpy(cstr, src, len)
                    cstr[len] = 0
                }
            }
        }
    }
}

// MARK: - HTTPClientError Extension

private enum HTTPClientError: Error {
    case clientError

    var isClientError: Bool { true }
}
