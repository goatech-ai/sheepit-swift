import XCTest
@testable import SheepitKit

/// The `lp_*` → `gt_*` rename is only safe because of this migration.
/// Without it, an existing install reads empty `gt_*` keys on first launch
/// after the upgrade and looks brand new: fresh device id (re-registers as
/// a new device), lost identity, dropped offline queue, and re-bucketed
/// experiments — a silent data-loss event across the whole installed base.
final class StorageMigrationTests: XCTestCase {
    func testLegacyStringValuesMoveToTheNewKeys() {
        let storage = InMemoryStorage()
        storage.set("device-abc", forKey: "lp_device_id")
        storage.set("anon-xyz", forKey: "lp_anonymous_id")
        storage.set("session-1", forKey: "lp_session_id")
        storage.set("1700000000.0", forKey: "lp_session_last_seen")

        StorageMigration.run(storage: storage)

        XCTAssertEqual(storage.string(forKey: StorageKeys.deviceId), "device-abc")
        XCTAssertEqual(storage.string(forKey: StorageKeys.anonymousId), "anon-xyz")
        XCTAssertEqual(storage.string(forKey: StorageKeys.sessionId), "session-1")
        XCTAssertEqual(storage.string(forKey: StorageKeys.sessionLastSeen), "1700000000.0")
    }

    func testLegacyDataValuesMoveToTheNewKeys() throws {
        // The offline queue, cached config, identity and experiment
        // assignments are stored as JSON Data, not String —
        // `string(forKey:)` returns nil for those, so a string-only
        // migration would silently drop them.
        let storage = InMemoryStorage()
        let queueBlob = Data(#"[{"event_name":"a"}]"#.utf8)
        let assignments = Data(#"{"exp":"variant_b"}"#.utf8)
        storage.set(queueBlob, forKey: "lp_offline_queue")
        storage.set(assignments, forKey: "lp_exp_assignments")
        storage.set(Data(#"{"userId":"user_1"}"#.utf8), forKey: "lp_identity")
        storage.set(Data(#"{"flags":{}}"#.utf8), forKey: "lp_config")

        StorageMigration.run(storage: storage)

        XCTAssertEqual(storage.data(forKey: StorageKeys.offlineQueue), queueBlob)
        XCTAssertEqual(storage.data(forKey: StorageKeys.experimentAssignments), assignments)
        XCTAssertNotNil(storage.data(forKey: StorageKeys.identity))
        XCTAssertNotNil(storage.data(forKey: StorageKeys.sdkConfig))
    }

    func testLegacyKeysAreRemovedAfterMigration() {
        let storage = InMemoryStorage()
        storage.set("device-abc", forKey: "lp_device_id")

        StorageMigration.run(storage: storage)

        XCTAssertNil(storage.string(forKey: "lp_device_id"), "legacy key is cleaned up")
        XCTAssertEqual(storage.string(forKey: StorageKeys.deviceId), "device-abc")
    }

    func testExistingNewKeysAreNeverOverwritten() {
        let storage = InMemoryStorage()
        storage.set("legacy-device", forKey: "lp_device_id")
        storage.set("current-device", forKey: StorageKeys.deviceId)

        StorageMigration.run(storage: storage)

        XCTAssertEqual(
            storage.string(forKey: StorageKeys.deviceId),
            "current-device",
            "a populated gt_* key must win over its lp_* sibling"
        )
    }

    func testExistingNewDataKeysAreNeverOverwritten() {
        let storage = InMemoryStorage()
        storage.set(Data("legacy".utf8), forKey: "lp_offline_queue")
        storage.set(Data("current".utf8), forKey: StorageKeys.offlineQueue)

        StorageMigration.run(storage: storage)

        XCTAssertEqual(storage.data(forKey: StorageKeys.offlineQueue), Data("current".utf8))
    }

    func testMigrationIsIdempotent() {
        let storage = InMemoryStorage()
        storage.set("device-abc", forKey: "lp_device_id")

        StorageMigration.run(storage: storage)
        XCTAssertEqual(storage.string(forKey: StorageMigration.markerKey), "done")

        // A later launch writes a legacy key again (e.g. an older build ran
        // in between). The marker means we do not clobber current state.
        storage.set("stale-device", forKey: "lp_device_id")
        storage.set("newer-device", forKey: StorageKeys.deviceId)
        StorageMigration.run(storage: storage)

        XCTAssertEqual(storage.string(forKey: StorageKeys.deviceId), "newer-device")
    }

    func testFreshInstallIsANoOpButStillMarks() {
        let storage = InMemoryStorage()

        StorageMigration.run(storage: storage)

        XCTAssertNil(storage.string(forKey: StorageKeys.deviceId))
        XCTAssertEqual(storage.string(forKey: StorageMigration.markerKey), "done")
    }

    func testEveryStorageKeyIsCovered() {
        // A new StorageKeys entry without a migration entry is a silent
        // data-loss bug for upgrading installs, so pin the mapping.
        let migrated = Set(StorageMigration.keyMap.map(\.current))
        let allKeys: Set<String> = [
            StorageKeys.deviceId,
            StorageKeys.anonymousId,
            StorageKeys.identity,
            StorageKeys.sdkConfig,
            StorageKeys.offlineQueue,
            StorageKeys.sessionId,
            StorageKeys.sessionLastSeen,
            StorageKeys.experimentAssignments,
        ]
        XCTAssertEqual(migrated, allKeys)
        XCTAssertTrue(
            StorageMigration.keyMap.allSatisfy { $0.legacy.hasPrefix("lp_") },
            "legacy side must be the lp_ prefix"
        )
        XCTAssertTrue(
            StorageMigration.keyMap.allSatisfy { $0.current.hasPrefix("gt_") },
            "current side must be the gt_ prefix"
        )
    }

    func testDebugOverridesKeyIsDeliberatelyNotRenamed() {
        // sdk-js keeps this one on lp_ too (packages/sdk-js/src/flags.ts:3).
        // Renaming it here would be a gratuitous cross-platform divergence.
        XCTAssertFalse(
            StorageMigration.keyMap.contains { $0.legacy == "lp_debug_overrides" },
            "debug overrides are intentionally excluded from the migration"
        )
    }

    /// End-to-end: an upgrading install keeps its identity.
    func testUpgradingInstallKeepsItsDeviceIdentity() {
        let storage = InMemoryStorage()
        storage.set("device-from-v0", forKey: "lp_device_id")
        storage.set("anon-from-v0", forKey: "lp_anonymous_id")

        StorageMigration.run(storage: storage)
        let context = ContextManager(storage: storage)

        XCTAssertEqual(context.deviceId, "device-from-v0", "must not re-register as a new device")
        XCTAssertEqual(context.anonymousId, "anon-from-v0", "must not break the anon→known stitch")
    }

    // MARK: - Against the real storage engine
    //
    // Every test above uses InMemoryStorage, whose string/data accessors are
    // strict `as?` casts on a dictionary. Production uses
    // UserDefaultsStorage, where `string(forKey:)` returns nil for a Data
    // value and vice versa. A migration that exists specifically to prevent
    // silent data loss on upgrade should be exercised against the engine it
    // actually runs on.

    func testMigrationAgainstRealUserDefaults() throws {
        let suiteName = "ai.goatech.sdk.tests.migration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storage = UserDefaultsStorage(suiteName: suiteName)

        // Mixed String and Data legacy values, exactly as the SDK writes them.
        defaults.set("device-from-v0", forKey: "lp_device_id")
        defaults.set("anon-from-v0", forKey: "lp_anonymous_id")
        defaults.set("session-from-v0", forKey: "lp_session_id")
        let queueBlob = Data(#"[{"event_name":"queued"}]"#.utf8)
        defaults.set(queueBlob, forKey: "lp_offline_queue")
        defaults.set(Data(#"{"exp":"variant_b"}"#.utf8), forKey: "lp_exp_assignments")

        StorageMigration.run(storage: storage)

        XCTAssertEqual(defaults.string(forKey: StorageKeys.deviceId), "device-from-v0")
        XCTAssertEqual(defaults.string(forKey: StorageKeys.anonymousId), "anon-from-v0")
        XCTAssertEqual(defaults.string(forKey: StorageKeys.sessionId), "session-from-v0")
        XCTAssertEqual(defaults.data(forKey: StorageKeys.offlineQueue), queueBlob)
        XCTAssertNotNil(defaults.data(forKey: StorageKeys.experimentAssignments))

        XCTAssertNil(defaults.object(forKey: "lp_device_id"), "legacy keys cleaned up")
        XCTAssertNil(defaults.object(forKey: "lp_offline_queue"))
        XCTAssertEqual(defaults.string(forKey: StorageMigration.markerKey), "done")

        // And the migrated state is what a real ContextManager reads back.
        let context = ContextManager(storage: storage)
        XCTAssertEqual(context.deviceId, "device-from-v0")
        XCTAssertEqual(context.anonymousId, "anon-from-v0")
    }

    func testRealUserDefaultsMigrationIsIdempotent() throws {
        let suiteName = "ai.goatech.sdk.tests.idempotent.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let storage = UserDefaultsStorage(suiteName: suiteName)

        defaults.set("device-from-v0", forKey: "lp_device_id")
        StorageMigration.run(storage: storage)

        // Second launch: a stale legacy value must not clobber current state.
        defaults.set("stale", forKey: "lp_device_id")
        StorageMigration.run(storage: storage)

        XCTAssertEqual(defaults.string(forKey: StorageKeys.deviceId), "device-from-v0")
    }

    func testWithoutMigrationTheInstallWouldLookNew() {
        // The counterfactual the migration exists to prevent.
        let storage = InMemoryStorage()
        storage.set("device-from-v0", forKey: "lp_device_id")

        let context = ContextManager(storage: storage)

        XCTAssertNotEqual(context.deviceId, "device-from-v0")
    }
}
