import Foundation

/// The two ages that govern the cached `/v1/config` body, validated. An age is measured from when
/// the server last sent the body or confirmed it with a 304 (`ConfigSync.confirmCachedBody`). Built from
/// `SheepitConfig.configStaleAfter` / `configOfflineMaxAge` by `ConfigSync`'s owner.
///
/// - `staleAfter`: the age past which a successful fetch was expected to have replaced the cache.
///   An older cache is still applied, and is reported stale (`SDKStatus.ConfigFreshness.isStale`).
/// - `offlineMaxAge`: the oldest cache `loadFromCache()` applies at launch (checked at launch only:
///   a process that stays running offline keeps what it applied). Past it the body is
///   deleted, so a device that stops fetching cannot serve old targeting forever, and the body
///   (one user's evaluated flags and assignments) does not stay on the device indefinitely.
///
/// 🔴 Validated HERE, at the consumer, as well as in `SheepitConfig.init`: both are public `var`s,
/// so `cfg.configOfflineMaxAge = .infinity` after init bypasses the initializer (the MF-1 pattern
/// of `sanitizedForSleep()`). An infinite or NaN limit would make every cache valid forever.
struct CachedConfigLimits: Sendable, Equatable {
    let staleAfter: TimeInterval
    let offlineMaxAge: TimeInterval

    /// What `issues` the input had, for one log line at client creation.
    let issues: [String]

    static let `default` = CachedConfigLimits(
        staleAfter: SDKDefaults.configStaleAfter,
        offlineMaxAge: SDKDefaults.configOfflineMaxAge
    )

    /// A value that is not finite and positive falls back to its default. When `offlineMaxAge` is
    /// below `staleAfter`, `staleAfter` comes DOWN to it rather than `offlineMaxAge` going up: a host
    /// that asks for a shorter offline limit is asking for less retention, and that request wins.
    init(staleAfter: TimeInterval, offlineMaxAge: TimeInterval) {
        var issues: [String] = []
        var stale = staleAfter
        var maxAge = offlineMaxAge
        if !(stale.isFinite && stale > 0) {
            issues.append("configStaleAfter must be finite and positive; using \(SDKDefaults.configStaleAfter) s")
            stale = SDKDefaults.configStaleAfter
        }
        if !(maxAge.isFinite && maxAge > 0) {
            issues.append("configOfflineMaxAge must be finite and positive; using \(SDKDefaults.configOfflineMaxAge) s")
            maxAge = SDKDefaults.configOfflineMaxAge
        }
        if maxAge < stale {
            issues.append("configOfflineMaxAge (\(maxAge) s) is below configStaleAfter; lowering configStaleAfter to it")
            stale = maxAge
        }
        self.staleAfter = stale
        self.offlineMaxAge = maxAge
        self.issues = issues
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.staleAfter == rhs.staleAfter && lhs.offlineMaxAge == rhs.offlineMaxAge
    }
}
