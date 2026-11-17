import Foundation
import os

/// Which user a `/v1/config` body was bucketed for, as far as the SDK can know. Experiment
/// attribution compares it with each event's user (`ExperimentManager.receipt(eventUserId:)`).
enum ConfigIdentity: Sendable, Equatable {
    /// Fetched while the server was confirmed to hold this user for the device (`nil`: none).
    case fetchedUnder(String?)
    /// A cached body written before the SDK recorded the label. Treated as matching no user.
    case unknown
}

/// Where an applied config came from: a server fetch, numbered in start order
/// (`ConfigSync.fetchesStarted`), the on-device cache at launch, or a body the server could not
/// resolve the device for, applied to memory only (`ConfigSync.onProvisional`).
enum ConfigApplyOrigin: Sendable, Equatable {
    case server(fetch: Int)
    case cache
    /// 🔴 Never ends an identity switch: the body was evaluated for no known row.
    case provisional
}

/// Counts `/v1/config` fetches as they START. Readable outside the actor, so a caller can record
/// "fetches started so far" and later tell a fetch that began after that point.
final class ConfigFetchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var started = 0

    var current: Int {
        lock.lock()
        defer { lock.unlock() }
        return started
    }

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        started += 1
        return started
    }
}

/// Periodically fetches flag/experiment configuration from GET /v1/config.
/// Mirrors packages/sdk-js/src/config-sync.ts; both follow the device-resolution rule in
/// `Docs/Technical/SDK_DEVICE_REGISTRATION_CONTRACT.md` § 7 (`DeviceResolution`).
actor ConfigSync {
    /// Every fetch's start number (`ConfigApplyOrigin.server`).
    nonisolated let fetchesStarted = ConfigFetchCounter()
    private let http: HTTPClient
    private let storage: StorageProvider
    private let refreshInterval: TimeInterval
    private let log: Logger
    /// The applied body, the identity it is labelled with, and where it came from: a server fetch
    /// in this process (with its start number) or the on-device cache at launch.
    private let onConfig: @Sendable (SDKConfigResponse, ConfigIdentity, ConfigApplyOrigin) -> Void
    /// Applies an UNRESOLVED body to memory, never to disk: only while no real body has been applied
    /// since launch or the last `reset()`, replacing an older memory-only one (`handleUnresolved`). Not a config "applied" for the
    /// waiters, so `awaitConfig` / `identify(userId:timeout:)` keep waiting for a resolved one.
    private let onProvisional: @Sendable (SDKConfigResponse) -> Void
    /// Called after every `onConfig`, once the reset gate is released: `onConfig` runs inside the
    /// gate, which must not resume anything (`IdentifyWaiters.configAppliedOutsideGate()`).
    private let onApplied: @Sendable () -> Void
    /// What the server's device row holds (`ContextManager.serverHeldUser`) and its epoch.
    ///
    /// `/v1/config` sends no user: the server buckets `u:` on the user its device row holds
    /// (`config-evaluation-context.ts`). The app's own user id moves the moment `identify()` is
    /// called, before the POST that changes the row, and that POST can fail or go unanswered, so
    /// it cannot label a config. The label is read when a request STARTS; if its epoch has moved
    /// by the time the response lands, the row may have changed underneath the request, and the
    /// response is applied as `.unknown` instead.
    private let identityProvider: @Sendable () -> (identity: ConfigIdentity, epoch: UInt64)
    /// The client's current device id (`ContextManager.deviceId`, the lock a replacement's swap
    /// writes under). A response fetched for another id is discarded (`isCurrentDevice`). Nil for a
    /// `ConfigSync` built on its own: no check.
    private let currentDeviceId: (@Sendable () -> String)?
    private var etag: String?
    /// The `resetGate` token `etag` was stored under. An ETag from before a `reset()` is never
    /// sent: it validates the logged-out user's body.
    private var etagResetToken: UInt64 = 0
    /// Shared with `SheepitClient.reset()`; see `ConfigResetGate`.
    private let resetGate: ConfigResetGate
    /// How old a cached body may be at launch, and when it counts as stale (`CachedConfigLimits`).
    private let limits: CachedConfigLimits
    /// The SDK's clock: every cache stamp and age is measured with it, so tests can age a cache.
    private let now: @Sendable () -> Date
    /// Shared with `SheepitClient` (`status()`, exposure events) and cleared by its `reset()`.
    private let freshness: ConfigFreshnessRecorder
    private var refreshTask: Task<Void, Never>?
    /// Start order of fetches. Actor methods re-enter at every `await`, so two fetches can be in
    /// flight at once (the refresh loop and an identify-triggered refetch) and their responses can
    /// land in either order. Only a response that STARTED after the last applied one is applied;
    /// otherwise an older body, labelled with an older user, would overwrite a newer one.
    private var requestSequence = 0
    private var lastAppliedSequence = 0
    /// Set by `refetchUnconditionally`. While set, every fetch omits `If-None-Match`.
    ///
    /// 🔴 Sticky because the unconditional refetch can fail (5xx, network). As a one-shot, the
    /// previous validator was still held afterwards, every later poll answered 304, and the
    /// previous row's config stayed applied under its old label: the identify latch again. It is
    /// cleared only when an unconditional request that started while it was set has its 2xx body
    /// applied; a 2xx discarded by the sequence or reset guards does not clear it.
    private var needsUnconditional = false
    /// Moved whenever an unconditional refetch is newly owed (`refetchUnconditionally`, a replaced
    /// registration id), as `etagResetToken` is by `reset()`. A fetch that
    /// started under an older token may neither clear `needsUnconditional` nor store its ETag.
    ///
    /// 🔴 Without it, a poll sent unconditional because an EARLIER refetch failed, landing after
    /// a newer one was owed (an identify whose bind settled unbound while that poll was on the
    /// wire), released the flag and kept its ETag. The settle's own refetch could fail, so every
    /// later poll was a 304 that applied nothing, and the identity switch, which only a server
    /// fetch started after the settle may end, stayed armed until relaunch.
    private var unconditionalToken: UInt64 = 0
    /// The `X-Device-ID` of the last APPLIED server body whose response said `resolved`; a server body
    /// with no resolution header clears it, and the launch cache never sets it: either may or may not
    /// have been evaluated for the device's row. Read by `refetchAfterRegistration`.
    private var resolvedDeviceId: String?
    /// The `resetGate` token `resolvedDeviceId` was recorded under: `reset()` clears what is applied.
    private var resolvedResetToken: UInt64 = 0
    /// The record was seeded at launch from the cache's resolved stamp (`sdkConfigResolvedFor`), not
    /// by a body applied in this process. It arms C5 only: a launch-cache body never counts as an
    /// applied resolved body for `refetchAfterRegistration` (contract § 1 (2)).
    private var resolvedFromCache = false
    /// C5 ITSELF mints at most one device per launch and reset generation (contract § 7); a joined
    /// replacement is the identify 404's and spends nothing, so two devices can still be replaced
    /// in one launch (SK-Q17 (5)). The `resetGate` token of the generation whose C5 registration
    /// was answered. Spent by that mint only (`ErasedDeviceOutcome.minted`), never by the trigger: a
    /// joined replacement, an adoption or a failed attempt mints nothing for C5. Keyed on the
    /// token, so a `reset()` releases it for the device the logout ends on (SK-Q16). Locked: the
    /// rotation spends it from its registration.
    private nonisolated let replacementCapSpentUnder = LockedValue<UInt64?>(nil)
    /// The `unknown_device` body that fired C5, kept until the replacement settles: if nothing
    /// replaces the erased device, its defaults are applied in memory (`applyErasedDefaults`).
    private var erasedBody: (data: Data, sequence: Int, resetToken: UInt64)?
    /// What the rotation did with a C5 trigger (`onResolvedDeviceUnknown`).
    enum ErasedDeviceClaim: Sendable, Equatable {
        /// The client is no longer on that id, or is gone: nothing was started.
        case notCurrent
        /// Still on it, but the cap is spent: nothing was started (the outcome was nil).
        case capped
        /// Joined a replacement already registering for it (an identify 404's).
        case joined
        /// Started a replacement.
        case replacing
    }
    /// What C5 hands the rotation, so the outcome of the replacement comes back here.
    struct ErasedDeviceOutcome: Sendable {
        /// The registration C5 itself started was answered with a device: spends the cap.
        let minted: @Sendable () -> Void
        /// Nothing replaced the erased device (failed, deferred, out of budget): drop its values.
        let unreplaced: @Sendable () async -> Void
    }
    /// C5 (contract § 7): `unknown_device` for the device `resolvedDeviceId` names, so its row was
    /// erased or purged. `SheepitClient` sets it to `DeviceRotation.replaceErasedDevice`, which says
    /// what it did (`ErasedDeviceClaim`); a nil outcome means capped: report only whether the
    /// device is still current. Called inside the actor, so it must only start work, never wait.
    nonisolated let onResolvedDeviceUnknown = LockedValue<(@Sendable (String, ErasedDeviceOutcome?) -> ErasedDeviceClaim)?>(nil)
    /// The `resetGate` token under which a real body (cached, or a server body that was not refused)
    /// was last applied; nil before any. While it equals the current token, an unresolved body is
    /// refused outright; otherwise it may be applied to memory only (`onProvisional`).
    private var realBodyResetToken: UInt64?
    /// Start order of the last provisional (memory-only) apply, so an older one never replaces it.
    private var lastProvisionalSequence = 0
    /// Set once a 2xx without the resolution header was reported (`config.resolution_header_absent`).
    private var reportedAbsentResolution = false
    /// The `X-Device-ID` of the last 2xx answered unresolved, until a body is applied. A 304 for that
    /// device confirms nothing (`confirmCachedBody`): the server answers 304 before it looks the
    /// device up, so with no age limit a re-stamp would keep a body the server can no longer
    /// evaluate for this device reported fresh, and kept, forever.
    private var unresolvedDeviceId: String?
    /// The launch cache apply (`applyLaunchCache()`), which runs OFF the actor: whether the launch
    /// slot is taken (by that apply, or by a server body applied first) and the reset token the
    /// cache was applied under, which `handleUnresolved` reads as `realBodyResetToken`'s twin.
    /// Only ever touched inside `resetGate` or on its own, so the lock order is always gate → this.
    private let launchCache = OSAllocatedUnfairLock(initialState: LaunchCacheState())
    /// Set by a known-to-known user change (`dropPersistedCacheForUserChange(newUserId:)`): the
    /// reset token it ran under and the NEW user's label, the only one written to disk while it
    /// holds; nil when no hold is on. Taken inside `resetGate`.
    private let persistHold = OSAllocatedUnfairLock<PersistHold?>(initialState: nil)
    private let diagnostics: DiagnosticBus?

    init(
        http: HTTPClient,
        storage: StorageProvider,
        refreshInterval: TimeInterval,
        log: Logger,
        resetGate: ConfigResetGate = ConfigResetGate(),
        limits: CachedConfigLimits = .default,
        now: @escaping @Sendable () -> Date = { Date() },
        freshness: ConfigFreshnessRecorder = ConfigFreshnessRecorder(),
        diagnostics: DiagnosticBus? = nil,
        identityProvider: @escaping @Sendable () -> (identity: ConfigIdentity, epoch: UInt64),
        currentDeviceId: (@Sendable () -> String)? = nil,
        onConfig: @escaping @Sendable (SDKConfigResponse, ConfigIdentity, ConfigApplyOrigin) -> Void,
        onProvisional: @escaping @Sendable (SDKConfigResponse) -> Void = { _ in },
        onApplied: @escaping @Sendable () -> Void = {}
    ) {
        self.http = http
        self.storage = storage
        self.refreshInterval = refreshInterval
        self.log = log
        self.identityProvider = identityProvider
        self.currentDeviceId = currentDeviceId
        self.onConfig = onConfig
        self.onProvisional = onProvisional
        self.onApplied = onApplied
        self.resetGate = resetGate
        self.limits = limits
        self.now = now
        self.freshness = freshness
        self.diagnostics = diagnostics
    }

    /// Start sync: apply the launch cache if that has not happened yet, then fetch periodically.
    ///
    /// `SheepitClient.start()` has normally applied the cache already (`applyLaunchCache()`,
    /// synchronously, before the client reaches the app), so the call here is a no-op; it remains
    /// for a `ConfigSync` started on its own.
    ///
    /// - Parameter onRefreshTick: called before every periodic fetch except the launch one, so a
    ///   host can re-send work that is due at most once per refresh interval (the identify retry).
    func start(
        deviceIdGetter: @escaping @Sendable () -> String,
        onRefreshTick: @escaping @Sendable () -> Void = {}
    ) {
        // A fetch that already applied is newer than anything on disk (it also took the launch slot).
        if lastAppliedSequence == 0 { applyLaunchCache(deviceId: deviceIdGetter()) }

        // Start periodic refresh
        refreshTask = Task {
            var isLaunchFetch = true
            while !Task.isCancelled {
                if !isLaunchFetch { onRefreshTick() }
                isLaunchFetch = false
                await fetchConfig(deviceId: deviceIdGetter())
                // `refreshInterval` came from the mutable public
                // `SheepitConfig.configRefreshInterval` — sanitize right before use rather
                // than trusting the initializer clamp already applied to it (2026-09 security
                // follow-up round 3, finding MF-1).
                try? await Task.sleep(for: .seconds(refreshInterval.sanitizedForSleep()))
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// Force a config refresh.
    func refresh(deviceId: String) async {
        await fetchConfig(deviceId: deviceId)
    }

    /// Fetch with no `If-None-Match`, whatever validator is held, keeping the cached body and
    /// what is applied until the response lands.
    ///
    /// 🔴 Called once an identify POST succeeds. The ETag carries no user and identifying moves no
    /// `config_version`, so a conditional fetch after `identify()` would 304 forever and the
    /// previous user's body would stay applied. One call rather than "drop the ETag, then
    /// refresh": between two actor entries a concurrent fetch can store an ETag again, and the
    /// refresh would then send it. If this request fails, every later fetch stays unconditional
    /// until one of them is applied (`needsUnconditional`).
    func refetchUnconditionally(deviceId: String) async {
        // Set inside this same actor call, before the request is built: see `needsUnconditional`.
        needsUnconditional = true
        unconditionalToken &+= 1
        await fetchConfig(deviceId: deviceId)
    }

    /// The refetch a registration answer owes (contract § 1 and § 7,
    /// `Docs/Technical/SDK_DEVICE_REGISTRATION_CONTRACT.md`).
    ///
    /// - Replaced id: always, unconditionally and sticky (`needsUnconditional`), as before.
    /// - Accepted id: ONE unconditional request, unless a body the server answered `resolved` for
    ///   `deviceId`, since the last `reset()`, is already applied. Config sync starts alongside
    ///   registration, so a fresh install's launch fetch names a device with no row and is refused;
    ///   without this the app read its defaults until the next poll (300 s by default). One-shot,
    ///   not sticky: a failed attempt leaves the next poll conditional, so a 304 still re-stamps the
    ///   cache (`confirmCachedBody`), and a refused one keeps nothing.
    ///
    /// 🔴 Dropped (no request) when `deviceId` is no longer the client's device or the client was
    /// destroyed (`isCurrent`), as in sdk-js. A logout that rotates moves the id first, so a refetch
    /// naming the abandoned device, whose row may still hold the logged-out user, never goes out. A
    /// `reset()` that KEEPS the device does not drop it: no user is bound to that row. The reset
    /// token is read BEFORE `isCurrent()`, and the request is applied only under it: every logout
    /// rotation is followed by a gate bump (`SheepitClient.reset()`; the identify-404 swap is not), so a logout landing between the two
    /// reads, or while the request is on the wire, gets the answer discarded by the gate.
    func refetchAfterRegistration(
        deviceId: String,
        replaced: Bool,
        isCurrent: @Sendable () -> Bool
    ) async {
        let issuedUnder = resetGate.current
        let skip: String?
        if !isCurrent() {
            skip = "superseded"
        } else if !replaced, !resolvedFromCache, resolvedDeviceId == deviceId, resolvedResetToken == issuedUnder {
            skip = "resolved_applied"
        } else {
            skip = nil
        }
        if let skip {
            diagnostics?.emit(
                .debug,
                .config,
                code: "config.registration_refetch_skipped",
                message: "No config refetch after the registration answer (\(skip))",
                data: ["reason": AnyCodable(skip)]
            )
            return
        }
        diagnostics?.emit(
            .info,
            .config,
            code: "config.refetch_on_registration",
            message: replaced
                ? "Device registered under a replaced id — refetching config"
                : "Device registered with no resolved config applied for it — refetching config now",
            data: ["outcome": AnyCodable(replaced ? "replaced" : "proposed")]
        )
        // Set inside this same actor call, before the request is built: see `needsUnconditional`.
        if replaced {
            needsUnconditional = true
            unconditionalToken &+= 1
        }
        await fetchConfig(deviceId: deviceId, resetTokenAtStart: issuedUnder, omitValidator: true)
    }

    // MARK: - Private

    /// - Parameters:
    ///   - resetTokenAtStart: the token the response must still match to be applied; the current one
    ///     when nil. A caller that decided to fetch earlier passes the token it decided under.
    ///   - omitValidator: no `If-None-Match` on this request only (`needsUnconditional` is sticky).
    private func fetchConfig(deviceId: String, resetTokenAtStart expectedToken: UInt64? = nil, omitValidator: Bool = false) async {
        let resetTokenAtStart = expectedToken ?? resetGate.current
        // The reset gate's clear runs outside the actor, so a stash from before a `reset()` is
        // dropped here, at the next fetch after the reset (`applyErasedDefaults` refuses one from an
        // older token). A successful replacement whose refetch 304s leaves its stash in place until
        // a body applies or a reset; it is inert, since only `unreplaced` reads it (SK-Q21).
        if let stash = erasedBody, stash.resetToken != resetGate.current { erasedBody = nil }
        requestSequence += 1
        let sequence = requestSequence
        let fetchNumber = fetchesStarted.next()
        // Before the await: see `identityProvider`.
        let (identityAtRequest, epochAtRequest) = identityProvider()
        var headers: [String: String] = ["X-Device-ID": deviceId]
        let unconditional = needsUnconditional
        let unconditionalTokenAtStart = unconditionalToken
        var sentValidator = false
        if !unconditional, !omitValidator, let etag, etagResetToken == resetTokenAtStart {
            headers["If-None-Match"] = etag
            sentValidator = true
        }

        do {
            // 🔴 Never from the URL cache. A resolved `/v1/config` 200 carries
            // `Cache-Control: private, max-age=60`, so the shared `URLCache` would answer a repeat
            // within 60 s without a request, including the unconditional refetch after identify,
            // and hand back the previous row's body under the new label. The SDK revalidates with
            // its own ETag.
            let (data, response) = try await http.getRaw(
                path: SDKEndpoints.config,
                extraHeaders: headers,
                cachePolicy: .reloadIgnoringLocalCacheData
            )

            // 304 Not Modified
            if response.statusCode == 304 {
                log.debug("Config unchanged (304)")
                confirmCachedBody(sentValidator: sentValidator, sequence: sequence, resetTokenAtStart: resetTokenAtStart,
                                  deviceId: deviceId)
                return
            }

            guard (200...299).contains(response.statusCode) else {
                log.warn("Config fetch failed: HTTP \(response.statusCode)")
                return
            }

            // 🔴 A 2xx the server could not resolve the device for (`DeviceResolution`) is never
            // cached and its ETag is never kept; nothing applied or on disk is touched, and an owed
            // unconditional fetch stays owed. It reaches memory only while nothing else is applied.
            let resolution = DeviceResolution(header: response.value(forHTTPHeaderField: DeviceResolution.headerName))
            if resolution.refuses {
                handleUnresolved(data: data, resolution: resolution, statusCode: response.statusCode, deviceId: deviceId,
                                 sequence: sequence, resetTokenAtStart: resetTokenAtStart,
                                 unconditional: unconditional || omitValidator)
                return
            }
            if resolution == .absent, !reportedAbsentResolution {
                // Once per client: a server older than the header, or a proxy that strips it. Both
                // turn the refusal above off, so the second must not be silent.
                reportedAbsentResolution = true
                diagnostics?.emit(
                    .info,
                    .config,
                    code: "config.resolution_header_absent",
                    message: "/v1/config sent no \(DeviceResolution.headerName) header — an unresolved answer cannot be told apart"
                )
            }

            // Parse the config response
            let configResponse = try JSONDecoder().decode(ApiDataResponse<SDKConfigResponse>.self, from: data)
            let sdkConfig = configResponse.data
            let receiptSafeData = AssignmentReceipt.cacheData(data, config: sdkConfig)

            // Checked before the ETag is taken too: an older response must not replace the
            // validator of a newer one.
            guard sequence > lastAppliedSequence else {
                log.debug("Config response discarded — a later fetch already applied")
                return
            }

            // 🔴 A label decision landed while the request was on the wire (an `identify()`, an
            // identify POST answering, a device id adopted): the row this body was bucketed for is
            // no longer known. It is still applied, so `experiment()` keeps answering, but as
            // `.unknown`. Its ETag is NOT kept and any older one is dropped: otherwise every later
            // poll would 304 against this body and the unknown label would latch until relaunch.
            let labelStillValid = identityProvider().epoch == epochAtRequest
            let identity: ConfigIdentity = labelStillValid ? identityAtRequest : .unknown

            // 🔴 Written and applied inside the reset gate, and only if no `reset()` ran since this
            // request started (`ConfigResetGate`). Otherwise this continuation would write the
            // logged-out user's body back to disk after `reset()` wiped it, and apply it to memory.
            //
            // The cache is the raw response, with the time it was written and the user it was
            // fetched under alongside. The label goes FIRST as a removal and LAST as a write, so a
            // process killed between the writes leaves a body with no label (unknown), never a body
            // with another fetch's label.
            var deviceLeft = false
            let applied = resetGate.ifNotReset(since: resetTokenAtStart) {
                // 🔴 Fetched for a device the client has since left (a C5 or identify-404
                // replacement swapped in a fresh id; the swap does not move the reset gate):
                // discarded, memory and disk, as a post-registration refetch for a left id is.
                // Written, this body and its stamp for the erased id would outlive the swap's
                // drop (`dropPersistedCacheForDeviceReplacement`), and with no age limit every
                // launch on the fresh id would apply it with C5 disarmed (the stamp names another
                // id). Applied, it would shield the erased device's values in memory. Read here,
                // inside the gate the drop also takes, after the swap's write: a body checked
                // before the swap is written before the drop, which then deletes it.
                guard isCurrentDevice(deviceId) else {
                    deviceLeft = true
                    return
                }
                // A server body is newer than the cache on disk: a launch apply after it must not
                // put the older body back (`applyLaunchCache()`), and the resolved record it may
                // have seeded is superseded by this body's own (`adoptLaunchResolvedRecord()`).
                launchCache.withLock { $0.claimed = true; $0.resolvedFor = nil }
                let fetchedAt = now()
                // 🔴 After `identify()` moved from one known user to another
                // (`dropPersistedCacheForUserChange(newUserId:)`), nothing is written to disk until
                // a body fetched for a row known to hold the NEW user lands. Until then the row may
                // hold the previous user, or a third one (an earlier identify whose POST answered
                // late: `ServerHeldUser` labels the row, not the app's user), and with no age limit
                // an offline relaunch would apply that body to the new user forever. Such a body is
                // applied to memory only. An ALLOW-list on the new user, never a deny-list on the
                // previous one: a deny-list let a third user's body through. The label is re-read
                // here, inside the gate the drop also runs in, so a drop landing after the read
                // above is not missed, and a response landing between the drop and the identify's
                // epoch move carries a label other than the new user's, so it is held too.
                let persistIdentity: ConfigIdentity = identityProvider().epoch == epochAtRequest ? identity : .unknown
                let hold = persistHold.withLock { $0 }
                let persistHeld = hold?.token == resetTokenAtStart
                let persist = !persistHeld || persistIdentity == hold?.required
                if persist, persistHeld { persistHold.withLock { $0 = nil } }
                // The C5 resolved stamp rides with the body: a held body writes neither, so the
                // body and the stamp on disk always describe the same response. The in-memory C5
                // record is not held (`resolvedDeviceId`, set below).
                if persist, data.count > SDKDefaults.configCacheMaxBytes {
                    // Kept in memory only (applied below). The older body on disk is deleted, not
                    // left behind: it describes a config the server has since replaced.
                    for key in [StorageKeys.sdkConfig, StorageKeys.sdkConfigCachedAt,
                                StorageKeys.sdkConfigFetchedUnder, StorageKeys.sdkConfigResolvedFor] {
                        storage.removeObject(forKey: key)
                    }
                    diagnostics?.emit(
                        .warn,
                        .config,
                        code: "config.cache_too_large",
                        message: "The config body is \(data.count) bytes, over the \(SDKDefaults.configCacheMaxBytes)-byte cache limit; it is applied but not cached, so an offline launch uses defaults",
                        data: ["bytes": AnyCodable(data.count), "limit": AnyCodable(SDKDefaults.configCacheMaxBytes)]
                    )
                } else if persist {
                    storage.removeObject(forKey: StorageKeys.sdkConfigFetchedUnder)
                    storage.removeObject(forKey: StorageKeys.sdkConfigResolvedFor)
                    storage.set(receiptSafeData, forKey: StorageKeys.sdkConfig)
                    storage.set(String(fetchedAt.timeIntervalSince1970), forKey: StorageKeys.sdkConfigCachedAt)
                    if let label = try? JSONEncoder().encode(ServerHeldUser(identity)) {
                        storage.set(label, forKey: StorageKeys.sdkConfigFetchedUnder)
                    }
                    // Last, like the label: a kill between the writes leaves a body with no stamp
                    // (not resolved), never another body's.
                    if resolution == .resolved { storage.set(deviceId, forKey: StorageKeys.sdkConfigResolvedFor) }
                }
                onConfig(sdkConfig, identity, .server(fetch: fetchNumber))
                freshness.record(.server, fetchedAt: fetchedAt)
            }
            guard applied, !deviceLeft else {
                log.debug(deviceLeft
                    ? "Config response discarded — fetched for a device the client has since replaced"
                    : "Config response discarded — reset() while in flight")
                return
            }
            onApplied()

            lastAppliedSequence = sequence
            // A real body applied: the replacement's defaults are moot (`applyErasedDefaults`).
            erasedBody = nil
            realBodyResetToken = resetTokenAtStart
            // Applied under a label that held for the whole request, so an unconditional request
            // may now release the flag. A body applied `.unknown` because a label decision landed
            // mid-request does not: the row it was owed for is still unanswered. Nor does one
            // started before the latest owed refetch: see `unconditionalToken`.
            let owedRefetchAnswered = unconditionalToken == unconditionalTokenAtStart
            if unconditional, labelStillValid, owedRefetchAnswered { needsUnconditional = false }
            etag = labelStillValid && owedRefetchAnswered ? sdkConfig.etag : nil
            etagResetToken = resetTokenAtStart
            // The body now applied is the device's only when the server said so.
            resolvedDeviceId = resolution == .resolved ? deviceId : nil
            resolvedResetToken = resetTokenAtStart
            unresolvedDeviceId = nil
            resolvedFromCache = false

            log.debug("Config updated (v\(sdkConfig.configVersion))")
            diagnoseAssignmentReceipt(sdkConfig.rawAssignmentToken)

        } catch {
            log.warn("Config fetch error: \(error.localizedDescription)")
        }
    }

    /// An unresolved 2xx (`DeviceResolution`): applied to memory only when no real body has been
    /// applied since launch or the last `reset()` (what is applied, if anything, is itself
    /// memory-only, and a newer one replaces it), so a device that never registers still gets the
    /// server's defaults and kill switches; refused otherwise (contract § 7). Never cached, ETag never kept,
    /// `needsUnconditional` and `lastAppliedSequence` untouched, labelled with no user.
    private func handleUnresolved(
        data: Data,
        resolution: DeviceResolution,
        statusCode: Int,
        deviceId: String,
        sequence: Int,
        resetTokenAtStart: UInt64,
        unconditional: Bool
    ) {
        // C5 across launches: the record the launch cache seeded off the actor is taken here, the
        // only place that reads it before a server body replaces it.
        adoptLaunchResolvedRecord()
        // The server no longer has the row a resolved body was recorded for (erased or purged): the
        // next registration must refetch. Only `unknown_device`: a `lookup_error` is a server
        // failure, not evidence the row is gone, and an unrecognized value says nothing either, so
        // both leave the record. Only an answer that started after the body applied, under the token
        // the record was made under and with no `reset()` since: a stale one landing after a newer
        // resolved body leaves the record (SK-Q10). The sequence guard is Swift-only: sdk-js never
        // has two config fetches in flight, so it has no stale answer to guard against.
        if resolution == .unresolved(DeviceResolution.unknownDevice), resolvedDeviceId == deviceId,
           resolvedResetToken == resetTokenAtStart, resetGate.current == resetTokenAtStart,
           sequence > lastAppliedSequence {
            resolvedDeviceId = nil
            // C5: the row is gone, so the device is replaced as after an identify 404. Cleared
            // first, so a later `unknown_device` for it cannot trigger it again; capped at one
            // replacement per launch, so a replacement whose own row then disappears is not chased.
            let capped = replacementCapSpentUnder.value == resetTokenAtStart
            let (cap, gate) = (replacementCapSpentUnder, resetGate)
            let outcome = capped ? nil : ErasedDeviceOutcome(
                minted: { if gate.current == resetTokenAtStart { cap.value = resetTokenAtStart } },
                unreplaced: { [weak self] in
                    await self?.applyErasedDefaults(sequence: sequence, resetToken: resetTokenAtStart)
                }
            )
            let claim = onResolvedDeviceUnknown.value?(deviceId, outcome) ?? .notCurrent
            let reason: String
            switch claim {
            case .notCurrent:
                // The client already left the id (an identify 404 swapped it, which does not move
                // the reset gate) or is gone: nothing to replace, so nothing to report or keep, as
                // sdk-js returns before its diagnostic.
                reason = ""
            case .capped:
                // Kept, but its values go: the provisional apply below puts the server's defaults
                // (kill switches included) in memory, and later answers are not refused.
                dropRealBody()
                reason = "capped"
            case .joined, .replacing:
                erasedBody = (data, sequence, resetTokenAtStart)
                reason = claim == .joined ? "joined" : "resolved_then_unknown"
            }
            let joined = claim == .joined
            if !reason.isEmpty { diagnostics?.emit(
                .warn,
                .config,
                code: "config.device_replaced_unknown",
                message: capped
                    ? "/v1/config no longer knows a device it resolved before — not replaced: one was already replaced since launch or the last reset()"
                    : joined
                        ? "/v1/config no longer knows a device it resolved before — joining the replacement already registering"
                        : "/v1/config no longer knows a device it resolved before — registering a fresh device",
                data: ["reason": AnyCodable(reason)]
            ) }
        }
        // Only from a response newer than the last applied body: a stale unresolved answer landing
        // after a resolved one would otherwise latch the 304 re-stamp off for the whole process.
        if sequence > lastAppliedSequence { unresolvedDeviceId = deviceId }
        var appliedToMemory = false
        var appliedReceipt: AnyCodable?
        if sequence > lastAppliedSequence {
            // Decoded only when it could reach memory; the stale mark below needs no body, so an
            // answer that fails to decode, or is older than the memory-only body, still sets it.
            let body = sequence > lastProvisionalSequence
                ? try? JSONDecoder().decode(ApiDataResponse<SDKConfigResponse>.self, from: data) : nil
            // 🔴 Whether a real body is applied is decided INSIDE the gate: the launch apply runs
            // off the actor and records its token in the same critical section it applies in, so a
            // check made before the gate could let this body replace a launch cache applied between
            // the check and the apply.
            _ = resetGate.ifNotReset(since: resetTokenAtStart) {
                if realBodyApplied(under: resetTokenAtStart) {
                    // The applied body can no longer be evaluated for this device: report it stale
                    // until a body is applied again. Every unresolved outcome, `lookup_error` too
                    // (sdk-js skips `lookup_error`): the body cannot be confirmed either way.
                    freshness.markDeviceUnresolved()
                } else if let body {
                    onProvisional(body.data)
                    appliedReceipt = body.data.rawAssignmentToken
                    appliedToMemory = true
                }
            }
            if appliedToMemory { lastProvisionalSequence = sequence }
        }
        log.warn(appliedToMemory
            ? "Config response for an unresolved device (\(resolution.outcome)) — nothing else applied, so it is applied to memory only, never cached"
            : "Config response refused — the server could not resolve this device (\(resolution.outcome)); keeping the config already applied")
        diagnostics?.emit(
            .warn,
            .config,
            code: "config.unresolved_body_refused",
            message: appliedToMemory
                ? "/v1/config answered for an unresolved device (\(resolution.outcome)) — applied to memory only, not cached"
                : "/v1/config answered for an unresolved device (\(resolution.outcome)) — not applied or cached",
            data: [
                "outcome": AnyCodable(resolution.outcome),
                "status_code": AnyCodable(statusCode),
                "unconditional": AnyCodable(unconditional),
                "applied_memory_only": AnyCodable(appliedToMemory),
            ]
        )
        if appliedToMemory { diagnoseAssignmentReceipt(appliedReceipt) }
    }

    /// The launch cache is applied off the actor (`applyLaunchCache(deviceId:)`), so the resolved
    /// record it seeds is moved into the actor's own here, once. It arms C5 only
    /// (`resolvedFromCache`): it never counts as an applied resolved body for
    /// `refetchAfterRegistration` (contract § 1 (2)). Never once a server body applied: that body
    /// cleared the seed in the critical section it applied in, and recorded its own.
    private func adoptLaunchResolvedRecord() {
        guard let seed = launchCache.withLock({ state -> (deviceId: String, resetToken: UInt64)? in
            defer { state.resolvedFor = nil }
            return state.resolvedFor
        }), lastAppliedSequence == 0 else { return }
        resolvedDeviceId = seed.deviceId
        resolvedResetToken = seed.resetToken
        resolvedFromCache = true
    }

    /// `deviceId` is still the client's device. Always true without a `currentDeviceId` source.
    private nonisolated func isCurrentDevice(_ deviceId: String) -> Bool {
        currentDeviceId.map { $0() == deviceId } ?? true
    }

    /// Whether a real body (the launch cache, or a server body that was not refused) was applied
    /// under `token`. The launch cache's token lives in `launchCache`: it is applied off the actor.
    private func realBodyApplied(under token: UInt64) -> Bool {
        realBodyResetToken == token || launchCache.withLock({ $0.appliedUnder }) == token
    }

    /// Nothing real is applied any more (neither a server body nor the launch cache): the erased
    /// device's body stops shielding it, so the unresolved answers that follow reach memory
    /// (`handleUnresolved`). Its ETag goes with it. The cache and its resolved stamp stay on disk,
    /// so the next launch retries the replacement once.
    private func dropRealBody() {
        realBodyResetToken = nil
        launchCache.withLock { $0.appliedUnder = nil }
        etag = nil
    }

    /// C5's replacement did not take over: the device keeps the erased id, but the erased row's
    /// values are dropped and the `unknown_device` body that fired C5 (the server's defaults, kill
    /// switches included) is applied to memory only. Not if a `reset()` ran or a real body applied
    /// since: those are newer.
    func applyErasedDefaults(sequence: Int, resetToken: UInt64) {
        guard let stash = erasedBody, stash.sequence == sequence, stash.resetToken == resetToken else { return }
        erasedBody = nil
        guard resetGate.current == resetToken, sequence > lastAppliedSequence, sequence > lastProvisionalSequence,
              let body = try? JSONDecoder().decode(ApiDataResponse<SDKConfigResponse>.self, from: stash.data)
        else { return }
        dropRealBody()
        if resetGate.ifNotReset(since: resetToken, { onProvisional(body.data) }) {
            lastProvisionalSequence = sequence
            log.warn("No replacement for the erased device — its values were dropped; the server's defaults apply in memory")
            diagnoseAssignmentReceipt(body.data.rawAssignmentToken)
        }
    }

    /// A 304 confirms that the body applied, and on disk, is still the server's current one: the
    /// stored stamp moves to now, as an HTTP cache freshens a stored response (RFC 9111 §4.3.4).
    ///
    /// 🔴 Without this a process that stays alive and polls into 304s keeps the stamp of its last
    /// 200, which can be days old, and the next launch that cannot reach the server reports stale,
    /// or with a host-set `configOfflineMaxAge` drops, a body the server confirmed minutes earlier.
    ///
    /// Only for a request that sent the validator (an unconditional request answered 304 is
    /// unexplained, so it confirms nothing), that started after the last applied body (an older
    /// request's 304 refers to an older validator), while no unconditional refetch is owed, and
    /// inside the reset gate, so a 304 landing after `reset()` writes nothing back.
    ///
    /// 🔴 And only while the stored label and what the server's row is known to hold now are BOTH
    /// known and equal. The ETag carries no user, so a 304 says nothing about who the body was
    /// bucketed for. After an `identify()` whose POST committed but whose answer was lost, or was
    /// refused while `/v1/config` still answers, the row's state is `.unknown`, no unconditional
    /// refetch is owed, and every poll 304s against the previous user's body. Re-stamping there
    /// kept that body fresh forever, so offline launches reported it fresh, and applied it past a
    /// host-set `configOfflineMaxAge`.
    /// Skipping leaves the stamp at the last 200, the 0.8.0 behaviour. `.unknown == .unknown` is
    /// not a match: it says nothing about the row.
    ///
    /// 🔴 And never for a device whose last 2xx was unresolved (`unresolvedDeviceId`).
    private func confirmCachedBody(sentValidator: Bool, sequence: Int, resetTokenAtStart: UInt64, deviceId: String) {
        guard sentValidator, sequence > lastAppliedSequence, !needsUnconditional,
              unresolvedDeviceId != deviceId else { return }
        let current = identityProvider().identity
        guard case .fetchedUnder = current else { return }
        resetGate.ifNotReset(since: resetTokenAtStart) {
            // A 304 for a device the client has left confirms nothing on disk now.
            guard isCurrentDevice(deviceId), storage.data(forKey: StorageKeys.sdkConfig) != nil,
                  let label = storage.data(forKey: StorageKeys.sdkConfigFetchedUnder)
                    .flatMap({ try? JSONDecoder().decode(ServerHeldUser.self, from: $0) }),
                  label.configIdentity == current
            else { return }
            let confirmedAt = now()
            storage.set(String(confirmedAt.timeIntervalSince1970), forKey: StorageKeys.sdkConfigCachedAt)
            freshness.confirm(at: confirmedAt)
        }
    }

    /// Drop the cached config and its validator. Never called because a fetch failed; the launch
    /// drop (`applyLaunchCache()`) deletes the stored keys itself, inside the reset gate.
    ///
    /// 🔴 NOT called by `SheepitClient.reset()` any more. Logout clears synchronously through
    /// `ConfigResetGate`; a clear sent to this actor ran at an arbitrary later time and deleted
    /// whatever cache was on disk by then, including one written after the reset.
    func clearCache() {
        // 🔴 The ETag must go too. `If-None-Match` is keyed on
        // (project, environment, device, headers, config_version) with NO user
        // component, and `config_version` moves only on a flag edit — so
        // clearing the body alone makes the next poll 304 and `onConfig` never
        // fires again. That is worse than the leak: it turns "the previous
        // user's values" into "no values at all until the app restarts".
        etag = nil
        // `needsUnconditional` is left as it is: with no ETag the next fetch is unconditional
        // anyway, and only an applied body may clear it.
        removeStoredBody()
    }

    /// `identify()` from one known user to another: delete the persisted body, keep memory, and
    /// hold further disk writes (`persistHold`) until a body fetched for a row known to hold
    /// `newUserId` is applied. That body ends the hold.
    ///
    /// Synchronous, inside the reset gate, so it is serialized with every fetch's disk write. Runs
    /// BEFORE the app's user changes (`SheepitClient.dispatchIdentify`), so a process killed in
    /// between never relaunches as the new user over the previous user's body. A response already
    /// in flight cannot write its body back: landing before the identify moves the identity epoch,
    /// its label is whatever the row held then (the previous user, or another), never `newUserId`
    /// unless the row already holds the new user; after, it reads unknown. The token is not
    /// bumped: this is not a logout, nothing in flight is discarded, and the ETag stays (it carries
    /// no user; the identify refetch omits it anyway). A `reset()` ends the hold: it is recorded
    /// under the current token.
    nonisolated func dropPersistedCacheForUserChange(newUserId: String) {
        let token = resetGate.current
        resetGate.ifNotReset(since: token) {
            removeStoredBody()
            persistHold.withLock { $0 = PersistHold(token: token, required: .fetchedUnder(newUserId)) }
        }
    }

    /// A replacement (C5, or an identify 404) swapped `freshId` in for a device the server no longer
    /// knows: delete the persisted body, keep memory. That body, and its C5 stamp, were fetched for
    /// the erased row. SheepitKit keeps ONE body, not one per device (sdk-js keys a slot per device
    /// and drops the erased one, `dropDeviceSlot`), so nothing accumulates, but with no age limit
    /// nothing else would remove it either: every offline launch on the fresh id would apply the
    /// erased row's flags and assignments until a fetch lands (SK-Q18).
    ///
    /// Called only on a successful swap (`DeviceRotation`): a failed or deferred replacement keeps
    /// the body and the stamp, so the next launch retries C5. Inside the reset gate, like every
    /// fetch's write. A body already stamped `resolved` for `freshId` is the fresh device's own
    /// (its refetch landed first) and is kept.
    nonisolated func dropPersistedCacheForDeviceReplacement(freshId: String) {
        let token = resetGate.current
        resetGate.ifNotReset(since: token) {
            guard storage.string(forKey: StorageKeys.sdkConfigResolvedFor) != freshId else { return }
            removeStoredBody()
        }
    }

    /// Whether a known-to-known hold is on, under the current reset token.
    nonisolated var persistHeldForTesting: Bool {
        let token = resetGate.current
        return persistHold.withLock { $0?.token == token }
    }

    private nonisolated func removeStoredBody() {
        storage.removeObject(forKey: StorageKeys.sdkConfig)
        storage.removeObject(forKey: StorageKeys.sdkConfigCachedAt)
        storage.removeObject(forKey: StorageKeys.sdkConfigFetchedUnder)
        storage.removeObject(forKey: StorageKeys.sdkConfigResolvedFor)
    }

    /// Apply the config cached on the device to memory, synchronously, on the caller's thread.
    ///
    /// 🔴 Called by `SheepitClient.start()` before `create(config:)` / `initialize(config:)` return,
    /// so a flag read on the app's next line, with no await and the server unreachable, answers
    /// with the cached value. It used to run on this actor from a `Task`, after the client had
    /// been handed back: an app that read its flags once at launch kept the compiled-in defaults
    /// for the whole session (the pilot, off its VPN).
    ///
    /// Race-free without the actor because everything it touches is lock-guarded: the read, the
    /// apply and any delete run inside `resetGate`, as every fetch's write and apply do, and the
    /// launch slot (`launchCache`) is claimed inside that same critical section. So:
    /// - it runs at most once, and never after a server body was applied (a fetch claims the slot
    ///   in its own gate section), so an older body never replaces a newer one;
    /// - a `reset()` between capturing the token and the apply ("session expired" at launch)
    ///   leaves nothing applied, recorded or claimed;
    /// - the actor learns what it needs from `launchCache`: the token the cache was applied under,
    ///   so an unresolved body cannot replace it (`handleUnresolved`). Nothing else changes for a
    ///   later fetch: the launch cache never set `etag` or `lastAppliedSequence`, so a later fetch
    ///   and its 304 behave exactly as before. The resolved record it seeds for C5 (contract § 7)
    ///   waits in `launchCache` until the actor takes it (`adoptLaunchResolvedRecord()`). The ETag
    ///   is nil whenever this can still apply (only an applied fetch sets it, and that claims the
    ///   slot), so deleting the stored keys without `clearCache()` drops no validator.
    ///
    /// The identity is read here, so the caller must already have settled what the server's row is
    /// known to hold (`SheepitClient.start()` marks an identified launch `.unknown` first).
    /// Diagnostics and `onApplied` run after the gate is released: both can reach host code.
    ///
    /// - Parameter deviceId: the device the launch starts on; the cache's resolved stamp arms C5
    ///   only when it names this id (`LaunchConfigCache.evaluate`).
    nonisolated func applyLaunchCache(deviceId: String) {
        // 🔴 Captured BEFORE the cache is read, and the read and the apply both happen inside the
        // reset gate. A `reset()` between them would otherwise put the logged-out user's flags and
        // assignments back into memory: for the whole session if the app is offline.
        let resetTokenAtRead = resetGate.current
        let nowDate = now()
        var outcome: LaunchOutcome?
        var appliedReceipt: AnyCodable?
        resetGate.ifNotReset(since: resetTokenAtRead) {
            let claimed = launchCache.withLock { state -> Bool in
                guard !state.claimed else { return false }
                state.claimed = true
                return true
            }
            guard claimed else { return }
            switch LaunchConfigCache.evaluate(storage: storage, limits: limits, now: nowDate, deviceId: deviceId) {
            case .none:
                return
            case .drop(let reason):
                removeStoredBody()
                outcome = .dropped(reason)
            case let .apply(body, cachedAt, ageUnknown, resolvedForDevice):
                // 🔴 The label stored with the body is used only when it EQUALS what the server's
                // row is known to hold now, read at the same moment. Every identified launch has
                // just set that state to unknown, and the stored label can be wrong (an identify
                // request that committed after the fetch that wrote it): trusting it re-applied
                // the previous row's body under the stored user on every offline relaunch.
                // Otherwise the body is applied as `.unknown`, which also covers a body with no
                // readable label (written by an earlier SDK). User-bucketed entries are then
                // unattributed until a fetch lands: the safe direction.
                let label = storage.data(forKey: StorageKeys.sdkConfigFetchedUnder)
                    .flatMap { try? JSONDecoder().decode(ServerHeldUser.self, from: $0) }
                let current = identityProvider().identity
                appliedReceipt = body.rawAssignmentToken
                if let rawData = storage.data(forKey: StorageKeys.sdkConfig),
                   AssignmentReceipt.isMalformed(body.rawAssignmentToken) {
                    storage.set(AssignmentReceipt.cacheData(rawData, config: body), forKey: StorageKeys.sdkConfig)
                }
                onConfig(body, label?.configIdentity == current ? current : .unknown, .cache)
                launchCache.withLock {
                    $0.appliedUnder = resetTokenAtRead
                    // C5 across launches (contract § 7): armed only when the stamp names this
                    // launch's device; absent or another id is not armed (fail closed).
                    $0.resolvedFor = resolvedForDevice ? (deviceId, resetTokenAtRead) : nil
                }
                freshness.record(.cache, fetchedAt: cachedAt, ageUnknown: ageUnknown)
                outcome = .applied(version: body.configVersion, cachedAt: cachedAt, ageUnknown: ageUnknown)
            }
        }
        switch outcome {
        case nil:
            return
        case .dropped(let reason):
            log.debug("Cached config dropped at launch (\(reason.rawValue))")
            diagnostics?.emit(
                .warn,
                .config,
                code: "config.launch_cache_dropped",
                message: "The cached config was deleted at launch (\(reason.rawValue)); flags read their defaults until a fetch lands",
                data: [
                    "reason": AnyCodable(reason.rawValue),
                    // The Double as set, never `Int(...)`: a finite limit can exceed `Int.max`
                    // (`.greatestFiniteMagnitude` passes validation) and that conversion traps.
                    "offline_max_age_s": limits.hasOfflineLimit ? AnyCodable(limits.offlineMaxAge) : AnyCodable("none"),
                ]
            )
        case let .applied(version, cachedAt, ageUnknown):
            onApplied()
            reportLaunchApply(version: version, cachedAt: cachedAt, ageUnknown: ageUnknown, now: nowDate)
            diagnoseAssignmentReceipt(appliedReceipt)
        }
    }

    /// Raw malformed values reach this shared validation path after all apply locks are released.
    private nonisolated func diagnoseAssignmentReceipt(_ raw: AnyCodable?) {
        guard AssignmentReceipt.isMalformed(raw) else { return }
        diagnostics?.emit(.warn, .config, code: "config.assignment_token_unavailable",
            message: "Config receipt is malformed; experiment attribution is unavailable.",
            data: ["outcome": AnyCodable("invalid_assignment_token")])
    }

    /// `config.launch_cache_applied`: every launch that applies the cache says how old it is, so an
    /// app running for days on an old cache (no expiry since 0.10.2) is visible. Info when stale or
    /// of unknown age (a stamp later than the device clock), debug otherwise.
    private nonisolated func reportLaunchApply(version: String, cachedAt: Date, ageUnknown: Bool, now: Date) {
        let age = max(0, now.timeIntervalSince(cachedAt))
        let stale = ageUnknown || age > limits.staleAfter
        log.debug(ageUnknown
            ? "Loaded config from cache (v\(version)), stamped later than the device clock — applying it, reported stale"
            : "Loaded config from cache (v\(version)), \(Int(saturating: age / 3600)) h old\(stale ? ", past the refresh limit — applying it until a fetch replaces it" : "")")
        var data: [String: AnyCodable] = [
            "stale": AnyCodable(stale),
            "age_unknown": AnyCodable(ageUnknown),
            "config_version": AnyCodable(version),
        ]
        if !ageUnknown { data["config_age_ms"] = AnyCodable(Int(saturating: age * 1000)) }
        diagnostics?.emit(
            stale ? .info : .debug,
            .config,
            code: "config.launch_cache_applied",
            message: ageUnknown
                ? "Applied the cached config at launch; its stamp is later than the device clock, so it is reported stale"
                : "Applied the cached config at launch (\(Int(saturating: age / 3600)) h old\(stale ? ", stale" : ""))",
            data: data
        )
    }
}

/// `ConfigSync.launchCache`'s state.
struct LaunchCacheState: Sendable {
    /// Taken by the launch apply, or by a server body applied before it.
    var claimed = false
    /// The reset token the launch cache was applied under; nil when it was not applied, or when C5
    /// dropped its values (`dropRealBody()`).
    var appliedUnder: UInt64?
    /// The resolved record the launch cache seeds for C5: the launch device and the token it was
    /// applied under. Taken once by the actor (`adoptLaunchResolvedRecord()`); cleared by a server
    /// body applied first, whose own record is newer.
    var resolvedFor: (deviceId: String, resetToken: UInt64)?
}

/// `ConfigSync.persistHold`'s state.
struct PersistHold: Sendable, Equatable {
    let token: UInt64
    /// The new user's label: while the hold is on, only a body fetched under it is written.
    let required: ConfigIdentity
}

/// What `applyLaunchCache()` did inside the gate, reported after it.
private enum LaunchOutcome {
    case dropped(LaunchConfigCache.DropReason)
    case applied(version: String, cachedAt: Date, ageUnknown: Bool)
}

/// The `X-Sheepit-Device-Resolution` header of a `/v1/config` 2xx
/// (`apps/api/src/lib/config-evaluation-context.ts`, values from `config-device-context.ts`), read
/// by the one rule every SDK follows: `Docs/Technical/SDK_DEVICE_REGISTRATION_CONTRACT.md` § 7.
///
/// 🔴 `/v1/config` answers 200, with targeting skipped and every flag on the server's default, when
/// it cannot find the device's row: `unknown_device` before the device registers (or after a logout
/// rotation, until the fresh device does), `lookup_error` when the lookup failed on the server.
/// Applying that body replaced the right values with defaults, and caching it wrote it over a good
/// cache that every later offline launch then served (with no age limit by default since 0.10.2).
/// Keeping its ETag could also 304-latch the defaults, but only against servers older than the
/// suffixed unresolved ETag (`config.ts` compares `If-None-Match` with the resolved ETag only).
///
/// The value is split on commas (repeated fields arrive joined), each token trimmed and compared
/// case-insensitively; RESOLVED only when every token is `resolved`. An ABSENT header is accepted:
/// servers before the header never send it. Anything else, empty and unknown values included, is
/// UNRESOLVED.
enum DeviceResolution: Equatable, Sendable {
    static let headerName = "X-Sheepit-Device-Resolution"
    /// The server's "no row for this device" token (`config-device-context.ts`): the only value that
    /// clears the resolved record or fires C5.
    static let unknownDevice = "unknown_device"

    case resolved
    case absent
    /// Bounded to `unknown_device` | `lookup_error` | `unrecognized`: the raw value is never kept.
    case unresolved(String)

    init(header: String?) {
        guard let header else {
            self = .absent
            return
        }
        let tokens = header.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
        guard let first = tokens.first(where: { $0 != "resolved" }) else {
            self = .resolved
            return
        }
        switch first {
        case Self.unknownDevice, "lookup_error": self = .unresolved(first)
        default: self = .unresolved("unrecognized")
        }
    }

    var refuses: Bool {
        if case .unresolved = self { return true }
        return false
    }

    /// The diagnostic `outcome`: `unknown_device` | `lookup_error` | `unrecognized`.
    var outcome: String {
        switch self {
        case .resolved: return "resolved"
        case .absent: return "absent"
        case .unresolved(let value): return value
        }
    }
}
