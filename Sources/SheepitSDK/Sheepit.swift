import Foundation

/// Sheepit iOS SDK — feature flags, experiments, and event tracking.
///
/// Usage:
/// ```swift
/// // Initialize
/// let sheepit = Sheepit.create(config: .init(apiKey: "lp_pub_xxx_..."))
///
/// // Track events
/// sheepit.track("button_tapped", properties: ["screen": "checkout"])
///
/// // Feature flags
/// if sheepit.flag("show_banner", default: .bool(false)).boolValue == true {
///     showBanner()
/// }
///
/// // Experiments
/// let result = sheepit.experiment("checkout_v2")
/// switch result.variant {
/// case "variant_a": showNewCheckout()
/// default: showOriginalCheckout()
/// }
///
/// // Identity
/// sheepit.identify(userId: "user_123", traits: ["plan": "pro"])
/// ```
public final class Sheepit: @unchecked Sendable {
    // MARK: - Singleton

    private static var instance: Sheepit?

    /// Create and return a singleton instance. Warns if already initialized.
    public static func initialize(config: SheepitConfig) -> Sheepit {
        if let existing = instance {
            existing.log.warn("initialize() called after already initialized. Returning existing instance.")
            return existing
        }
        let inst = create(config: config)
        instance = inst
        return inst
    }

    /// Get the singleton instance. Returns nil if not initialized.
    public static var shared: Sheepit? { instance }

    // MARK: - Factory

    /// Create a new independent instance. Preferred for SwiftUI apps (inject via environment).
    ///
    /// Reject secret keys (`lp_sec_*`). They grant full project write access and must NEVER
    /// ship in an iOS bundle (anyone can extract them via `strings` on the IPA). The matching
    /// guard in the JS SDK lives at packages/sdk-js/src/client.ts:130. Audit E-002 (2026-04-25)
    /// flagged the missing guard here as a P0 secret-leak vector.
    ///
    /// Apps doing internal SDK testing in XCTest can opt out by setting
    /// `SheepitConfig.allowSecretKeyInClient = true`. Production callers should never set it.
    public static func create(config: SheepitConfig) -> Sheepit {
        precondition(config.apiKey.hasPrefix("lp_pub_") || config.apiKey.hasPrefix("lp_sec_"),
                     "Invalid API key format. Expected lp_pub_... or lp_sec_...")
        if config.apiKey.hasPrefix("lp_sec_") && !config.allowSecretKeyInClient {
            preconditionFailure(
                "[Sheepit] Secret keys (lp_sec_*) must not ship in iOS apps. They grant full " +
                "project write access and would leak from the IPA. Use a publishable key " +
                "(lp_pub_*) for client-side code. See audit-findings/REMEDIATION_PROGRESS.md " +
                "(E-002) for the rationale."
            )
        }
        return Sheepit(config: config)
    }

    // MARK: - Internal Components

    private let config: SheepitConfig
    private let log: GTLogger
    private let storage: StorageProvider
    private let context: ContextManager
    private let queue: EventQueue
    private let offlineQueue: OfflineQueue
    private let http: HTTPClient
    private let transport: Transport
    private let connectivity: GTConnectivityMonitor
    private let deviceManager: DeviceManager
    private let flagManager: GTFlagManager
    private let experimentManager: GTExperimentManager
    private let configSync: ConfigSync
    private let performanceMonitor: PerformanceMonitor?
    private let crashReporter: CrashReporter?
    private let diagnosticBus: DiagnosticBus
    private let lifecycleObserver: AppLifecycleObserver
    private let lastFlushClock = LastFlushClock()

    private var flushTask: Task<Void, Never>?
    private let destroyedFlag = AtomicFlag()
    /// Resolves when the initial device registration round-trip completes
    /// (success OR failure). identify() and other server calls that reference
    /// deviceId await this so they don't 404 against a locally-generated UUID
    /// the server hasn't seen.
    private var registrationTask: Task<Void, Never>?

    private init(config: SheepitConfig) {
        self.config = config
        self.log = GTLogger(debug: config.debug)
        let bus = DiagnosticBus(bufferSize: config.diagnosticBufferSize)
        if let onDiagnostic = config.onDiagnostic {
            bus.subscribe(onDiagnostic)
        }
        self.diagnosticBus = bus
        self.storage = UserDefaultsStorage(suiteName: "ai.goatech.sdk")
        // Must run before ContextManager reads any key, or an existing
        // install looks brand new: fresh device id, lost identity, lost
        // offline queue, re-bucketed experiments.
        StorageMigration.run(storage: storage)
        self.context = ContextManager(storage: storage)
        self.queue = EventQueue(maxSize: config.maxQueueSize, diagnostics: bus)
        self.offlineQueue = OfflineQueue(storage: storage, diagnostics: bus)
        self.http = HTTPClient(config: config, log: log)
        self.connectivity = GTConnectivityMonitor()
        self.transport = Transport(
            http: http,
            queue: queue,
            offlineQueue: offlineQueue,
            connectivity: connectivity,
            log: log,
            appVersion: config.appVersion,
            diagnostics: bus,
            lastFlushClock: lastFlushClock
        )
        self.deviceManager = DeviceManager(http: http, log: log)
        self.flagManager = GTFlagManager(diagnostics: bus)
        self.flagManager.setOverridesAllowed(config.allowFlagOverrides ?? config.debug)
        self.experimentManager = GTExperimentManager(storage: storage)

        // ConfigSync callback applies config to flag/experiment managers.
        // Capture managers (not self) to avoid a reference cycle.
        let fm = self.flagManager
        let em = self.experimentManager
        let logger = self.log
        self.configSync = ConfigSync(
            http: http,
            storage: storage,
            refreshInterval: config.configRefreshInterval,
            log: log,
            onConfig: { response in
                fm.setEvaluatedFlags(response.flags)
                em.setAssignments(response.experiments)
                logger.debug(
                    "Config applied: \(response.flags.count) flags, "
                    + "\(response.experiments.count) experiments"
                )
            }
        )

        // Performance monitoring
        if config.performance.enabled {
            let monitor = PerformanceMonitor(
                http: http,
                context: context,
                config: config.performance,
                log: log
            )
            self.performanceMonitor = monitor
        } else {
            self.performanceMonitor = nil
        }

        // Crash reporting
        if config.crashes.enabled {
            let reporter = CrashReporter(
                http: http,
                context: context,
                config: config.crashes,
                storage: storage,
                log: log
            )
            self.crashReporter = reporter
        } else {
            self.crashReporter = nil
        }

        // Flush on app background so queued events survive suspension.
        // `transport` is captured directly (not self) to avoid a cycle.
        let transportRef = self.transport
        self.lifecycleObserver = AppLifecycleObserver(
            log: log,
            diagnostics: bus,
            onBackground: { await transportRef.flush() }
        )

        // Wire error tracking callbacks
        if let monitor = performanceMonitor {
            Task {
                await monitor.setOnError { [weak self] error, endpoint in
                    self?.trackSDKError(source: "performance", error: error, endpoint: endpoint)
                }
            }
        }
        if let reporter = crashReporter {
            Task {
                await reporter.setOnError { [weak self] error, endpoint in
                    self?.trackSDKError(source: "crashes", error: error, endpoint: endpoint)
                }
            }
        }

        start()
        log.debug("SDK initialized (env: \(config.environment))")
    }

    // MARK: - Public API: Events

    /// Track an event with optional properties.
    public func track(_ eventName: String, properties: [String: Any]? = nil) {
        guard !destroyedFlag.value else { return }

        let name = validateEventName(eventName)
        context.touchSession()
        let ctx = context.eventContext()

        let event = EnrichedEvent(
            eventId: UUID().uuidString,
            eventName: name,
            eventProperties: properties?.mapValues { AnyCodable($0) },
            deviceId: ctx.deviceId,
            anonymousId: ctx.anonymousId,
            sessionId: ctx.sessionId,
            userId: ctx.userId,
            platform: ctx.platform,
            sdkVersion: ctx.sdkVersion,
            locale: ctx.locale,
            timezone: ctx.timezone,
            timestamp: ISO8601DateFormatter().string(from: Date())
        )

        queue.add(event)
        crashReporter?.addBreadcrumb(category: "track", message: name)
        config.onEvent?(name, properties)

        if queue.size() >= config.flushSize {
            Task { await transport.flush() }
        }
    }

    /// Force flush pending events and performance metrics to the server.
    public func flush() async {
        await transport.flush()
        await performanceMonitor?.flush()
    }

    // MARK: - Public API: Flags

    /// Evaluate a feature flag. Returns synchronously from cached config.
    public func flag(_ flagKey: String, default defaultValue: FlagValue = .bool(false)) -> FlagValue {
        guard !destroyedFlag.value else { return defaultValue }
        return flagManager.evaluate(
            flagKey: flagKey,
            defaultValue: defaultValue,
            onExposure: { [weak self] key, value in
                self?.track("$flag_exposure", properties: [
                    "flag_key": key,
                    // Raw value, not a case description — matches
                    // packages/sdk-js/src/client.ts:315 and the
                    // `flag_value: "unknown"` event schema.
                    "flag_value": value.anyValue,
                ])
            }
        )
    }

    /// Override a flag value for local testing. Only applies when
    /// overrides are allowed — see `SheepitConfig.allowFlagOverrides`
    /// (defaults to following `debug`). No-ops (and does not persist) when
    /// disabled.
    public func overrideFlag(_ key: String, value: FlagValue) {
        flagManager.overrideFlag(key, value: value)
    }

    /// Clear all debug overrides. ALWAYS works, regardless of whether
    /// overrides are currently allowed (`SheepitConfig.allowFlagOverrides`)
    /// — gating writes is the security property that matters (a production
    /// build must not be able to apply an override); gating deletes would
    /// buy nothing and could leave a build that once ran with
    /// `debug: true` unable to purge an override it wrote to disk before
    /// shipping.
    public func clearOverrides() {
        flagManager.clearOverrides()
    }

    /// All currently-set debug overrides, keyed by flag key. Only
    /// non-empty when overrides are allowed — see
    /// `SheepitConfig.allowFlagOverrides` (defaults to following `debug`).
    public func getOverrides() -> [String: FlagValue] {
        flagManager.getOverrides()
    }

    /// Clear a single flag's debug override, leaving any others in place.
    /// ALWAYS works, regardless of whether overrides are currently
    /// allowed — see `clearOverrides()`'s doc for why.
    public func clearOverride(_ key: String) {
        guard !destroyedFlag.value else { return }
        flagManager.clearOverride(key)
    }

    /// Diagnostic read for a debug/dev-menu flag inspector. Does NOT fire
    /// exposure — safe to sweep every known key without polluting
    /// experiment/flag exposure data. Not for use in product code paths;
    /// use `flag(_:default:)` there.
    public func inspect(_ flagKey: String, default defaultValue: FlagValue = .bool(false)) -> SheepitFlagInspection {
        guard !destroyedFlag.value else {
            return SheepitFlagInspection(
                key: flagKey,
                remoteValue: nil,
                overrideValue: nil,
                effectiveValue: defaultValue,
                source: .fallback
            )
        }
        return flagManager.inspect(flagKey: flagKey, defaultValue: defaultValue)
    }

    /// Union of flag keys with a remote value (from the last-applied
    /// `/v1/config`) and keys carrying a local override, sorted. Does NOT
    /// fire exposure.
    ///
    /// A dev menu's PRIMARY list should come from the customer's
    /// generated `Flag.allCases` (works on a fresh install with the API
    /// down). This is for the inverse — surfacing server keys the local
    /// codegen doesn't know about yet.
    public func knownFlagKeys() -> [String] {
        guard !destroyedFlag.value else { return [] }
        return flagManager.knownFlagKeys()
    }

    /// A stream of flag-change notifications: fires on config apply
    /// (a `/v1/config` refresh), override set, and override clear.
    /// Multi-subscriber — call this once per observer; each call
    /// registers an independent stream. No Combine/Observation surface
    /// exists in the SDK, so a SwiftUI dev-menu screen should iterate
    /// this in a `.task` to re-render on change.
    ///
    /// After `destroy()`, returns an already-finished stream — a `for
    /// await` consumer sees the loop end immediately rather than hanging
    /// on a stream that will never yield or complete again.
    public func flagChanges() -> AsyncStream<Void> {
        guard !destroyedFlag.value else {
            return AsyncStream { continuation in continuation.finish() }
        }
        return flagManager.changes()
    }

    // MARK: - Public API: Experiments

    /// Get the assigned variant for an experiment.
    public func experiment(_ experimentKey: String) -> SheepitExperimentResult {
        guard !destroyedFlag.value else { return SheepitExperimentResult(variant: "control") }
        return experimentManager.resolve(experimentKey: experimentKey) { [weak self] key, variant in
            self?.track("$experiment_exposure", properties: [
                "experiment_key": key,
                "variant": variant,
            ])
        }
    }

    // MARK: - Public API: Identity

    /// Identify the current user. Call after login.
    ///
    /// Mirrors `packages/sdk-js/src/identity.ts`: re-identifying with the
    /// SAME `userId` only merges traits locally — it does not flush, does
    /// not clear experiment assignments, and does not POST. Only a real
    /// identity CHANGE does that work. Before this gate, an app calling
    /// `identify()` on every screen appearance issued a
    /// `/v1/devices/:id/identify` POST each time.
    public func identify(userId: String, traits: [String: Any]? = nil) {
        guard !destroyedFlag.value else { return }

        let previousUserId = context.userId

        guard previousUserId != userId else {
            // Same user — traits-only merge.
            if let traits { context.updateUserTraits(traits) }
            diagnosticBus.emit(
                .debug,
                .identity,
                code: "identity.identify_noop",
                message: "identify() called with the current userId — traits merged only"
            )
            return
        }

        // Flush events attributed to the previous identity first.
        Task { await flush() }

        context.setUserId(userId)
        if let traits { context.updateUserTraits(traits) }

        // Reset experiments for the new user
        experimentManager.clearAssignments()
        flagManager.clearExposed()

        diagnosticBus.emit(
            .info,
            .identity,
            code: "identity.identified",
            message: "Identity changed",
            data: ["has_previous_user": AnyCodable(previousUserId != nil)]
        )

        // Post identity to server (fire-and-forget). Await registration so
        // /v1/devices/:deviceId/identify targets a device the server knows.
        Task { [weak self] in
            guard let self else { return }
            await self.registrationTask?.value
            await self.deviceManager.identify(
                deviceId: self.context.deviceId,
                userId: userId,
                attributes: traits
            )
        }
    }

    /// Reset identity. Call on logout.
    public func reset() {
        guard !destroyedFlag.value else { return }

        Task { await flush() }
        context.resetIdentity()
        experimentManager.clearAssignments()
        flagManager.clearExposed()
    }

    // MARK: - Public API: Performance

    /// Start a named performance span for custom timing measurement.
    /// Returns the span object. Call `endSpan(_:)` with the same name to complete it.
    public func startSpan(_ name: String, attributes: [String: String] = [:]) {
        guard !destroyedFlag.value else { return }
        Task { await performanceMonitor?.startSpan(name, attributes: attributes) }
    }

    /// End a previously started performance span by name.
    public func endSpan(_ name: String) {
        guard !destroyedFlag.value else { return }
        Task { await performanceMonitor?.endSpan(name) }
    }

    /// Notify the SDK that the first frame has been rendered.
    /// Used for cold/warm start measurement.
    public func markFirstFrame() {
        guard !destroyedFlag.value else { return }
        Task { await performanceMonitor?.markFirstFrame() }
    }

    /// Get a snapshot of current performance metrics.
    public func performanceSummary() async -> SheepitPerformanceSummary? {
        guard !destroyedFlag.value else { return nil }
        return await performanceMonitor?.performanceSummary()
    }

    // MARK: - Public API: Crashes

    /// Add a breadcrumb for crash report context.
    /// Breadcrumbs are recorded in a ring buffer and included in crash reports.
    public func addBreadcrumb(category: String, message: String) {
        guard !destroyedFlag.value else { return }
        crashReporter?.addBreadcrumb(category: category, message: message)
    }

    /// Set the current screen name for crash context.
    public func setScreen(_ screenName: String) {
        guard !destroyedFlag.value else { return }
        crashReporter?.setScreen(screenName)
    }

    // MARK: - Public API: Status

    /// Get current SDK status.
    public func status() -> SDKStatus {
        SDKStatus(
            initialized: !destroyedFlag.value,
            online: connectivity.isOnline,
            queueDepth: queue.size(),
            offlineQueueDepth: offlineQueue.size(),
            lastFlushAt: lastFlushClock.date,
            deviceId: context.deviceId,
            userId: context.userId,
            flagCount: flagManager.count(),
            experimentCount: experimentManager.count(),
            sdkVersion: SDKDefaults.sdkVersion
        )
    }

    // MARK: - Public API: Diagnostics

    /// The SDK's diagnostics bus. Subscribe for a live feed of internal
    /// events (transport, config, identity, lifecycle, connectivity)
    /// without enabling `debug` logging.
    ///
    /// ```swift
    /// let cancel = sdk.diagnostics().subscribe { event in
    ///     print(event.code, event.message)
    /// }
    /// ```
    public func diagnostics() -> DiagnosticBus {
        diagnosticBus
    }

    /// The buffered diagnostic events, oldest first. Bounded by
    /// `SheepitConfig.diagnosticBufferSize`.
    public func getRecentDiagnostics() -> [DiagnosticEvent] {
        diagnosticBus.getRecentDiagnostics()
    }

    /// Shut down the SDK. Flushes pending events and performance metrics.
    public func destroy() {
        // testAndSet so exactly one caller runs teardown even if
        // destroy() is called concurrently from two threads.
        guard destroyedFlag.testAndSet() else { return }
        Task { await flush() }
        flushTask?.cancel()
        flushTask = nil
        registrationTask?.cancel()
        registrationTask = nil
        Task { await configSync.stop() }
        if let monitor = performanceMonitor {
            Task {
                await monitor.flush()
                await monitor.stop()
            }
        }
        if let reporter = crashReporter {
            Task { await reporter.stop() }
        }
        lifecycleObserver.destroy()
        connectivity.destroy()
        // Finish outstanding flagChanges() streams so a consumer whose
        // lifetime isn't tied to a cancellable scope sees completion
        // rather than hanging forever.
        flagManager.finishAllChanges()
        if Sheepit.instance === self {
            Sheepit.instance = nil
        }
        log.debug("SDK destroyed")
    }

    // MARK: - Private

    private func start() {
        // Register device if needed. Capture the task so identify() can await it.
        let existingDeviceId = storage.string(forKey: StorageKeys.deviceId)
        if existingDeviceId == nil {
            registrationTask = Task { [weak self] in
                guard let self else { return }
                if let deviceId = await self.deviceManager.register(
                    anonymousId: self.context.anonymousId,
                    existingDeviceId: nil
                ) {
                    self.context.setDeviceId(deviceId)
                }
            }
        }

        // Start config sync
        Task {
            await configSync.start { [weak self] in
                self?.context.deviceId ?? ""
            }
        }

        // Start periodic flush
        flushTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(config.flushInterval))
                guard !Task.isCancelled else { break }
                await transport.flush()
            }
        }

        // Start performance monitoring
        if let monitor = performanceMonitor {
            Task { await monitor.start() }
        }

        // Start crash reporting
        if let reporter = crashReporter {
            Task { await reporter.start() }
        }

        // Flush on background (no-op off UIKit platforms)
        lifecycleObserver.register()

        // Drain offline queue when back online
        connectivity.onOnline { [weak self] in
            guard let self else { return }
            let queued = self.offlineQueue.drain()
            if !queued.isEmpty {
                self.log.debug("Back online — re-queuing \(queued.count) offline events")
                for event in queued { self.queue.add(event) }
                Task { await self.transport.flush() }
            }
        }
    }

    /// Track an SDK-internal error as an event so it appears in the dashboard.
    /// Guarded against recursion — errors from tracking this event are silently dropped.
    internal func trackSDKError(source: String, error: Error, endpoint: String? = nil) {
        var props: [String: Any] = [
            "source": source,
            "error": error.localizedDescription,
            "platform": "ios",
        ]
        if let endpoint { props["endpoint"] = endpoint }

        if let sdkError = error as? SDKError {
            switch sdkError {
            case .httpError(let code), .serverError(let code):
                props["status_code"] = code
            case .badRequest(let msg):
                props["status_code"] = 400
                props["detail"] = String(msg.prefix(500))
            case .rateLimited:
                props["status_code"] = 429
            default:
                break
            }
        }

        // Use track() directly but don't let failures cascade
        track("$sdk_error", properties: props)
    }

    private func validateEventName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(!trimmed.isEmpty, "Event name must not be empty")
        return String(trimmed.replacingOccurrences(of: "\\s+", with: "_", options: .regularExpression)
            .prefix(SDKDefaults.eventNameMaxLength))
    }
}
