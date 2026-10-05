import Foundation
import SheepitCrashHandler

/// Orchestrates crash capture, persistence, and upload.
///
/// On start:
/// 1. Moves a crash report the previous session left in the live file into `PendingCrashStore`
/// 2. Installs signal handlers and NSException handler for the current session (which
///    truncates the live file — hence step 1 first)
/// 3. Uploads every queued report — even when crash-loop protection skipped steps 1-2; one that
///    fails for a retryable reason stays queued for the next launch, bounded by
///    `SDKDefaults.crashUploadMaxAttempts` / `crashUploadMaxAge`
/// 4. Maintains the mmap'd crash context with current user/device/flag state
///
/// Every upload decision emits a `transport.crash_upload` diagnostic whose `outcome` names the
/// branch (`CrashUploadOutcome`).
actor CrashReporter {
    private let http: HTTPClient
    private let context: ContextManager
    private let config: CrashConfig
    private let storage: StorageProvider
    private let log: Logger

    /// Internal for a test pin; see `productionLiveDirectory()`.
    nonisolated let crashFilePath: String
    private let pendingStore: PendingCrashStore
    private let diagnostics: DiagnosticBus?
    private let now: @Sendable () -> Date
    private var isInstalled = false
    private var successfulLaunchTask: Task<Void, Never>?
    var onError: (@Sendable (Error, String) -> Void)?

    init(
        http: HTTPClient,
        context: ContextManager,
        config: CrashConfig,
        storage: StorageProvider,
        log: Logger,
        crashDirectory: URL? = nil,
        pendingDirectory: URL? = nil,
        diagnostics: DiagnosticBus? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.http = http
        self.context = context
        self.config = config
        self.storage = storage
        self.log = log

        let dir = crashDirectory ?? Self.productionLiveDirectory()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.crashFilePath = dir.appendingPathComponent("current.crash").path
        self.pendingStore = PendingCrashStore(
            directory: pendingDirectory
                ?? crashDirectory.map { $0.appendingPathComponent("pending", isDirectory: true) }
                ?? PendingCrashStore.defaultDirectory()
        )
        self.diagnostics = diagnostics
        self.now = now
    }

    /// `<Caches>/ai.goatech.sdk/crashes`, holding `current.crash`. Unchanged since 0.x, so a
    /// crash an older build wrote is still found after an update. The retry queue is not in
    /// Caches — see `PendingCrashStore`. 🔴 Used even when XCTest is loaded: see
    /// `PendingCrashStore.defaultDirectory()` for why the live file is never redirected.
    static func productionLiveDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return caches.appendingPathComponent("ai.goatech.sdk/crashes", isDirectory: true)
    }

    func setOnError(_ handler: @escaping @Sendable (Error, String) -> Void) {
        self.onError = handler
    }

    // MARK: - Lifecycle

    /// Start the crash reporter: queue the previous session's crash, install handlers, then
    /// upload everything queued.
    func start() async {
        // Never false in the SDK: `SheepitClient` builds no reporter when crashes are disabled,
        // and ages the queue out itself (`CrashReporter.reapExhausted`).
        guard config.enabled else {
            log.debug("[Crashes] Disabled by configuration")
            return
        }

        if CrashLoopProtection.shouldInstallHandlers(config: config, storage: storage) {
            // Before install(): it reopens the live file O_TRUNC and zeroes it. Uploading from
            // the live file and installing afterwards lost every report whose upload failed.
            adoptPreviousSessionCrash()

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
        } else {
            log.warn("[Crashes] Crash loop detected — skipping handler installation")
        }

        // NOT behind the crash-loop guard. The latch it reads is sticky in UserDefaults and is
        // cleared only by a launch that installed, so gating this on it stranded every queued
        // report for good. The loop the guard exists for is crash-on-launch; if a poison report
        // is what crashes — reading it or sending it — `upload(_:)` has already spent an attempt
        // (it records the attempt before either), so it is dropped after
        // `crashUploadMaxAttempts` launches.
        await uploadPendingReports()
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

    /// Move a crash the previous session wrote into the pending queue. Counted for crash-loop
    /// protection HERE, once per crash — not on each later retry of the same report.
    private func adoptPreviousSessionCrash() {
        guard sheepit_has_pending_crash_report(crashFilePath) else { return }

        log.debug("[Crashes] Found pending crash report from previous session")
        CrashLoopProtection.recordCrash(storage: storage)

        // Re-stamp before `adopt` evicts the oldest: eviction sorts on first-seen, and a report
        // stamped under a 1970 clock would otherwise always be the one dropped, whatever its age.
        let current = now()
        for queued in pendingStore.entries() {
            _ = Self.withPlausibleFirstSeen(queued, store: pendingStore, now: current)
        }

        let live = URL(fileURLWithPath: crashFilePath)
        let (entry, evicted) = pendingStore.adopt(
            liveFile: live, now: current, maxReports: SDKDefaults.crashPendingMaxReports
        )
        for old in evicted {
            log.warn("[Crashes] Retry queue full — dropping oldest crash report \(old.id)")
            emitOutcome(.droppedQueueFull, reportId: old.id, attempts: old.attempts, error: nil)
        }
        guard entry != nil else {
            log.error("[Crashes] Could not move the pending crash report aside — it will be overwritten")
            emitOutcome(.droppedUnretainable, reportId: nil, attempts: 0, error: nil)
            return
        }
    }

    /// A stored first-seen time: not before `crashClockFloor`, not past `now` + tolerance.
    private static func plausible(_ date: Date, now: Date) -> Bool {
        date >= SDKDefaults.crashClockFloor && date <= now.addingTimeInterval(SDKDefaults.crashClockFutureTolerance)
    }

    /// The only check `now` itself can get: there is nothing to compare it with but the floor.
    /// A clock stuck in the past is caught; a clock running FAST cannot be told from real time.
    private static func clockIsSet(_ now: Date) -> Bool {
        now >= SDKDefaults.crashClockFloor
    }

    /// The entry with a first-seen time age can be judged against. A report adopted under a
    /// wrong device clock carries a wrong first-seen: the epoch (a boot before NTP settles —
    /// the next launch would drop a real crash as 56 years old) or the future (it would never
    /// age out, holding a queue slot). Either is re-stamped to `now` once `clockIsSet(now)`,
    /// so the 7 days count from that launch's time.
    private static func withPlausibleFirstSeen(
        _ entry: PendingCrashStore.Entry,
        store: PendingCrashStore,
        now: Date
    ) -> PendingCrashStore.Entry {
        guard clockIsSet(now), !plausible(entry.firstSeen, now: now) else { return entry }
        return store.restamp(entry, firstSeen: now)
    }

    /// Past the attempt bound, or past `crashUploadMaxAge` — the age judged only when `now` is
    /// set and first-seen is plausible, so a clock stuck before the floor never ages a report
    /// out. A clock jumped FORWARD by more than the max age does age one out early: see
    /// `clockIsSet`.
    private static func isExhausted(_ entry: PendingCrashStore.Entry, now: Date) -> Bool {
        if entry.attempts >= SDKDefaults.crashUploadMaxAttempts { return true }
        guard clockIsSet(now), plausible(entry.firstSeen, now: now) else { return false }
        return now.timeIntervalSince(entry.firstSeen) > SDKDefaults.crashUploadMaxAge
    }

    private static func dropExhausted(
        _ entry: PendingCrashStore.Entry,
        store: PendingCrashStore,
        diagnostics: DiagnosticBus?,
        log: Logger
    ) {
        log.warn("[Crashes] Dropping crash report \(entry.id) after \(entry.attempts) counted attempts")
        store.remove(entry)
        emit(.droppedRetryExhausted, on: diagnostics, reportId: entry.id, attempts: entry.attempts, error: nil)
    }

    /// Drop every queued report past its bounds; send nothing, keep the rest. For a client that
    /// builds no reporter — crash reporting disabled — so disabling it does not strand the queue.
    /// Called by `SheepitClient.start()`, never for an inert client (which must touch no disk).
    static func reapExhausted(
        store: PendingCrashStore,
        now: Date,
        diagnostics: DiagnosticBus?,
        log: Logger
    ) {
        for queued in store.entries() {
            let entry = withPlausibleFirstSeen(queued, store: store, now: now)
            if isExhausted(entry, now: now) {
                dropExhausted(entry, store: store, diagnostics: diagnostics, log: log)
            }
        }
    }

    private func uploadPendingReports() async {
        for entry in pendingStore.entries() {
            await upload(entry)
        }
    }

    private func upload(_ queued: PendingCrashStore.Entry) async {
        let entry = Self.withPlausibleFirstSeen(queued, store: pendingStore, now: now())
        if Self.isExhausted(entry, now: now()) {
            Self.dropExhausted(entry, store: pendingStore, diagnostics: diagnostics, log: log)
            return
        }

        // Counted BEFORE the report is read or sent: a report that crashes the process in
        // either step must still spend an attempt (see `start()`). Refunded below when the
        // failure is not a server error.
        let attempted = pendingStore.recordAttempt(entry)

        guard var payload = CrashReportReader.read(from: attempted.url.path) else {
            log.error("[Crashes] Failed to parse pending crash report")
            pendingStore.remove(attempted)
            emitOutcome(.droppedUnreadable, reportId: entry.id, attempts: attempted.attempts, error: nil)
            return
        }
        payload.reportId = entry.id

        do {
            // ONE in-process attempt: the queue retries across launches. HTTPClient's own
            // ladder (`retryAttempts`, 1 s / 5 s backoff) would multiply every launch's upload.
            _ = try await http.postRaw(path: SDKEndpoints.crashReport, body: payload, maxAttempts: 1)
            log.debug("[Crashes] Crash report uploaded successfully")
            pendingStore.remove(attempted)
            emitOutcome(.uploaded, reportId: entry.id, attempts: attempted.attempts, error: nil)
        } catch {
            log.error("[Crashes] Failed to upload crash report: \(error.localizedDescription)")
            onError?(error, SDKEndpoints.crashReport)
            if Self.isNonRetryable(error) {
                pendingStore.remove(attempted)
                emitOutcome(.droppedNonRetryable, reportId: entry.id, attempts: attempted.attempts, error: error)
            } else {
                let kept = Self.spendsAttempt(error) ? attempted : pendingStore.refundAttempt(attempted)
                emitOutcome(.retainedForRetry, reportId: entry.id, attempts: kept.attempts, error: error)
            }
        }
    }

    /// Whether a retryable failure counts against `crashUploadMaxAttempts`. Only a 5xx does —
    /// the one answer that can mean THIS report breaks the server. Everything else is refunded
    /// and bounded by `crashUploadMaxAge` and the queue cap instead:
    /// - offline / timeout / cancelled: the server never saw it;
    /// - 402 (daily cap) / 429: the server said "later";
    /// - 401 / 403 / 404: a key, WAF or proxy in front of the API refusing EVERY report, not
    ///   this one. Founder decision 2026-09-28: while a customer's proxy or WAF is misconfigured,
    ///   crashes must wait for the fix rather than burn their budget against it.
    static func spendsAttempt(_ error: Error) -> Bool {
        guard let sdkError = error as? SDKError else { return false }
        switch sdkError {
        case .serverError:
            return true
        case .badRequest, .httpError, .rateLimited, .networkError, .invalidResponse, .notInitialized:
            // `.badRequest` (400) and 413/422 never get here: `isNonRetryable` drops them first.
            return false
        }
    }

    /// A report the server will reject identically however many times it is re-sent: 400
    /// (malformed — `HTTPClient` throws `.badRequest`), 413 (too large), 422. Everything else
    /// is retried, bounded: 5xx and network errors are transient; 402 (daily cap) and 429 clear
    /// with time; 401/403/404 are a key, WAF or proxy problem a later build or config fixes.
    static func isNonRetryable(_ error: Error) -> Bool {
        guard let sdkError = error as? SDKError else { return false }
        switch sdkError {
        case .badRequest:
            return true
        case .httpError(let code):
            return code == 413 || code == 422
        default:
            return false
        }
    }

    private static func statusCode(of error: Error) -> Int? {
        guard let sdkError = error as? SDKError else { return nil }
        switch sdkError {
        case .badRequest: return 400
        case .rateLimited: return 429
        case .httpError(let code), .serverError(let code): return code
        default: return nil
        }
    }

    private func emitOutcome(
        _ outcome: CrashUploadOutcome,
        reportId: String?,
        attempts: Int,
        error: Error?
    ) {
        Self.emit(outcome, on: diagnostics, reportId: reportId, attempts: attempts, error: error)
    }

    private static func emit(
        _ outcome: CrashUploadOutcome,
        on diagnostics: DiagnosticBus?,
        reportId: String?,
        attempts: Int,
        error: Error?
    ) {
        var data: [String: AnyCodable] = [
            "outcome": AnyCodable(outcome.rawValue),
            "attempts": AnyCodable(attempts),
            "max_attempts": AnyCodable(SDKDefaults.crashUploadMaxAttempts),
        ]
        if let reportId { data["report_id"] = AnyCodable(reportId) }
        if let error, let status = statusCode(of: error) { data["status_code"] = AnyCodable(status) }
        diagnostics?.emit(
            outcome.severity,
            .transport,
            code: "transport.crash_upload",
            message: outcome.message,
            data: data
        )
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

/// The `outcome` of a `transport.crash_upload` diagnostic — one value per branch a queued
/// crash report can take.
enum CrashUploadOutcome: String, CaseIterable {
    case uploaded
    /// The upload failed for a retryable reason; the report stays queued for the next launch.
    case retainedForRetry = "retained_for_retry"
    /// The server rejected the report in a way a retry cannot change (400/413/422).
    case droppedNonRetryable = "dropped_non_retryable"
    /// Out of counted attempts or older than `SDKDefaults.crashUploadMaxAge`.
    case droppedRetryExhausted = "dropped_retry_exhausted"
    /// Evicted, oldest first, to keep the queue at `SDKDefaults.crashPendingMaxReports`.
    case droppedQueueFull = "dropped_queue_full"
    /// The queued file is not a readable crash report.
    case droppedUnreadable = "dropped_unreadable"
    /// The previous session's report could not be moved out of the live file before the
    /// handler reused it.
    case droppedUnretainable = "dropped_unretainable"

    var severity: DiagnosticSeverity {
        switch self {
        case .uploaded: return .info
        case .retainedForRetry: return .warn
        case .droppedNonRetryable, .droppedRetryExhausted, .droppedQueueFull, .droppedUnreadable,
             .droppedUnretainable:
            return .error
        }
    }

    var message: String {
        switch self {
        case .uploaded: return "Crash report uploaded"
        case .retainedForRetry: return "Crash report upload failed; kept for the next launch"
        case .droppedNonRetryable: return "Crash report rejected by the server; dropped"
        case .droppedRetryExhausted: return "Crash report dropped after exhausting its retries"
        case .droppedQueueFull: return "Crash retry queue full; oldest report dropped"
        case .droppedUnreadable: return "Queued crash report is unreadable; dropped"
        case .droppedUnretainable: return "Crash report could not be kept for upload; dropped"
        }
    }
}
