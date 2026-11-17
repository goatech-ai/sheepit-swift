import Foundation

/// The one retry/backoff policy for `POST /v1/devices/register`, shared by every path that
/// registers (the launch registration, a logout rotation, the identify ladder's replacement), so
/// they cannot drift. Contract, identical in every SDK:
/// `Docs/Technical/SDK_DEVICE_REGISTRATION_CONTRACT.md` § 3 and § 6.
///
/// - **One HTTP attempt per call** (`DeviceManager.register` uses `postOnceRaw`): this policy is
///   the only retry layer.
/// - **Budget:** `attemptsPerLaunch` CONSECUTIVE failed attempts per client (one per process
///   launch), shared by every failure class and every path; a success resets it, since a `reset()`
///   rotation or an identify 404 replacement registers again within one launch. The first attempt
///   goes immediately.
/// - **Delay:** jittered uniformly in `[1 s, min(cap, 2 s · 2^n)]`, `n` = `failures_total` BEFORE
///   this failure (so the first-ever retry waits 1–2 s); cap 60 s for a transient failure, 1 h for
///   402/422/429. On every non-terminal answer, 5xx included (RFC 9110 § 10.2.3), a longer
///   `Retry-After` wins, clamped to 1 h. A terminal answer (400 `VALIDATION_ERROR`, or 401/403 with
///   our API's error envelope) is a flat 24 h and stops.
/// - **Persisted:** every failure writes the ONE record (`RegistrationBackoff`), so a relaunch
///   inside the window sends nothing and `failures_total` keeps escalating launch over launch. A
///   window already open is never shortened or moved later by a later answer (only a terminal
///   answer may lengthen it). A success clears it.
final class RegistrationPolicy: @unchecked Sendable {
    enum FailureClass: Sendable {
        case transient
        /// 402 (hosted daily cap) or 422 (environment device ceiling).
        case cap
        /// 429.
        case rateLimited
        /// 400 `VALIDATION_ERROR`, 401, 403.
        case terminal
    }

    static let attemptsPerLaunch = 6
    static let floorSeconds: TimeInterval = 1
    /// The ceiling of the first retry's range: `[floorSeconds, 2 s]`.
    static let firstRetryCeilingSeconds: TimeInterval = 2
    static let transientCeilingSeconds: TimeInterval = 60
    static let throttleCeilingSeconds: TimeInterval = 60 * 60
    static let terminalWindowSeconds: TimeInterval = SDKDefaults.deviceRegistrationTerminalBackoff
    /// The register request's own timeout, 10 s in every SDK (the session default is 30 s).
    static let registerRequestTimeoutSeconds: TimeInterval = 10
    /// IDENTIFY_WAIT_BUDGET (contract § 3): one register round trip, `registerRequestTimeoutSeconds`
    /// plus 1 s. While a persisted window is open on an unregistered device, an `identify()` (awaitable
    /// or the SDK's own bind) waits out a remaining window of at most this long; a longer one settles
    /// "not registered yet" at once, and nothing is sent. A shorter caller timeout still wins.
    static let identifyWaitBudgetSeconds: TimeInterval = 11

    private let storage: StorageProvider
    private let diagnostics: DiagnosticBus
    private let log: Logger
    private let now: @Sendable () -> Date
    /// The wire app version this build registers with ("" for none): the registered marker's
    /// second half (§ 6).
    private let appVersion: String
    private let lock = NSLock()
    private var consecutiveFailures = 0
    private var _jitter: @Sendable (Double) -> Double = { upper in Double.random(in: 0..<upper) }

    init(
        storage: StorageProvider,
        diagnostics: DiagnosticBus,
        log: Logger,
        now: @escaping @Sendable () -> Date,
        appVersion: String?
    ) {
        self.storage = storage
        self.diagnostics = diagnostics
        self.log = log
        self.now = now
        self.appVersion = appVersion ?? ""
    }

    /// Test-only: the full-jitter draw, given the exclusive upper bound.
    var jitterForTesting: @Sendable (Double) -> Double {
        get { lock.lock(); defer { lock.unlock() }; return _jitter }
        set { lock.lock(); _jitter = newValue; lock.unlock() }
    }

    // MARK: - Budget

    /// Whether another attempt may go out: false (and a diagnostic) after `attemptsPerLaunch`
    /// consecutive failures this launch; the caller sends nothing.
    func takeAttempt() -> Bool {
        lock.lock()
        let allowed = consecutiveFailures < Self.attemptsPerLaunch
        lock.unlock()
        if !allowed {
            diagnostics.emit(
                .warn,
                .identity,
                code: "identity.device_registration_budget_exhausted",
                message: "Device registration failed \(Self.attemptsPerLaunch) times in a row this launch — " +
                    "the next launch retries after the persisted backoff",
                data: ["outcome": AnyCodable("budget_exhausted")]
            )
        }
        return allowed
    }

    // MARK: - Persisted window

    /// Seconds until the persisted window ends, or nil when none is open. Applies the launch rules
    /// (`RegistrationBackoff.load`): another SDK version's record is cleared, a window further out
    /// than 24 h is clamped and rewritten.
    func openWindow() -> TimeInterval? {
        let current = now()
        guard let record = loadRecord(now: current) else { return nil }
        let remaining = record.until - current.timeIntervalSince1970
        return remaining > 0 ? remaining : nil
    }

    /// `RegistrationBackoff.load`, reporting a record it had to discard: an unreadable record is
    /// cleared and logged, never treated as active.
    private func loadRecord(now current: Date) -> RegistrationBackoffRecord? {
        var discards: [RegistrationBackoff.Discard] = []
        let record = RegistrationBackoff.load(storage: storage, now: current) { discards.append($0) }
        report(discards)
        return record
    }

    /// Emits what `load` reported. Never called under `lock`: diagnostics reach host callbacks.
    private func report(_ discards: [RegistrationBackoff.Discard]) {
        for discard in discards {
            switch discard {
            case .unreadable:
                log.warn("Device registration backoff record was unreadable — cleared")
                diagnostics.emit(
                    .warn,
                    .identity,
                    code: "identity.device_registration_backoff_unreadable",
                    message: "The stored registration backoff record could not be read and was cleared",
                    data: ["outcome": AnyCodable("unreadable_cleared")]
                )
            case .clampNotPersisted:
                log.warn("Device registration backoff was clamped after a clock change, but the rewrite did not persist")
            case .otherSDKVersion:
                break
            }
        }
    }

    /// Records a failed attempt and returns how long to wait before the next one, or nil for a
    /// terminal answer (stop).
    @discardableResult
    func recordFailure(_ failure: FailureClass, retryAfter: TimeInterval? = nil) -> TimeInterval? {
        lock.lock()
        let jitter = _jitter
        let current = now()
        let nowSeconds = current.timeIntervalSince1970
        var discards: [RegistrationBackoff.Discard] = []
        let prior = RegistrationBackoff.load(storage: storage, now: current) { discards.append($0) }
        let failuresBefore = min(prior?.failuresTotal ?? 0, 10_000)
        let failuresTotal = failuresBefore + 1
        let window = Self.window(for: failure, failuresBefore: failuresBefore, retryAfter: retryAfter, jitter: jitter)
        var until = nowSeconds + window
        if let prior, prior.until > nowSeconds {
            // An open window is never shortened, and only a terminal answer may lengthen it.
            until = failure == .terminal ? max(prior.until, until) : prior.until
        }
        let record = RegistrationBackoffRecord(until: until, failuresTotal: failuresTotal, writtenBy: SDKDefaults.sdkVersion)
        let written = RegistrationBackoff.write(record, storage: storage)
        consecutiveFailures += 1
        lock.unlock()
        report(discards)
        if !written {
            log.warn("Device registration backoff could not be persisted — a relaunch may retry early")
            diagnostics.emit(
                .warn,
                .identity,
                code: "identity.device_registration_backoff_write_failed",
                message: "The registration backoff record could not be saved; a relaunch may retry early",
                data: ["outcome": AnyCodable("write_failed"), "failures_total": AnyCodable(failuresTotal)]
            )
        }
        return failure == .terminal ? nil : max(0, until - nowSeconds)
    }

    /// The window one failure opens. Pure, apart from the injected jitter draw.
    static func window(
        for failure: FailureClass,
        failuresBefore: Int,
        retryAfter: TimeInterval?,
        jitter: @Sendable (Double) -> Double
    ) -> TimeInterval {
        let cap: TimeInterval
        switch failure {
        case .terminal: return terminalWindowSeconds
        case .transient: cap = transientCeilingSeconds
        case .cap, .rateLimited: cap = throttleCeilingSeconds
        }
        let ceiling = min(cap, firstRetryCeilingSeconds * pow(2, Double(min(max(failuresBefore, 0), 30))))
        let spread = max(0, ceiling - floorSeconds)
        let jittered = spread > 0 ? floorSeconds + min(spread, max(0, jitter(spread))) : floorSeconds
        guard let retryAfter, retryAfter.isFinite, retryAfter > jittered else { return jittered }
        return min(retryAfter, throttleCeilingSeconds)
    }

    // MARK: - Registered marker (§ 6)

    /// Whether this scope registered `deviceId` with the installed app version. A different (or
    /// unrecorded) app version registers again, proposing the same id, so the row stays current.
    func isRegistered(_ deviceId: String) -> Bool {
        storage.string(forKey: StorageKeys.deviceRegistered) == deviceId
            && storage.string(forKey: StorageKeys.deviceRegisteredAppVersion) == appVersion
    }

    /// A successful registration of `deviceId`: the marker, its app version, no backoff, flushed.
    func recordSuccess(_ deviceId: String) {
        lock.lock()
        consecutiveFailures = 0
        lock.unlock()
        storage.set(deviceId, forKey: StorageKeys.deviceRegistered)
        storage.set(appVersion, forKey: StorageKeys.deviceRegisteredAppVersion)
        RegistrationBackoff.clear(storage: storage)
        if !storage.synchronize() {
            log.warn("Device registration state could not be flushed to disk")
        }
    }

    /// A rotation moved to an unregistered device.
    func clearRegistered() {
        storage.removeObject(forKey: StorageKeys.deviceRegistered)
    }
}
