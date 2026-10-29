import Foundation

/// Per-tenancy storage slots: what the SDK knows about ONE server (apiUrl, environment, apiKey) is
/// kept under `key:<hash>`, so two builds of one app sharing a bundle id (a Debug build on the
/// staging key, a TestFlight build on production) stop reading each other's server state.
///
/// 🔴 Before this, 0.7.0 kept it under fixed keys. A build on environment B found
/// `gt_device_registered` written for environment A, skipped registration, and its launch identify
/// POST answered 404 (the device row is per project, environment and device), which it recorded as a
/// rejection: that install stayed anonymous for good. A's cached config, registration backoff,
/// server-held label and offline queue leaked into B the same way.
///
/// Scoped: the server's knowledge of this device (`scopedKeys`) and the offline queue, whose events
/// were stamped for one project and must not be sent with another's key. Shared: the device and
/// anonymous ids (registering in a new scope sends the existing id and the server upserts that
/// environment's row, so one install stays one device everywhere), the app's own `identity`, the
/// session, the markers, and `deviceBindAttempted`: a bind in any scope is a fact about the shared
/// device, so `reset()` in every scope must rotate it (over-rotating is safe, under-rotating leaks
/// the user's targeting). sdk-js counterpart: `tenancyScopeHash` in `config-sync.ts`; it scopes the
/// device id, where Swift shares it and scopes the offline queue instead.
enum StorageScope {
    /// The keys `ScopedStorage` moves into a slot. Every other key passes through unchanged.
    static let scopedKeys: Set<String> = [
        StorageKeys.deviceRegistered,
        StorageKeys.serverHeldUser,
        StorageKeys.sdkConfig,
        StorageKeys.sdkConfigCachedAt,
        StorageKeys.sdkConfigFetchedUnder,
        StorageKeys.deviceRegistrationBackoffUntil,
        StorageKeys.deviceRegistrationBackoffSDKVersion,
        StorageKeys.offlineQueue,
    ]

    /// Byte-for-byte sdk-js `tenancyScopeHash`: FNV-1a (32-bit) over the UTF-16 code units of
    /// `JSON.stringify([apiUrl, environment, apiKey])`, in base 36. `apiUrl` is the RAW configured
    /// value, not normalised: sdk-js hashes the raw value too, and normalising here would move every
    /// install with a trailing slash to a new slot. Pinned by `StorageScopeTests`.
    static func hash(apiUrl: String, environment: String, apiKey: String) -> String {
        fnv1a(jsonStringify([apiUrl, environment, apiKey]))
    }

    static func hash(for config: SheepitConfig) -> String {
        hash(apiUrl: config.apiUrl, environment: config.environment, apiKey: config.apiKey)
    }

    /// The slot key: the same `key:<hash>` shape sdk-js uses.
    static func key(_ base: String, scope: String) -> String {
        "\(base):\(scope)"
    }

    /// JS `Math.imul` FNV-1a, which iterates `charCodeAt` (UTF-16 units), not bytes or scalars.
    static func fnv1a(_ input: String) -> String {
        var hash: UInt32 = 0x811c_9dc5
        for unit in input.utf16 {
            hash = (hash ^ UInt32(unit)) &* 0x0100_0193
        }
        return String(hash, radix: 36)
    }

    /// `JSON.stringify` of an array of strings. Not `JSONEncoder`: it escapes `/` and is free to
    /// differ elsewhere, and one differing byte is a different slot from sdk-js. JS escapes only `"`,
    /// `\` and the C0 controls (short forms where they exist, else lowercase `\u00xx`); a Swift
    /// `String` cannot hold the lone surrogates it also escapes.
    static func jsonStringify(_ values: [String]) -> String {
        var out = "["
        for (index, value) in values.enumerated() {
            if index > 0 { out += "," }
            out += "\""
            for scalar in value.unicodeScalars {
                switch scalar {
                case "\"": out += "\\\""
                case "\\": out += "\\\\"
                case "\u{08}": out += "\\b"
                case "\u{0C}": out += "\\f"
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                case let control where control.value < 0x20:
                    let hex = String(control.value, radix: 16)
                    out += "\\u" + String(repeating: "0", count: 4 - hex.count) + hex
                default:
                    out.unicodeScalars.append(scalar)
                }
            }
            out += "\""
        }
        return out + "]"
    }

    /// What the one-time upgrade found. See `adoptLegacyState`.
    struct Adoption: Equatable {
        let serverStateDiscarded: Bool
        let queue: OfflineQueue.Adoption
    }

    /// Serialises the upgrade across every client in the process: two clients on different keys
    /// beginning work at once must not both adopt the same legacy queue. Assumes the suite is not
    /// shared across processes (an App Group): a lock cannot serialise another process.
    private static let adoptionLock = NSLock()

    /// The upgrade from an SDK that kept this state unscoped, run from `beginWork()` (never from
    /// `init`: a constructed-but-unpublished `initialize()` loser must write nothing).
    ///
    /// The legacy server knowledge is DISCARDED, not moved: nothing says which server wrote it, and
    /// 0.7.0 installs stranded on the wrong environment are exactly the ones carrying it. With the
    /// slot empty, `start()` registers (the existing device id, so an install already known to this
    /// environment is an idempotent upsert) and the launch identify POST binds the stored user. The
    /// legacy offline queue is ADOPTED into this slot: those events were never sent, and the scope
    /// that wrote them most likely is this one. Once the legacy keys are gone nothing finds them
    /// again, so this runs once per install. `gt_identity` (the app's own user id) and the bind marker
    /// (shared, never scoped) are never touched.
    ///
    /// Emits nothing: diagnostics reach host callbacks, and those must not run under `adoptionLock`.
    ///
    /// - Returns: nil when there was no legacy state.
    static func adoptLegacyState(raw: StorageProvider, into offlineQueue: OfflineQueue) -> Adoption? {
        adoptionLock.lock()
        defer { adoptionLock.unlock() }
        // 🔴 Before the label goes: 0.5.x wrote `gt_server_held_user` but had no bind marker (it came
        // with `DeviceRotation` in 0.6.0), so the label is its only record that the device holds a
        // user. Without this, a `reset()` before this launch's identify POST went out kept the device.
        // Worst case one extra rotation. Inserted, not written over: the marker is a set (`BindMarker`)
        // and may already hold ids another client bound.
        if let label = raw.data(forKey: StorageKeys.serverHeldUser),
           case .known(let userId?)? = try? JSONDecoder().decode(ServerHeldUser.self, from: label),
           !userId.isEmpty,
           let deviceId = raw.string(forKey: StorageKeys.deviceId) {
            BindMarker.insert(deviceId, in: raw)
        }
        var discarded = false
        for key in scopedKeys where key != StorageKeys.offlineQueue {
            guard raw.data(forKey: key) != nil || raw.string(forKey: key) != nil else { continue }
            raw.removeObject(forKey: key)
            discarded = true
        }
        var queue: OfflineQueue.Adoption?
        if let data = raw.data(forKey: StorageKeys.offlineQueue) {
            queue = offlineQueue.adoptPersisted(data)
            raw.removeObject(forKey: StorageKeys.offlineQueue)
        }
        guard discarded || queue != nil else { return nil }
        return Adoption(serverStateDiscarded: discarded, queue: queue ?? .init(kept: 0, trimmed: 0, unencodable: 0))
    }
}

/// Rewrites exactly `StorageScope.scopedKeys` to their `key:<hash>` slot, so every component keeps
/// reading and writing `StorageKeys.x` and never learns which slot it is in. `StorageMigration` and
/// the upgrade in `StorageScope.adoptLegacyState` take the raw storage instead.
final class ScopedStorage: StorageProvider, @unchecked Sendable {
    let base: StorageProvider
    let scope: String

    init(base: StorageProvider, scope: String) {
        self.base = base
        self.scope = scope
    }

    func resolve(_ key: String) -> String {
        StorageScope.scopedKeys.contains(key) ? StorageScope.key(key, scope: scope) : key
    }

    func string(forKey key: String) -> String? { base.string(forKey: resolve(key)) }
    func set(_ value: String?, forKey key: String) { base.set(value, forKey: resolve(key)) }
    func data(forKey key: String) -> Data? { base.data(forKey: resolve(key)) }
    func set(_ value: Data?, forKey key: String) { base.set(value, forKey: resolve(key)) }
    func removeObject(forKey key: String) { base.removeObject(forKey: resolve(key)) }
}
