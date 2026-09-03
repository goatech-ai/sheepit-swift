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

    private var _deviceId: String
    private var _anonymousId: String
    private var _sessionId: String
    private var _userId: String?
    private var _userTraits: [String: Any] = [:]
    private var sessionLastSeen: Date

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

    init(storage: StorageProvider) {
        self.storage = storage

        // Restore or generate device ID
        self._deviceId = storage.string(forKey: StorageKeys.deviceId)
            ?? UUID().uuidString

        // Restore or generate anonymous ID
        self._anonymousId = storage.string(forKey: StorageKeys.anonymousId)
            ?? UUID().uuidString

        // Restore or generate session
        let storedSessionId = storage.string(forKey: StorageKeys.sessionId)
        let storedLastSeen = storage.string(forKey: StorageKeys.sessionLastSeen)
            .flatMap { TimeInterval($0) }
            .map { Date(timeIntervalSince1970: $0) }

        let isExpired = storedLastSeen.map {
            Date().timeIntervalSince($0) > SDKDefaults.sessionTimeoutSeconds
        } ?? true

        if let storedSessionId, !isExpired {
            self._sessionId = storedSessionId
            self.sessionLastSeen = storedLastSeen ?? Date()
        } else {
            self._sessionId = UUID().uuidString
            self.sessionLastSeen = Date()
        }

        // Restore identity
        if let identityData = storage.data(forKey: StorageKeys.identity),
           let identity = try? JSONDecoder().decode(StoredIdentity.self, from: identityData) {
            self._userId = identity.userId
        }

        // Persist initial values
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

    func touchSession() {
        lock.lock()
        defer { lock.unlock() }
        let now = Date()
        if now.timeIntervalSince(sessionLastSeen) > SDKDefaults.sessionTimeoutSeconds {
            _sessionId = UUID().uuidString
        }
        sessionLastSeen = now
        storage.set(_sessionId, forKey: StorageKeys.sessionId)
        storage.set(String(now.timeIntervalSince1970), forKey: StorageKeys.sessionLastSeen)
    }

    var isSessionExpired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return Date().timeIntervalSince(sessionLastSeen) > SDKDefaults.sessionTimeoutSeconds
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
        sessionLastSeen = Date()
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
            timezone: TimeZone.current.identifier,
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
