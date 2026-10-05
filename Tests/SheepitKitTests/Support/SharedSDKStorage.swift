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

    static func clear() {
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        for key in keys { defaults.removeObject(forKey: key) }
    }
}
