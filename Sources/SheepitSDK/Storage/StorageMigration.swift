import Foundation

/// One-pass migration for the LaunchPad → GoaTech storage-key rename.
/// Swift counterpart to `packages/sdk-js/src/storage-migration.ts`.
///
/// Runs once at SDK init, BEFORE anything reads storage. For every `gt_*`
/// key that is empty but has a populated `lp_*` sibling, the value is
/// copied across so an existing install does not lose its device id,
/// identity, offline event queue, or experiment assignments — which would
/// otherwise re-register the device as brand new and re-bucket every
/// experiment.
///
/// Idempotent: a marker key records the run, so later launches skip the
/// work. Safe to re-run with no side effects if the marker is wiped.
///
/// The legacy `lp_*` strings live ONLY in this file. Everything else reads
/// `StorageKeys.<name>`.
enum StorageMigration {
    static let markerKey = "gt_storage_migration_v1"
    private static let markerValue = "done"

    /// `(legacy, current)` pairs. Mirrors `KEY_MAP` in the JS SDK, minus
    /// the two attribution keys — mobile attribution capture is not
    /// implemented on this platform, so there is nothing to migrate.
    static let keyMap: [(legacy: String, current: String)] = [
        ("lp_device_id", StorageKeys.deviceId),
        ("lp_anonymous_id", StorageKeys.anonymousId),
        ("lp_identity", StorageKeys.identity),
        ("lp_config", StorageKeys.sdkConfig),
        ("lp_offline_queue", StorageKeys.offlineQueue),
        ("lp_session_id", StorageKeys.sessionId),
        ("lp_session_last_seen", StorageKeys.sessionLastSeen),
        ("lp_exp_assignments", StorageKeys.experimentAssignments),
    ]

    /// Copy any legacy values forward. No-op once the marker is set.
    ///
    /// Concurrency: `Sheepit.create()` is documented as supporting multiple
    /// independent instances, so two of them can race here on the same
    /// UserDefaults suite. That is safe ONLY because every step is
    /// idempotent — both threads copy the same source value, and
    /// `removeObject` on an already-removed key is a no-op. Adding a
    /// non-idempotent step here would require real synchronisation.
    ///
    /// Values are read as `Data` first and as `String` second: the SDK
    /// stores the offline queue, cached config, identity and experiment
    /// assignments as JSON `Data` but the ids as `String`, and
    /// `UserDefaults.string(forKey:)` returns nil for a `Data` value.
    static func run(storage: StorageProvider) {
        guard storage.string(forKey: markerKey) != markerValue else { return }

        for entry in keyMap {
            // Already migrated, or freshly written by a newer install.
            if storage.data(forKey: entry.current) != nil { continue }
            if storage.string(forKey: entry.current) != nil { continue }

            if let legacyData = storage.data(forKey: entry.legacy) {
                storage.set(legacyData, forKey: entry.current)
            } else if let legacyString = storage.string(forKey: entry.legacy) {
                storage.set(legacyString, forKey: entry.current)
            } else {
                continue
            }

            // Drop the legacy key so the stored surface is clean; the new
            // key holds the value and nothing reads `lp_*` past this point.
            storage.removeObject(forKey: entry.legacy)
        }

        storage.set(markerValue, forKey: markerKey)
    }
}
