import Foundation

/// What a launch does with the `/v1/config` body cached on the device: apply it, drop it, or
/// find nothing. Pure: reads storage, writes nothing. Called by `ConfigSync.applyLaunchCache()`,
/// inside the reset gate, which owns the apply and the delete.
///
/// The rules (founder decision 2026-11-09, SheepitKit 0.10.2):
/// - a body that cannot be decoded can never be applied, so it is dropped (`unreadable`);
/// - a missing, non-finite or non-positive stamp means the entry predates the stamp key or was
///   corrupted: dropped (`unstamped`), which costs one fetch;
/// - with no offline limit (`CachedConfigLimits.hasOfflineLimit` false, the default) the body is
///   applied whatever its age. A stamp later than the device clock (clock skew) is applied too,
///   with its age reported as unknown, so `status()` calls it stale;
/// - with a finite limit set by the host, a body older than it, or future-dated (its age cannot be
///   checked against the limit), is dropped (`pastMaxAge` / `futureDated`).
///
/// 🔴 Never consulted after a failed fetch: a failed fetch deletes nothing.
enum LaunchConfigCache {
    enum Decision {
        /// Nothing on disk.
        case none
        /// `cachedAt` is the stored stamp; `ageUnknown` when it is later than `now`.
        /// `resolvedForDevice`: the resolved stamp (`sdkConfigResolvedFor`) names the launch device,
        /// which arms C5 (contract § 7). Only a resolved 2xx writes the stamp; `reset()` removes it.
        case apply(SDKConfigResponse, cachedAt: Date, ageUnknown: Bool, resolvedForDevice: Bool)
        case drop(DropReason)
    }

    /// The diagnostic `reason` of `config.launch_cache_dropped`.
    enum DropReason: String, Sendable {
        case unreadable
        case unstamped
        case pastMaxAge = "past_max_age"
        case futureDated = "future_dated"
        /// Over `SDKDefaults.configCacheMaxBytes`: not decoded on the launch thread.
        case oversize
    }

    /// - Parameter deviceId: the device the launch starts on, compared with the resolved stamp.
    static func evaluate(storage: StorageProvider, limits: CachedConfigLimits, now: Date, deviceId: String) -> Decision {
        guard let data = storage.data(forKey: StorageKeys.sdkConfig) else { return .none }
        guard data.count <= SDKDefaults.configCacheMaxBytes else { return .drop(.oversize) }
        guard let cached = try? JSONDecoder().decode(ApiDataResponse<SDKConfigResponse>.self, from: data) else {
            return .drop(.unreadable)
        }
        // Stored as a String: `StorageProvider` vends String and Data only. `Double("inf")` and
        // `Double("1e999")` both parse to +infinity, which would read as a stamp in the far future.
        let cachedAt = storage.string(forKey: StorageKeys.sdkConfigCachedAt).flatMap(Double.init) ?? 0
        guard cachedAt.isFinite, cachedAt > 0 else { return .drop(.unstamped) }
        let nowSeconds = now.timeIntervalSince1970
        let futureDated = cachedAt > nowSeconds
        if limits.hasOfflineLimit {
            if futureDated { return .drop(.futureDated) }
            if nowSeconds - cachedAt > limits.offlineMaxAge { return .drop(.pastMaxAge) }
        }
        // An absent stamp (a header-less body, or a cache written before the key) or another
        // device's: not armed, so an erased device is not detected from that cache (fail closed).
        let resolvedForDevice = storage.string(forKey: StorageKeys.sdkConfigResolvedFor) == deviceId
        return .apply(cached.data, cachedAt: Date(timeIntervalSince1970: cachedAt), ageUnknown: futureDated,
                      resolvedForDevice: resolvedForDevice)
    }
}
