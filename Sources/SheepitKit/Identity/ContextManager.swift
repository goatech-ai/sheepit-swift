import Foundation

/// Manages device, session, anonymous, and user identity state.
/// Mirrors packages/sdk-js/src/context.ts
///
/// Lock-guarded: `identify()` writes `userId` while every
/// `track()` reads the event set through `eventContext()`, and
/// `touchSession()` mutates session state on the caller's thread.
/// ThreadSanitizer reports the unguarded version as a `Swift access
/// race`. `eventContext()` takes the lock once so the snapshot it returns
/// is internally consistent rather than stitched from a half-applied
/// identity change.
final class ContextManager: @unchecked Sendable {
    private let lock = NSLock()
    private let storage: StorageProvider

    /// Injected so session-rollover tests do not have to wait out the
    /// 30-minute idle window. Production passes `Date.init`.
    private let now: @Sendable () -> Date

    private var _deviceId: String
    private var _anonymousId: String
    /// Nil only in a process launched in the background whose stored session had expired
    /// (0.6-C): no session exists until the app first comes to the foreground, and
    /// `rolloverIfExpired()` mints one then.
    private var _sessionId: String?
    private var _userId: String?
    /// What the server's device row holds (`ServerHeldUser`). `/v1/config` buckets on the row, so
    /// this — not `_userId` — is what a fetched config is labelled with.
    private var _serverHeldUser: ServerHeldUser = .unknown
    /// Bumped by every `setServerHeldUser`. A config fetch compares the epoch at its start with
    /// the epoch when its response lands; any change in between invalidates its label.
    private var _serverHeldEpoch: UInt64 = 0
    private var sessionLastSeen: Date
    /// When the live session began; nil when unknown (a session stored by an SDK before
    /// `$session_end`, or one `reset()` opened without announcing it). A session with no start
    /// ends without a `$session_end`.
    private var sessionStartedAt: Date?
    /// The session that aged out and is owed a `$session_end`; taken once by
    /// `takeEndedSession()`.
    private var _endedSession: EndedSession?
    /// The app version and build the live session began under, frozen with it: its `$session_end`
    /// is stamped with these, not with whatever build is running when the end is noticed (an app
    /// update between the two would otherwise move the whole session into the new release).
    private var sessionAppVersion: String?
    private var sessionAppBuild: String?
    private let appIdentity: @Sendable () -> (version: String?, build: String?)

    /// True when `init` minted `_deviceId` fresh (a UUIDv4) because storage held nothing for
    /// `StorageKeys.deviceId`; false when it was restored from disk (a locally minted UUID, or a
    /// legacy server-assigned `dev_…` id, kept verbatim). Either way the id is used immediately and
    /// proposed as-is on registration (`Docs/Technical/SDK_DEVICE_REGISTRATION_CONTRACT.md` § 1);
    /// this flag only decides first-session and install bookkeeping. Read-only after `init`.
    let didMintDeviceId: Bool
    /// True when the stored id failed the contract's shape and `init` minted a replacement.
    let replacedUnusableDeviceId: Bool
    /// Why (`DeviceManager.unusableDeviceIdReason`), for the diagnostic. Never the id itself.
    let unusableDeviceIdReason: String?
    /// True when this scope's slot was empty and `init` took the pre-0.10.0 unscoped id.
    let adoptedLegacyDeviceId: Bool

    /// A fresh device id: a lowercase UUIDv4, byte-identical in shape to sdk-js and Kotlin.
    static func mintDeviceId() -> String {
        UUID().uuidString.lowercased()
    }

    /// True once a fresh session id has been minted and not yet announced.
    /// `takeNewSessionFlag()` consumes it so `$session_start` is emitted
    /// exactly once per session. Mirrors `isNewSession` in
    /// `packages/sdk-js/src/context.ts`, which the JS client reads at
    /// `client.ts:593` to decide whether to fire the event.
    private var _isNewSession: Bool

    /// One-shot, for the LIFETIME of this device — not per session, unlike
    /// `_isNewSession`. Seeded from `didMintDeviceId` and consumed by
    /// `takeIsFirstSession()` the first time (and only the first time) a `$session_start`
    /// is actually announced.
    ///
    /// This is deliberately a SEPARATE flag from `didMintDeviceId` itself, which stays
    /// `true` for this whole process's lifetime once set. Without a one-shot latch, a
    /// session that rolls over LATER in the SAME process (idle timeout while the app sits
    /// in the foreground, `didMintDeviceId` still `true`) would report `is_first_session:
    /// true` a second time — but only the device's very first session ever is "first."
    private var _firstSessionPending: Bool

    var deviceId: String {
        lock.lock()
        defer { lock.unlock() }
        return _deviceId
    }

    var anonymousId: String {
        lock.lock()
        defer { lock.unlock() }
        return _anonymousId
    }

    /// The session id held in memory, live or not. Events read `eventContext().sessionId`
    /// instead, which is nil once the session has aged out.
    var sessionId: String? {
        lock.lock()
        defer { lock.unlock() }
        return _sessionId
    }

    var userId: String? {
        lock.lock()
        defer { lock.unlock() }
        return _userId
    }

    /// - Parameter now: injected clock so session-rollover tests do not have to wait out the
    ///   30-minute idle window. Production passes the default `{ Date() }`.
    /// - Parameter persistOnInit: whether construction writes the restored/generated ids
    ///   back to storage. Default `true`, for standalone/test callers that want a
    ///   `ContextManager` to behave like a normal, fully-persisted one on its own.
    ///   `SheepitClient` always passes `false` — it defers the write to `beginWork()` via
    ///   `persistOnBeginWork()`, not just for a client whose API key or apiUrl was rejected.
    ///   Persistence used to run unconditionally here for any accepted key, which meant
    ///   CONSTRUCTION ALONE — not just an inert client's construction — rotated the
    ///   device/session ids a later reader would see. That was harmless for the normal case
    ///   (one construction, one live client) but not for a concurrent `initialize()` LOSER: it
    ///   is fully constructed (accepted key, `inertReason == nil`) and then `destroy()`ed
    ///   unpublished without ever calling `beginWork()` — so its `init` alone clobbered
    ///   whatever the WINNER had already persisted, with a session id nobody would ever use
    ///   again (2026-09 security follow-up round 4, finding MF3-1; E-001 only closed this gap
    ///   for the inert case). Reads still happen regardless of `persistOnInit`: a loser's (or
    ///   an inert client's) `status()` still needs a `deviceId`/`userId` to report, just not
    ///   one it wrote anywhere.
    /// - Parameter launchedInBackground: the process started with no UI (a silent push, a
    ///   background refresh task; see `AppForegroundState`). A live stored session is resumed
    ///   as usual; an expired or missing one is NOT replaced, so nothing is minted, persisted
    ///   or announced until the app comes to the foreground.
    init(
        storage: StorageProvider,
        now: @escaping @Sendable () -> Date = { Date() },
        persistOnInit: Bool = true,
        launchedInBackground: Bool = false,
        legacyStorage: StorageProvider? = nil,
        appIdentity: @escaping @Sendable () -> (version: String?, build: String?) = { (nil, nil) }
    ) {
        self.storage = storage
        self.now = now
        self.appIdentity = appIdentity

        // Restore or generate device ID
        // 🔴 Minted LOWERCASE, like every other SDK; a stored id is kept byte-for-byte (an
        // uppercase id from 0.9.x stays as it is). A stored id the server would refuse
        // (`DeviceManager.isUsableDeviceId`) is never sent: it is replaced by a fresh one here,
        // persisted at `persistOnBeginWork()`, and proposed (contract § 1).
        //
        // 🔴 Scoped since 0.10.0 (`StorageScope.scopedKeys`), like sdk-js's `gt_device_id:<scope>`.
        // An empty slot takes the pre-scope unscoped id from `legacyStorage`, byte-for-byte, so an
        // existing single-host install keeps its device; `SheepitClient.beginWork()` then writes
        // the slot and deletes the legacy key (`StorageScope.retireLegacyDeviceId`).
        let scopedDeviceId = storage.string(forKey: StorageKeys.deviceId)
        let legacyDeviceId = scopedDeviceId == nil ? legacyStorage?.string(forKey: StorageKeys.deviceId) : nil
        self.adoptedLegacyDeviceId = legacyDeviceId != nil
        let storedDeviceId = scopedDeviceId ?? legacyDeviceId
        self.didMintDeviceId = storedDeviceId == nil
        self.unusableDeviceIdReason = storedDeviceId.flatMap { DeviceManager.unusableDeviceIdReason($0) }
        let usableStoredId = unusableDeviceIdReason == nil ? storedDeviceId : nil
        self.replacedUnusableDeviceId = storedDeviceId != nil && usableStoredId == nil
        self._deviceId = usableStoredId ?? Self.mintDeviceId()
        self._firstSessionPending = self.didMintDeviceId

        // Restore or generate anonymous ID
        self._anonymousId = storage.string(forKey: StorageKeys.anonymousId)
            ?? UUID().uuidString

        // Restore or generate session
        let storedSessionId = storage.string(forKey: StorageKeys.sessionId)
        let storedLastSeen = storage.string(forKey: StorageKeys.sessionLastSeen)
            .flatMap { TimeInterval($0) }
            .map { Date(timeIntervalSince1970: $0) }

        let isExpired = storedLastSeen.map {
            now().timeIntervalSince($0) > SDKDefaults.sessionTimeoutSeconds
        } ?? true

        // Finite and positive only: `TimeInterval("nan")`, `("inf")` and `("1e300")` all parse, and a
        // poisoned start would trap in `durationMs`. Anything else reads as "no start".
        let storedStartedAt = storage.string(forKey: StorageKeys.sessionStartedAt)
            .flatMap { TimeInterval($0) }
            .flatMap { $0.isFinite && $0 > 0 && $0 < 4_102_444_800 ? Date(timeIntervalSince1970: $0) : nil }
        let storedAppVersion = storage.string(forKey: StorageKeys.sessionAppVersion)
        let storedAppBuild = storage.string(forKey: StorageKeys.sessionAppBuild)
        // The previous process's session aged out while the app was dead: it is owed its end,
        // timestamped at its last activity. Skipped when that end was already queued.
        // A session stored without its app identity (by 0.10.1 or earlier) is not ended: stamping
        // it with today's build would misattribute it.
        if let storedSessionId, isExpired, let storedStartedAt, let storedLastSeen,
           let storedAppVersion, let storedAppBuild,
           storage.string(forKey: StorageKeys.sessionEndedId) != storedSessionId {
            self._endedSession = EndedSession(
                id: storedSessionId, startedAt: storedStartedAt, endedAt: storedLastSeen,
                appVersion: storedAppVersion.isEmpty ? nil : storedAppVersion,
                appBuild: storedAppBuild.isEmpty ? nil : storedAppBuild)
        }

        if let storedSessionId, !isExpired {
            self._sessionId = storedSessionId
            // No stored app identity (a session from 0.10.1 or earlier): it cannot be ended truthfully.
            self.sessionStartedAt = storedAppVersion == nil || storedAppBuild == nil ? nil : storedStartedAt
            self.sessionAppVersion = storedAppVersion.map { $0.isEmpty ? nil : $0 } ?? nil
            self.sessionAppBuild = storedAppBuild.map { $0.isEmpty ? nil : $0 } ?? nil
            self.sessionLastSeen = storedLastSeen ?? now()
            // Resuming an existing session — nothing to announce.
            self._isNewSession = false
        } else if launchedInBackground {
            // Nobody is looking, so no session begins (0.6-C). `distantPast` makes the first
            // foreground's `rolloverIfExpired()` mint and flag one, exactly as an expired
            // session would.
            self._sessionId = nil
            self.sessionLastSeen = .distantPast
            self._isNewSession = false
        } else {
            self._sessionId = UUID().uuidString
            self.sessionLastSeen = now()
            self.sessionStartedAt = self.sessionLastSeen
            (self.sessionAppVersion, self.sessionAppBuild) = appIdentity()
            // Cold start into a brand-new session, or the stored one aged
            // out while the process was dead. Either way this is the first
            // session, so `$session_start` is owed.
            self._isNewSession = true
        }

        // Restore identity
        if let identityData = storage.data(forKey: StorageKeys.identity),
           let identity = try? JSONDecoder().decode(StoredIdentity.self, from: identityData) {
            self._userId = identity.userId
        }
        self._serverHeldUser = storage.data(forKey: StorageKeys.serverHeldUser)
            .flatMap { try? JSONDecoder().decode(ServerHeldUser.self, from: $0) } ?? .unknown

        guard persistOnInit else { return }

        // Persist initial values
        lock.lock()
        defer { lock.unlock() }
        persistIds()
    }

    /// Writes the current device/session/session-last-seen ids to disk. The ONLY other writer
    /// of these three keys at construction time is `persistOnInit` above — `SheepitClient`
    /// always constructs with `persistOnInit: false` and calls this instead, from
    /// `beginWork()`, so a client that never begins work (an inert client, or a concurrent
    /// `initialize()` LOSER that is `destroy()`ed unpublished) makes zero writes here: byte-
    /// identical to an inert client on disk (2026-09 security follow-up round 4, finding
    /// MF3-1). Safe to call more than once — it writes the same in-memory values every time —
    /// though `SheepitClient.beginWork()`'s own one-shot guard means it never actually does.
    func persistOnBeginWork() {
        lock.lock()
        defer { lock.unlock() }
        persistIds()
        // A freshly minted id must survive an immediate kill: it is already on every event and
        // request, and it is the registration proposal.
        if didMintDeviceId || replacedUnusableDeviceId || adoptedLegacyDeviceId { _ = storage.synchronize() }
    }

    // MARK: - Device

    func setDeviceId(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        _deviceId = id
        storage.set(id, forKey: StorageKeys.deviceId)
        _ = storage.synchronize()
    }

    /// Writes `id` to disk (and flushes) WITHOUT adopting it in memory: the first step of adopting
    /// a server-replaced id, so the id is durable before re-stamped events can leave the device.
    func persistDeviceIdAhead(_ id: String) {
        storage.set(id, forKey: StorageKeys.deviceId)
        _ = storage.synchronize()
    }

    /// `setDeviceId(id)` only while the device is still `expected`, in one critical section: a
    /// logout rotation's `setDeviceId` cannot land between the check and the write.
    func replaceDeviceId(_ expected: String, with id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard _deviceId == expected else { return false }
        _deviceId = id
        storage.set(id, forKey: StorageKeys.deviceId)
        _ = storage.synchronize()
        return true
    }

    // MARK: - Session

    /// Records activity on the current session. **Bump-only — it never
    /// rotates the session id.**
    ///
    /// This matches `touchSession()` in `packages/sdk-js/src/context.ts:175`,
    /// which likewise only rewrites `gt_session_last_seen`. On the web,
    /// rollover happens in exactly one place — `loadOrCreateSession()` at
    /// SDK construction, i.e. a page load.
    ///
    /// 🔴 It used to rotate the id here, silently. That minted session
    /// boundaries nothing announced — no `$session_start`, so DAU / MAU /
    /// retention never counted them — and it filed events under the wrong
    /// session, because `Transport` stamped one batch-level
    /// `context.session.id` from `events[0]` for a batch that could span two
    /// sessions. Rotation now lives in `rolloverIfExpired()`, which announces
    /// the boundary, and `Transport.flush()` groups each drain by session id
    /// so the boundary may fall anywhere.
    func touchSession() {
        lock.lock()
        defer { lock.unlock() }
        guard let sessionId = _sessionId else { return }
        let timestamp = now()
        sessionLastSeen = timestamp
        storage.set(sessionId, forKey: StorageKeys.sessionId)
        storage.set(String(timestamp.timeIntervalSince1970), forKey: StorageKeys.sessionLastSeen)
    }

    /// Mint a new session if the idle window has elapsed, flagging that
    /// `$session_start` is owed. Idempotent within a live session, so it is
    /// safe to call on every `track()` as well as on app foreground.
    /// - Returns: whether a session was minted, so the caller can refresh what holds a copy of
    ///   the id (the crash context).
    @discardableResult
    func rolloverIfExpired() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let timestamp = now()
        // A background launch leaves no session and a `distantPast` last-seen, so this mints
        // one on the first foreground with no separate nil check (0.6-C).
        guard timestamp.timeIntervalSince(sessionLastSeen) > SDKDefaults.sessionTimeoutSeconds else {
            return false
        }
        oweEndOfCurrentSession()
        _sessionId = UUID().uuidString
        sessionLastSeen = timestamp
        sessionStartedAt = timestamp
        (sessionAppVersion, sessionAppBuild) = appIdentity()
        _isNewSession = true
        persistIds()
        return true
    }

    /// Bumps the session's last activity as the app leaves the foreground, so the duration of a
    /// session that saw no event since it began still covers the time on screen. A no-op once
    /// the idle window has already elapsed: touching would revive a session `rolloverIfExpired()`
    /// is about to end.
    func touchSessionIfLive() {
        lock.lock()
        defer { lock.unlock() }
        let timestamp = now()
        guard _sessionId != nil, !(timestamp.timeIntervalSince(sessionLastSeen) > SDKDefaults.sessionTimeoutSeconds) else { return }
        sessionLastSeen = timestamp
        storage.set(String(sessionLastSeen.timeIntervalSince1970), forKey: StorageKeys.sessionLastSeen)
    }

    /// The session owed a `$session_end`, if any, cleared so it is announced once in this process.
    /// The caller queues the event and then calls `markSessionEndQueued(_:)`.
    func takeEndedSession() -> EndedSession? {
        lock.lock()
        defer { lock.unlock() }
        guard let ended = _endedSession else { return nil }
        _endedSession = nil
        return ended
    }

    /// Records, after its event is queued, that `id`'s end was announced, so a relaunch before a new
    /// session is stored does not announce it again. Flushed: a kill right after must not repeat it.
    func markSessionEndQueued(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        storage.set(id, forKey: StorageKeys.sessionEndedId)
        _ = storage.synchronize()
    }

    /// Callers hold `lock`. The live session, if it was announced and its identity is known, is
    /// owed an end at its last activity.
    private func oweEndOfCurrentSession(requireAnnounced: Bool = false) {
        // An end already owed is kept. `reset()` also skips a session whose `$session_start` is
        // still unannounced (a rollover just minted it): it has nothing to end yet.
        guard _endedSession == nil, !(requireAnnounced && _isNewSession), let id = _sessionId, let started = sessionStartedAt else { return }
        _endedSession = EndedSession(
            id: id, startedAt: started, endedAt: sessionLastSeen,
            appVersion: sessionAppVersion, appBuild: sessionAppBuild)
    }

    /// Returns whether a `$session_start` is owed, clearing the flag so the
    /// event is emitted exactly once per session even if two boundaries race
    /// (SDK start landing alongside a foreground notification).
    func takeNewSessionFlag() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let owed = _isNewSession
        _isNewSession = false
        return owed
    }

    /// Returns whether the session about to be announced is this device's very first
    /// session ever, clearing the flag so it can never report `true` again for the
    /// lifetime of this device — see `_firstSessionPending`'s doc for why that must be a
    /// separate one-shot from `didMintDeviceId`. Callers must pair this with a `true`
    /// result from `takeNewSessionFlag()`; calling it on its own (or more than once) is
    /// harmless but meaningless.
    func takeIsFirstSession() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard _firstSessionPending else { return false }
        _firstSessionPending = false
        return true
    }

    var isSessionExpired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return now().timeIntervalSince(sessionLastSeen) > SDKDefaults.sessionTimeoutSeconds
    }

    // MARK: - Identity

    func setUserId(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        _userId = id
        persistIdentity()
    }

    /// The server-held label and its epoch, read together. Persisted, so a relaunch keeps knowing
    /// what the row holds, including that it does not know.
    var serverHeldUser: (user: ServerHeldUser, epoch: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        return (_serverHeldUser, _serverHeldEpoch)
    }

    /// Record what the server's device row now holds (see `ServerHeldUser` for who calls this and
    /// with what). Always bumps the epoch, even for an unchanged value: a fetch that started
    /// before a label decision must not be trusted after it.
    func setServerHeldUser(_ user: ServerHeldUser) {
        lock.lock()
        defer { lock.unlock() }
        _serverHeldUser = user
        _serverHeldEpoch &+= 1
        if let data = try? JSONEncoder().encode(user) {
            storage.set(data, forKey: StorageKeys.serverHeldUser)
        }
    }

    /// Record that the SDK does not know what the row holds, moving the epoch only if it knew.
    ///
    /// For an identify POST's own send and failure. When the label is already `.unknown`, a fetch
    /// in flight is applied as `.unknown` whatever happens here, so bumping would change only one
    /// thing: `ConfigSync` drops that fetch's ETag. A retry that fails every time (5xx, 429,
    /// offline) then made every poll a full 200 and a disk write, because each tick's POST moved
    /// the epoch while that tick's GET was on the wire.
    func markServerHeldUserUnknown() {
        lock.lock()
        defer { lock.unlock() }
        guard _serverHeldUser != .unknown else { return }
        _serverHeldUser = .unknown
        _serverHeldEpoch &+= 1
        if let data = try? JSONEncoder().encode(ServerHeldUser.unknown) {
            storage.set(data, forKey: StorageKeys.serverHeldUser)
        }
    }

    /// - Parameter mintSession: false in the background (0.6-C). The old session is dropped, in
    ///   memory and on disk, so the next user never joins it, and no new one is minted: a
    ///   session minted here is never announced, so the first foreground would find it live and
    ///   no `$session_start` would ever fire for it. The first foreground mints one instead.
    func resetIdentity(mintSession: Bool = true) {
        lock.lock()
        defer { lock.unlock() }
        _userId = nil
        // The outgoing session was announced with `$session_start` (unless it is one `reset()`
        // itself opened), so it is owed its end; leaving it out would orphan every logout's session.
        oweEndOfCurrentSession(requireAnnounced: true)
        // The server-held label is not touched here: logout does not change the device row. When
        // that row may hold a user, `SheepitClient.reset()` switches to a fresh device
        // (`DeviceRotation`), which sets the label for the new row.
        _anonymousId = UUID().uuidString
        if mintSession {
            _sessionId = UUID().uuidString
            sessionLastSeen = now()
        } else {
            _sessionId = nil
            sessionLastSeen = .distantPast
            storage.removeObject(forKey: StorageKeys.sessionId)
            storage.removeObject(forKey: StorageKeys.sessionStartedAt)
            storage.removeObject(forKey: StorageKeys.sessionLastSeen)
        }
        // The session `reset()` opens is never announced, so it is never ended either: a
        // `$session_end` with no `$session_start` would skew the pair.
        sessionStartedAt = nil
        storage.removeObject(forKey: StorageKeys.sessionStartedAt)
        // Deliberately does NOT set `_isNewSession`. `reset()` mints a new
        // session id on the web too (`context.ts:162`), and the JS SDK does
        // not emit `$session_start` for it either — the emit lives only on
        // the init path. Announcing it here would double-count a logout as
        // a session in DAU.
        storage.removeObject(forKey: StorageKeys.identity)
        persistIds()
    }

    // MARK: - Context for Events

    /// `sessionId` is nil once the session has aged out. In the foreground `track()` rolls
    /// over first, so it is always live there; in the background (0.6-C) nothing rolls over or
    /// extends it, so a background event joins the stored session only while it is live.
    func eventContext() -> EventContextSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return eventContextLocked()
    }

    /// Sampling never waits behind storage work holding the existing context lock.
    func tryEventContext() -> EventContextSnapshot? {
        guard lock.try() else { return nil }
        defer { lock.unlock() }
        return eventContextLocked()
    }

    private func eventContextLocked() -> EventContextSnapshot {
        let live = now().timeIntervalSince(sessionLastSeen) <= SDKDefaults.sessionTimeoutSeconds
        return EventContextSnapshot(
            deviceId: _deviceId,
            anonymousId: _anonymousId,
            sessionId: live ? _sessionId : nil,
            userId: _userId,
            platform: DeviceProfile.platform,
            // The same BCP-47 tag registration sends; see `DeviceProfile.wireLocaleTag`.
            locale: DeviceProfile.wireLocaleTag(.current)
                ?? DeviceProfile.bounded(Locale.current.identifier, DeviceProfile.localeMaxLength),
            timezone: DeviceProfile.timezone(),
            sdkVersion: SDKDefaults.sdkVersion
        )
    }

    // MARK: - Private (callers must hold `lock` — NSLock is not recursive)

    private func persistIds() {
        storage.set(_deviceId, forKey: StorageKeys.deviceId)
        storage.set(_anonymousId, forKey: StorageKeys.anonymousId)
        // No session (a background launch, 0.6-C): leave the stored, expired one as it is
        // rather than writing a `distantPast` last-seen over it.
        guard let sessionId = _sessionId else { return }
        storage.set(sessionId, forKey: StorageKeys.sessionId)
        storage.set(String(sessionLastSeen.timeIntervalSince1970), forKey: StorageKeys.sessionLastSeen)
        if let sessionStartedAt {
            storage.set(String(sessionStartedAt.timeIntervalSince1970), forKey: StorageKeys.sessionStartedAt)
        } else {
            storage.removeObject(forKey: StorageKeys.sessionStartedAt)
        }
        storage.set(sessionAppVersion ?? "", forKey: StorageKeys.sessionAppVersion)
        storage.set(sessionAppBuild ?? "", forKey: StorageKeys.sessionAppBuild)
    }

    private func persistIdentity() {
        guard let userId = _userId else { return }
        let identity = StoredIdentity(userId: userId)
        if let data = try? JSONEncoder().encode(identity) {
            storage.set(data, forKey: StorageKeys.identity)
        }
    }
}

// MARK: - Supporting Types

/// A session that has aged out, with when it was last active: what `$session_end` reports.
struct EndedSession: Sendable, Equatable {
    let id: String
    let startedAt: Date
    let endedAt: Date
    /// What the session began under; `$session_end` is stamped with it, not the running build.
    var appVersion: String? = nil
    var appBuild: String? = nil

    /// Whole milliseconds between the start and the last activity; never negative (a wall-clock
    /// step backwards would otherwise produce one).
    var durationMs: Int {
        let ms = (endedAt.timeIntervalSince(startedAt) * 1000).rounded()
        // `Int(_:)` traps on NaN and out-of-range values; clamp first (30 days is far past any session).
        guard ms.isFinite, ms > 0 else { return 0 }
        // Below `Int32.max` (about 23 days): `Int` is 32 bits on watchOS arm64_32.
        return Int(min(ms, 2_000_000_000))
    }
}

struct EventContextSnapshot: Sendable {
    let deviceId: String
    let anonymousId: String
    /// Nil when there is no live session (0.6-C); the wire then carries no `session.id`.
    let sessionId: String?
    let userId: String?
    let platform: String
    let locale: String
    let timezone: String
    let sdkVersion: String
}

private struct StoredIdentity: Codable {
    let userId: String
}
