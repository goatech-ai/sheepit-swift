import Foundation

/// The persisted registration backoff: ONE record under ONE scoped key
/// (`StorageKeys.deviceRegistrationBackoff`), written in one serialized write as a JSON string.
/// Contract: `Docs/Technical/SDK_DEVICE_REGISTRATION_CONTRACT.md` § 3. Policy (what to write and
/// when) lives in `RegistrationPolicy`; this type only encodes, reads and writes the record.
///
/// 🔴 0.9.x kept `until` and the SDK version under two keys, written by two `set` calls, and only
/// after a cap or terminal answer. A kill between the two writes, or any transient failure, left
/// nothing behind, so the next launch started from zero.
struct RegistrationBackoffRecord: Codable, Equatable, Sendable {
    /// Epoch seconds. Registration is withheld while `until - now > 0`.
    var until: TimeInterval
    /// Failures since the last success, across launches. The backoff exponent.
    var failuresTotal: Int
    /// `SDKDefaults.sdkVersion` of the build that wrote it (`sdk_version` on disk). Another
    /// build's record is cleared: the new build may carry the fix for whatever was rejected.
    /// Not named after the SDK version constant: the release tooling greps Sources for exactly one
    /// declaration of it.
    var writtenBy: String

    enum CodingKeys: String, CodingKey {
        case until
        case failuresTotal = "failures_total"
        case writtenBy = "sdk_version"
    }
}

enum RegistrationBackoff {
    enum Discard: Sendable {
        case unreadable, otherSDKVersion
        /// Not a discard: a backward-clock window was clamped, but the rewrite did not stick.
        case clampNotPersisted
    }

    /// The longest window ever honoured. A stored `until` further out than this from now can only
    /// come from a clock that has since moved back.
    static let maximumWindow: TimeInterval = SDKDefaults.deviceRegistrationTerminalBackoff

    /// The current record, after the launch rules: another SDK version's record is cleared, an
    /// unreadable one is cleared, and a window further out than `maximumWindow` is clamped to
    /// `now + maximumWindow` AND rewritten (never dropped), so the wait converges in real time.
    /// Nil when there is none. `onDiscard` hears why a stored record was cleared.
    static func load(
        storage: StorageProvider,
        now: Date,
        onDiscard: (Discard) -> Void = { _ in }
    ) -> RegistrationBackoffRecord? {
        guard let raw = storage.string(forKey: StorageKeys.deviceRegistrationBackoff) else { return nil }
        guard
            let record = try? JSONDecoder().decode(RegistrationBackoffRecord.self, from: Data(raw.utf8)),
            record.until.isFinite, record.failuresTotal >= 0
        else {
            clear(storage: storage)
            onDiscard(.unreadable)
            return nil
        }
        guard record.writtenBy == SDKDefaults.sdkVersion else {
            clear(storage: storage)
            onDiscard(.otherSDKVersion)
            return nil
        }
        let latest = now.timeIntervalSince1970 + maximumWindow
        guard record.until > latest else { return record }
        var clamped = record
        clamped.until = latest
        if !write(clamped, storage: storage) { onDiscard(.clampNotPersisted) }
        return clamped
    }

    /// One `set` of the whole record. Returns false when the store did not keep it (the read-back
    /// differs, or `synchronize()` reports the flush failed); the caller logs that, never swallows it.
    @discardableResult
    static func write(_ record: RegistrationBackoffRecord, storage: StorageProvider) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        guard let data = try? encoder.encode(record), let json = String(data: data, encoding: .utf8) else {
            return false
        }
        storage.set(json, forKey: StorageKeys.deviceRegistrationBackoff)
        removeLegacyKeys(storage: storage)
        let kept = storage.string(forKey: StorageKeys.deviceRegistrationBackoff) == json
        return storage.synchronize() && kept
    }

    /// A successful registration ends any backoff.
    static func clear(storage: StorageProvider) {
        storage.removeObject(forKey: StorageKeys.deviceRegistrationBackoff)
        removeLegacyKeys(storage: storage)
    }

    private static func removeLegacyKeys(storage: StorageProvider) {
        storage.removeObject(forKey: StorageKeys.legacyDeviceRegistrationBackoffUntil)
        storage.removeObject(forKey: StorageKeys.legacyDeviceRegistrationBackoffSDKVersion)
    }
}
