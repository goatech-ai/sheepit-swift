import Foundation

/// The persisted "gave up registering for now" window after a terminal registration failure.
/// Written by `SheepitClient.start()` and `DeviceRotation`, read by `start()`'s guard.
///
/// Two limits keep it from stranding a device longer than it should:
///   - **Per SDK build.** A backoff written by another `SDKDefaults.sdkVersion` is ignored: the new
///     build may carry the fix for whatever was rejected (a 400 is always the SDK's own body).
///   - **Clock skew.** A window ending further out than `deviceRegistrationTerminalBackoff` from now
///     can only come from a clock that has since moved back, and is ignored.
enum RegistrationBackoff {
    /// `duration` defaults to the terminal (24h) window; the shorter `SDKDefaults.
    /// deviceRegistrationCapBackoff` is passed explicitly for a 422 (environment device cap) —
    /// see `RegistrationOutcome.capReached`'s doc for why that case gets a shorter window.
    static func record(
        storage: StorageProvider,
        now: Date,
        duration: TimeInterval = SDKDefaults.deviceRegistrationTerminalBackoff
    ) {
        storage.set(
            String(now.timeIntervalSince1970 + duration),
            forKey: StorageKeys.deviceRegistrationBackoffUntil
        )
        storage.set(SDKDefaults.sdkVersion, forKey: StorageKeys.deviceRegistrationBackoffSDKVersion)
    }

    /// A successful registration ends any backoff.
    static func clear(storage: StorageProvider) {
        storage.removeObject(forKey: StorageKeys.deviceRegistrationBackoffUntil)
        storage.removeObject(forKey: StorageKeys.deviceRegistrationBackoffSDKVersion)
    }

    static func isActive(storage: StorageProvider, now: Date) -> Bool {
        guard
            let raw = storage.string(forKey: StorageKeys.deviceRegistrationBackoffUntil),
            let until = TimeInterval(raw),
            storage.string(forKey: StorageKeys.deviceRegistrationBackoffSDKVersion) == SDKDefaults.sdkVersion
        else { return false }
        let remaining = until - now.timeIntervalSince1970
        return remaining > 0 && remaining <= SDKDefaults.deviceRegistrationTerminalBackoff
    }
}
