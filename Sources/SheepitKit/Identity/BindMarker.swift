import Foundation

/// The persisted record of which devices an identify POST was SENT for (`StorageKeys.deviceBindAttempted`):
/// the most recent `cap` device ids, oldest first, as a JSON array in the string slot. Read by
/// `DeviceRotation.deviceMayBeBound()`; written before every identify request and by the 0.5.x upgrade
/// in `StorageScope.adoptLegacyState`.
///
/// 🔴 A set, not one id. The slot is shared by every client in the process (it is not scoped), and
/// 0.6.0 through 0.7.x kept a single id that every bind overwrote: client B's unanswered POST for
/// device D was erased by client A's bind of a replacement F, and B's `reset()` (in a later launch,
/// with no in-process record of its own POST) then kept D, which may hold the user. Every id stays
/// until `cap` newer binds push it out, so one client's bind never hides another's. Over-rotating is
/// safe; under-rotating leaks the logged-out user's targeting.
///
/// A bare id (what 0.6.0 through 0.7.x wrote) reads as a one-element set: device ids never start with
/// `[`. An array that does not decode counts as holding every id (fail toward rotating) until the
/// next bind overwrites it. Nothing removes an id on rotation or replacement: a stale id simply stops
/// matching the current device.
enum BindMarker {
    /// How many recent binds are remembered. Ids are only ever matched against the current one, so a
    /// larger cap is strictly safer; it bounds the slot, and must outlast every rotation and
    /// replacement other clients make before a client with an unanswered POST logs out.
    static let cap = 32

    /// 🔴 Serialises every read-modify-write across the process: two clients marking at once must not
    /// drop each other's id, which is the lost update this type exists to prevent. Like
    /// `StorageScope.adoptionLock`, it cannot serialise another process sharing the suite.
    private static let lock = NSLock()

    /// Whether an identify POST was sent for `deviceId` within the last `cap` binds.
    static func contains(_ deviceId: String, in storage: StorageProvider) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let ids = stored(in: storage) else { return true }
        return ids.contains(deviceId)
    }

    /// The marked ids, oldest first; empty for a value that does not decode.
    static func ids(in storage: StorageProvider) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored(in: storage) ?? []
    }

    /// Record `deviceId` as the newest bind, moving it to the end if present and trimming the oldest
    /// beyond `cap`.
    static func insert(_ deviceId: String, in storage: StorageProvider) {
        lock.lock()
        defer { lock.unlock() }
        var ids = (stored(in: storage) ?? []).filter { $0 != deviceId }
        ids.append(deviceId)
        write(Array(ids.suffix(cap)), to: storage)
    }

    /// Record `added` only if `existing` is already marked, under one lock hold. For a swap that
    /// carries a bind forward to the device about to replace it.
    static func insert(_ added: String, ifContains existing: String, in storage: StorageProvider) {
        lock.lock()
        defer { lock.unlock() }
        // An undecodable value counts as holding `existing`; it is rewritten with just the two ids.
        var ids = stored(in: storage) ?? [existing]
        guard ids.contains(existing) else { return }
        ids.removeAll { $0 == added }
        ids.append(added)
        write(Array(ids.suffix(cap)), to: storage)
    }

    /// Nil for an array that does not decode. Caller holds `lock`.
    private static func stored(in storage: StorageProvider) -> [String]? {
        guard let raw = storage.string(forKey: StorageKeys.deviceBindAttempted), !raw.isEmpty else { return [] }
        guard raw.hasPrefix("[") else { return [raw] }
        return try? JSONDecoder().decode([String].self, from: Data(raw.utf8))
    }

    private static func write(_ ids: [String], to storage: StorageProvider) {
        guard let data = try? JSONEncoder().encode(ids), let encoded = String(data: data, encoding: .utf8) else { return }
        storage.set(encoded, forKey: StorageKeys.deviceBindAttempted)
    }
}
