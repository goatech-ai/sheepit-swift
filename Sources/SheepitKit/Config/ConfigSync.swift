import Foundation

/// Which user a `/v1/config` body was bucketed for, as far as the SDK can know. Experiment
/// attribution compares it with each event's user (`ExperimentManager.snapshot(eventUserId:)`).
enum ConfigIdentity: Sendable, Equatable {
    /// Fetched while the server was confirmed to hold this user for the device (`nil`: none).
    case fetchedUnder(String?)
    /// A cached body written before the SDK recorded the label. Treated as matching no user.
    case unknown
}

/// Periodically fetches flag/experiment configuration from GET /v1/config.
/// Mirrors packages/sdk-js/src/config-sync.ts
actor ConfigSync {
    private let http: HTTPClient
    private let storage: StorageProvider
    private let refreshInterval: TimeInterval
    private let log: Logger
    /// Receives the config and the identity it was fetched under (see `identityProvider`).
    private let onConfig: @Sendable (SDKConfigResponse, ConfigIdentity) -> Void
    /// What the server's device row holds (`ContextManager.serverHeldUser`) and its epoch.
    ///
    /// `/v1/config` sends no user: the server buckets `u:` on the user its device row holds
    /// (`config-evaluation-context.ts`). The app's own user id moves the moment `identify()` is
    /// called, before the POST that changes the row, and that POST can fail or go unanswered, so
    /// it cannot label a config. The label is read when a request STARTS; if its epoch has moved
    /// by the time the response lands, the row may have changed underneath the request, and the
    /// response is applied as `.unknown` instead.
    private let identityProvider: @Sendable () -> (identity: ConfigIdentity, epoch: UInt64)
    private var etag: String?
    /// The `resetGate` token `etag` was stored under. An ETag from before a `reset()` is never
    /// sent: it validates the logged-out user's body.
    private var etagResetToken: UInt64 = 0
    /// Shared with `SheepitClient.reset()`; see `ConfigResetGate`.
    private let resetGate: ConfigResetGate
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

    init(
        http: HTTPClient,
        storage: StorageProvider,
        refreshInterval: TimeInterval,
        log: Logger,
        resetGate: ConfigResetGate = ConfigResetGate(),
        identityProvider: @escaping @Sendable () -> (identity: ConfigIdentity, epoch: UInt64),
        onConfig: @escaping @Sendable (SDKConfigResponse, ConfigIdentity) -> Void
    ) {
        self.http = http
        self.storage = storage
        self.refreshInterval = refreshInterval
        self.log = log
        self.identityProvider = identityProvider
        self.onConfig = onConfig
        self.resetGate = resetGate
    }

    /// Start sync: load cache immediately, then fetch periodically.
    ///
    /// - Parameter onRefreshTick: called before every periodic fetch except the launch one, so a
    ///   host can re-send work that is due at most once per refresh interval (the identify retry).
    func start(
        deviceIdGetter: @escaping @Sendable () -> String,
        onRefreshTick: @escaping @Sendable () -> Void = {}
    ) {
        // Load cached config synchronously for instant availability
        loadFromCache()

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
        await fetchConfig(deviceId: deviceId)
    }

    // MARK: - Private

    private func fetchConfig(deviceId: String) async {
        let resetTokenAtStart = resetGate.current
        requestSequence += 1
        let sequence = requestSequence
        // Before the await: see `identityProvider`.
        let (identityAtRequest, epochAtRequest) = identityProvider()
        var headers: [String: String] = ["X-Device-ID": deviceId]
        let unconditional = needsUnconditional
        if !unconditional, let etag, etagResetToken == resetTokenAtStart { headers["If-None-Match"] = etag }

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
                return
            }

            guard (200...299).contains(response.statusCode) else {
                log.warn("Config fetch failed: HTTP \(response.statusCode)")
                return
            }

            // Parse the config response
            let configResponse = try JSONDecoder().decode(ApiDataResponse<SDKConfigResponse>.self, from: data)
            let sdkConfig = configResponse.data

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
            let applied = resetGate.ifNotReset(since: resetTokenAtStart) {
                storage.removeObject(forKey: StorageKeys.sdkConfigFetchedUnder)
                storage.set(data, forKey: StorageKeys.sdkConfig)
                storage.set(String(Date().timeIntervalSince1970), forKey: StorageKeys.sdkConfigCachedAt)
                if let label = try? JSONEncoder().encode(ServerHeldUser(identity)) {
                    storage.set(label, forKey: StorageKeys.sdkConfigFetchedUnder)
                }
                onConfig(sdkConfig, identity)
            }
            guard applied else {
                log.debug("Config response discarded — reset() while in flight")
                return
            }

            lastAppliedSequence = sequence
            // Applied, so an unconditional request may now release the flag.
            if unconditional { needsUnconditional = false }
            etag = labelStillValid ? sdkConfig.etag : nil
            etagResetToken = resetTokenAtStart

            log.debug("Config updated (v\(sdkConfig.configVersion))")

        } catch {
            log.warn("Config fetch error: \(error.localizedDescription)")
        }
    }

    /// Drop the cached config: used when the cache on disk is stale at launch.
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
        storage.removeObject(forKey: StorageKeys.sdkConfig)
        storage.removeObject(forKey: StorageKeys.sdkConfigCachedAt)
        storage.removeObject(forKey: StorageKeys.sdkConfigFetchedUnder)
    }

    private func loadFromCache() {
        // A fetch that already applied is newer than anything on disk.
        guard lastAppliedSequence == 0 else { return }
        // 🔴 Captured BEFORE the cache is read, and the read and the apply both happen inside the
        // reset gate. A `reset()` between them ("session expired" at launch) would otherwise put
        // the logged-out user's flags and assignments back into memory: for the whole session if
        // the app is offline, since no fetch replaces them.
        let resetTokenAtRead = resetGate.current
        var stale = false
        resetGate.ifNotReset(since: resetTokenAtRead) {
            guard let data = storage.data(forKey: StorageKeys.sdkConfig),
                  let cached = try? JSONDecoder().decode(ApiDataResponse<SDKConfigResponse>.self, from: data)
            else { return }

            // 🔴 Age check. `SDKDefaults.configMaxAge` existed but was DEAD — declared
            // and never read — so an iOS cache was served indefinitely while the web
            // enforced the same 24h bound (`sdk-js/src/config-sync.ts`). A config kept
            // past its bound serves stale targeting forever on a device that stops
            // fetching, and it is a retention problem as well as a correctness one.
            //
            // A missing timestamp means the entry predates this key: treat it as stale
            // rather than trusting it, which costs one fetch on upgrade.
            // Stored as a String: `StorageProvider` vends String and Data only, and
            // widening the protocol for one timestamp is not worth it.
            let cachedAt = storage.string(forKey: StorageKeys.sdkConfigCachedAt).flatMap(Double.init) ?? 0
            // `Double("inf")` and `Double("1e999")` both parse to +infinity, which
            // satisfies `> 0` and makes the age negative — a cache that never
            // expires. A future-dated stamp (clock skew at write) does the same.
            // Require a finite stamp that is not in the future.
            let now = Date().timeIntervalSince1970
            guard cachedAt.isFinite, cachedAt > 0, cachedAt <= now,
                now - cachedAt <= SDKDefaults.configMaxAge
            else {
                stale = true
                return
            }

            log.debug("Loaded config from cache (v\(cached.data.configVersion))")
            // 🔴 The label stored with the body is used only when it EQUALS what the server's row
            // is known to hold now, read at the same moment. Every identified launch has just set
            // that state to unknown, and the stored label can be wrong (an identify request that
            // committed after the fetch that wrote it): trusting it re-applied the previous row's
            // body under the stored user on every offline relaunch, up to the 24 h cache limit.
            // Otherwise the body is applied as `.unknown`, which also covers a body with no
            // readable label (written by an earlier SDK). User-bucketed entries are then
            // unattributed until a fetch lands: the safe direction.
            let label = storage.data(forKey: StorageKeys.sdkConfigFetchedUnder)
                .flatMap { try? JSONDecoder().decode(ServerHeldUser.self, from: $0) }
            let current = identityProvider().identity
            onConfig(cached.data, label?.configIdentity == current ? current : .unknown)
        }
        // Outside the gate: dropping a stale cache is not a write that can resurrect anything.
        if stale {
            log.debug("Cached config is stale or unstamped — dropping it")
            clearCache()
        }
    }
}
