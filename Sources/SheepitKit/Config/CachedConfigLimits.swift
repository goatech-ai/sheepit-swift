import Foundation

/// The two ages that govern the cached `/v1/config` body, validated. An age is measured from when
/// the server last sent the body or confirmed it with a 304 (`ConfigSync.confirmCachedBody`). Built from
/// `SheepitConfig.configStaleAfter` / `configOfflineMaxAge` by `ConfigSync`'s owner.
///
/// - `staleAfter`: the age past which a successful fetch was expected to have replaced the cache.
///   An older cache is still applied, and is reported stale (`SDKStatus.ConfigFreshness.isStale`).
/// - `offlineMaxAge`: the oldest cache applied at launch (`LaunchConfigCache`, checked at launch
///   only: a process that stays running offline keeps what it applied). `.infinity`, the default
///   since 0.10.2, is no limit: the cache is applied whatever its age until a successful fetch
///   replaces it or `reset()` deletes it, so a device that cannot reach the server (off the VPN, no
///   signal) never falls back to compiled-in defaults. A finite value set by the host is honoured:
///   past it the body is deleted at launch.
///
/// 🔴 Validated HERE, at the consumer, as well as in `SheepitConfig.init`: both are public `var`s,
/// so a mutation after init bypasses the initializer (the MF-1 pattern of `sanitizedForSleep()`).
/// A NaN, zero or negative limit falls back to its default. Either may be `.infinity`: no limit for
/// `offlineMaxAge`, never stale by age for `staleAfter`.
struct CachedConfigLimits: Sendable, Equatable {
    let staleAfter: TimeInterval
    let offlineMaxAge: TimeInterval

    /// What `issues` the input had, for one log line at client creation.
    let issues: [String]

    static let `default` = CachedConfigLimits(
        staleAfter: SDKDefaults.configStaleAfter,
        offlineMaxAge: SDKDefaults.configOfflineMaxAge
    )

    /// Whether the host set a finite offline limit. Without one, nothing is deleted for its age.
    var hasOfflineLimit: Bool { offlineMaxAge.isFinite }

    /// Both must be positive; `.infinity` is valid for either, as in sdk-js
    /// (`resolveCachedConfigLimits`). An invalid value falls back to its default. When
    /// `offlineMaxAge` is below `staleAfter`, `staleAfter` comes DOWN to it rather than
    /// `offlineMaxAge` going up: a host that asks for a shorter offline limit is asking for less
    /// retention, and that request wins (sdk-js applies the same rule).
    init(staleAfter: TimeInterval, offlineMaxAge: TimeInterval) {
        var issues: [String] = []
        var stale = staleAfter
        var maxAge = offlineMaxAge
        // `.nan > 0` is false, so NaN lands here too.
        if !(stale > 0) {
            issues.append("configStaleAfter must be positive (.infinity for never stale); using \(SDKDefaults.configStaleAfter) s")
            stale = SDKDefaults.configStaleAfter
        }
        // `.nan > 0` is false, so NaN lands here too.
        if !(maxAge > 0) {
            issues.append("configOfflineMaxAge must be positive (.infinity for no limit); using \(Self.describe(SDKDefaults.configOfflineMaxAge))")
            maxAge = SDKDefaults.configOfflineMaxAge
        }
        if maxAge < stale {
            issues.append("configOfflineMaxAge (\(Self.describe(maxAge))) is below configStaleAfter; lowering configStaleAfter to it")
            stale = maxAge
        }
        self.staleAfter = stale
        self.offlineMaxAge = maxAge
        self.issues = issues
    }

    private static func describe(_ limit: TimeInterval) -> String {
        limit.isFinite ? "\(limit) s" : "no limit"
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.staleAfter == rhs.staleAfter && lhs.offlineMaxAge == rhs.offlineMaxAge
    }
}
