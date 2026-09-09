import Foundation

/// Detects rapid consecutive crashes and disables crash reporting to prevent
/// infinite crash loops (e.g., crash-on-launch -> upload -> crash -> repeat).
enum CrashLoopProtection {
    private static let timestampsKey = "sheepit_crash_timestamps"
    private static let disabledKey = "sheepit_crash_loop_disabled"

    /// Returns `true` if it is safe to install crash handlers.
    /// Returns `false` if the app is in a crash loop and should skip installation.
    static func shouldInstallHandlers(config: CrashConfig, storage: StorageProvider) -> Bool {
        if storage.string(forKey: disabledKey) == "1" { return false }

        let raw = storage.string(forKey: timestampsKey) ?? ""
        let now = Date().timeIntervalSince1970
        let window = Double(config.crashLoopWindowSeconds)

        let recentCrashes = raw.split(separator: ",")
            .compactMap { Double($0) }
            .filter { now - $0 < window }

        if recentCrashes.count >= config.crashLoopThreshold {
            storage.set("1", forKey: disabledKey)
            return false
        }

        return true
    }

    /// Record that a crash occurred. Called when a pending crash report is found on launch.
    static func recordCrash(storage: StorageProvider) {
        let existing = storage.string(forKey: timestampsKey) ?? ""
        var entries = existing.split(separator: ",").map(String.init)
        entries.append(String(Date().timeIntervalSince1970))

        // Keep only the last 10 entries
        if entries.count > 10 {
            entries = Array(entries.suffix(10))
        }

        storage.set(entries.joined(separator: ","), forKey: timestampsKey)
    }

    /// Record a successful launch (no crash). Called after the app has been running
    /// for a sufficient period without crashing. Resets the crash counter and re-enables
    /// crash reporting if it was disabled by loop protection.
    static func recordSuccessfulLaunch(storage: StorageProvider) {
        storage.set(nil as String?, forKey: timestampsKey)
        storage.set(nil as String?, forKey: disabledKey)
    }
}
