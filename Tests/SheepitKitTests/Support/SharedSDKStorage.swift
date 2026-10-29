import Foundation
@testable import SheepitKit

/// Every `SheepitClient` built in this test target reads and writes the ONE hardcoded
/// `ai.goatech.sdk` `UserDefaults` suite. A suite that leaves keys behind (a device id, a session,
/// an offline backlog) changes what the next suite's client starts from. Clear it in BOTH `setUp`
/// and `tearDown` of any suite that builds a client.
///
/// 🔴 This isolates suites within ONE test process only. The suite is per USER, so a concurrent
/// test run in another clone shares it; that cross-process problem is queued in `PENDING_WORK.md`.
///
/// Key by key with `removeObject`, the same operation every other suite in this target uses.
/// `SharedSDKStorageTests` fails if a `StorageKeys` entry is missing from `keys`.
enum SharedSDKStorage {
    static let suite = "ai.goatech.sdk"

    static let keys: [String] = [
        StorageKeys.deviceId, StorageKeys.anonymousId, StorageKeys.identity, StorageKeys.sdkConfig,
        StorageKeys.sdkConfigCachedAt, StorageKeys.sdkConfigFetchedUnder, StorageKeys.serverHeldUser,
        StorageKeys.offlineQueue, StorageKeys.sessionId, StorageKeys.sessionLastSeen,
        StorageKeys.experimentAssignments, StorageKeys.deviceRegistered, StorageKeys.deviceBindAttempted,
        StorageKeys.deviceRegistrationBackoffUntil, StorageKeys.deviceRegistrationBackoffSDKVersion,
        StorageKeys.installedAppVersion,
    ]

    /// Also every `key:<hash>` slot (`StorageScope`): each config a suite uses writes its own.
    static func clear() {
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        for key in keys { remove(key, from: defaults) }
    }

    /// `key` and every scoped slot of it.
    static func remove(_ key: String, from defaults: UserDefaults? = UserDefaults(suiteName: suite)) {
        guard let defaults else { return }
        defaults.removeObject(forKey: key)
        for stored in defaults.dictionaryRepresentation().keys where stored.hasPrefix(key + ":") {
            defaults.removeObject(forKey: stored)
        }
    }

    /// `key(_:for:)` for the config most client suites share (`lp_pub_tst_a…`, production,
    /// `https://stub.invalid`): the slot a suite seeds and reads through the real suite.
    static func slot(_ key: String) -> String {
        self.key(key, for: standardConfig)
    }

    /// Seeds "this device registered" for the standard config: `deviceId` (or the stored id, or a new
    /// one) as `gt_device_id`, and the same id in the registered slot, which counts only when it names
    /// the current id. Returns the id.
    @discardableResult
    static func markRegistered(_ deviceId: String? = nil) -> String {
        let defaults = UserDefaults(suiteName: suite)
        let id = deviceId ?? defaults?.string(forKey: StorageKeys.deviceId) ?? UUID().uuidString
        defaults?.set(id, forKey: StorageKeys.deviceId)
        defaults?.set(id, forKey: slot(StorageKeys.deviceRegistered))
        return id
    }

    /// Seeds "an identify POST was sent for `deviceId`" in the shared bind marker, in its current
    /// format (`BindMarker`). A bare id is the 0.6.0–0.7.x format: seed that only to test the upgrade.
    static func markBindAttempted(_ deviceId: String) {
        BindMarker.insert(deviceId, in: UserDefaultsStorage(suiteName: suite))
    }

    /// The device ids the shared bind marker holds, oldest first.
    static func bindAttempted() -> [String] {
        BindMarker.ids(in: UserDefaultsStorage(suiteName: suite))
    }

    /// Whether the standard config's registered slot names the stored device id.
    static func isRegistered() -> Bool {
        let defaults = UserDefaults(suiteName: suite)
        guard let registered = defaults?.string(forKey: slot(StorageKeys.deviceRegistered)) else { return false }
        return registered == defaults?.string(forKey: StorageKeys.deviceId)
    }

    /// The real suite as a client on that config sees it.
    static func slotStorage() -> StorageProvider {
        ScopedStorage(base: UserDefaultsStorage(suiteName: suite), scope: StorageScope.hash(for: standardConfig))
    }

    private static let standardConfig = SheepitConfig(
        apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64), apiUrl: "https://stub.invalid"
    )

    /// The key a client on `config` reads `key` from: its slot for a scoped key, `key` itself otherwise.
    static func key(_ key: String, for config: SheepitConfig) -> String {
        ScopedStorage(base: InMemoryStorage(), scope: StorageScope.hash(for: config)).resolve(key)
    }
}
