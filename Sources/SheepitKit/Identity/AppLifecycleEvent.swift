import Foundation

/// What (if anything) `SheepitClient.emitAppInstallOrUpdateIfOwed()` should announce this
/// launch. See `DEVICE_CONTEXT_AND_AUDIENCE_ANALYTICS.md` § 8, decision 7.
enum AppLifecycleEvent: Equatable {
    /// The very first launch of a genuinely fresh install.
    case install
    /// The stored app-version marker differs from the version running now.
    case update(previousVersion: String, currentVersion: String)
    /// Nothing to announce — an existing install's ordinary launch, or a version-marker
    /// backfill with nothing yet to diff against.
    case none
}

/// Decides between `$app_install` / `$app_update` / nothing, from the stored version
/// marker (`StorageKeys.installedAppVersion`) and whether THIS launch minted a fresh
/// device id.
///
/// Kept pure — no `Bundle.main`, no `UserDefaults` — so it is unit-testable independent of
/// whether the XCTest host bundle carries a `CFBundleShortVersionString`
/// (`CrashContextDeviceProfileTests.swift`'s own comment: it may or may not, depending on
/// the environment running the suite).
///
/// 🔴 Decision 7 ("suppress `$app_install` on upgrade") is NOT "does `StorageKeys.deviceId`
/// exist in storage" — by the time `SheepitClient.start()` runs, `beginWork()` has already
/// called `context.persistOnBeginWork()`, so that key is ALWAYS present, even on a
/// genuinely fresh install. (This is the exact dead-guard shape D-1's fix exists to avoid
/// repeating.) The real signal is `ContextManager.didMintDeviceId`, captured inside `init`
/// BEFORE that write: true only when THIS launch minted a fresh device id from empty
/// storage — i.e., a device nobody has ever seen before.
enum AppLifecycleEventDecider {
    static func decide(
        storedVersion: String?,
        currentVersion: String,
        didMintDeviceId: Bool
    ) -> AppLifecycleEvent {
        guard let storedVersion else {
            // No marker yet — either a genuinely fresh install, or an existing install
            // running this bookkeeping for the very first time after upgrading to >=0.4.0.
            // `didMintDeviceId` is what tells those two apart: an existing install already
            // holds a device id restored from storage, so it backfills the marker silently
            // rather than reporting a fake install the day it upgrades.
            return didMintDeviceId ? .install : .none
        }
        guard storedVersion != currentVersion else { return .none }
        return .update(previousVersion: storedVersion, currentVersion: currentVersion)
    }
}
