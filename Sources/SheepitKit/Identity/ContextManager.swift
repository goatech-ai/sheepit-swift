import Foundation

/// Manages device, session, anonymous, and user identity state.
/// Mirrors packages/sdk-js/src/context.ts
///
/// Lock-guarded: `identify()` writes `userId` / `userTraits` while every
/// `track()` reads the whole set through `eventContext()`, and
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
    private var _sessionId: String
    private var _userId: String?
    private var _userTraits: [String: Any] = [:]
    private var sessionLastSeen: Date

    /// True when `init` minted `_deviceId` fresh because storage held nothing for
    /// `StorageKeys.deviceId`. False whenever a value was restored from disk instead —
    /// which, for every real existing install, is a LOCALLY-MINTED id that has never made
    /// it to the server: `POST /v1/devices/register` has never fired in any published
    /// version (`start()`'s guard was never satisfiable — verified back to the SDK's first
    /// commit), so no install anywhere holds a server-assigned `dev_…` id today. The same
    /// `false` value also covers the forward-looking case of a device that DOES already
    /// hold a server-assigned id (once registration starts succeeding, a later bug that
    /// re-triggers a second attempt must not re-mint). Read-only from outside; nothing after
    /// `init` may change it.
    ///
    /// This is a DIFFERENT question from `StorageKeys.deviceRegistered` (whether registration
    /// has ever *succeeded*): a device can hold a non-nil `_deviceId` without
    /// `deviceRegistered` ever having been set — every real install today, plus one whose
    /// first registration attempt failed. `start()` needs both: `deviceRegistered` decides
    /// whether to attempt registration at all, `didMintDeviceId` decides what id (if any) to
    /// send along with that attempt.
    let didMintDeviceId: Bool

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

    var sessionId: String {
        lock.lock()
        defer { lock.unlock() }
        return _sessionId
    }

    var userId: String? {
        lock.lock()
        defer { lock.unlock() }
        return _userId
    }

    var userTraits: [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        return _userTraits
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
    init(
        storage: StorageProvider,
        now: @escaping @Sendable () -> Date = { Date() },
        persistOnInit: Bool = true
    ) {
        self.storage = storage
        self.now = now

        // Restore or generate device ID
        let storedDeviceId = storage.string(forKey: StorageKeys.deviceId)
        self.didMintDeviceId = storedDeviceId == nil
        self._deviceId = storedDeviceId ?? UUID().uuidString
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

        if let storedSessionId, !isExpired {
            self._sessionId = storedSessionId
            self.sessionLastSeen = storedLastSeen ?? now()
            // Resuming an existing session — nothing to announce.
            self._isNewSession = false
        } else {
            self._sessionId = UUID().uuidString
            self.sessionLastSeen = now()
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
    }

    // MARK: - Device

    func setDeviceId(_ id: String) {
        lock.lock()
        defer { lock.unlock() }
        _deviceId = id
        storage.set(id, forKey: StorageKeys.deviceId)
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
        let timestamp = now()
        sessionLastSeen = timestamp
        storage.set(_sessionId, forKey: StorageKeys.sessionId)
        storage.set(String(timestamp.timeIntervalSince1970), forKey: StorageKeys.sessionLastSeen)
    }

    /// Mint a new session if the idle window has elapsed, flagging that
    /// `$session_start` is owed. Idempotent within a live session, so it is
    /// safe to call on every `track()` as well as on app foreground.
    func rolloverIfExpired() {
        lock.lock()
        defer { lock.unlock() }
        let timestamp = now()
        guard timestamp.timeIntervalSince(sessionLastSeen) > SDKDefaults.sessionTimeoutSeconds else {
            return
        }
        _sessionId = UUID().uuidString
        sessionLastSeen = timestamp
        _isNewSession = true
        persistIds()
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

    func updateUserTraits(_ traits: [String: Any]) {
        lock.lock()
        defer { lock.unlock() }
        for (key, value) in traits {
            _userTraits[key] = value
        }
    }

    func resetIdentity() {
        lock.lock()
        defer { lock.unlock() }
        _userId = nil
        _userTraits = [:]
        _anonymousId = UUID().uuidString
        _sessionId = UUID().uuidString
        sessionLastSeen = now()
        // Deliberately does NOT set `_isNewSession`. `reset()` mints a new
        // session id on the web too (`context.ts:162`), and the JS SDK does
        // not emit `$session_start` for it either — the emit lives only on
        // the init path. Announcing it here would double-count a logout as
        // a session in DAU.
        storage.removeObject(forKey: StorageKeys.identity)
        persistIds()
    }

    // MARK: - Context for Events

    func eventContext() -> EventContextSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return EventContextSnapshot(
            deviceId: _deviceId,
            anonymousId: _anonymousId,
            sessionId: _sessionId,
            userId: _userId,
            platform: "ios",
            locale: Locale.current.identifier,
            timezone: DeviceProfile.timezone(),
            sdkVersion: SDKDefaults.sdkVersion
        )
    }

    // MARK: - Private (callers must hold `lock` — NSLock is not recursive)

    private func persistIds() {
        storage.set(_deviceId, forKey: StorageKeys.deviceId)
        storage.set(_anonymousId, forKey: StorageKeys.anonymousId)
        storage.set(_sessionId, forKey: StorageKeys.sessionId)
        storage.set(String(sessionLastSeen.timeIntervalSince1970), forKey: StorageKeys.sessionLastSeen)
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

struct EventContextSnapshot: Sendable {
    let deviceId: String
    let anonymousId: String
    let sessionId: String
    let userId: String?
    let platform: String
    let locale: String
    let timezone: String
    let sdkVersion: String
}

private struct StoredIdentity: Codable {
    let userId: String
}
