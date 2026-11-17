import Foundation

/// Where the applied `/v1/config` came from and when the server last returned or confirmed it.
/// Written by `ConfigSync` and cleared by `SheepitClient.reset()`, both inside `ConfigResetGate`,
/// so it always describes the config that is actually applied. Read by `status()` and the exposure
/// events (`config_source`, `config_age_ms`).
final class ConfigFreshnessRecorder: @unchecked Sendable {
    struct Entry: Sendable, Equatable {
        let source: SDKStatus.ConfigFreshness.Source
        /// When the server last sent this body or answered 304 for it.
        let fetchedAt: Date
        /// A launch cache whose stamp was later than the device clock (clock skew): how old it is
        /// cannot be known, so it is reported stale until a fetch replaces the entry. (A launch cache
        /// holds no ETag, so no 304 can confirm it first.)
        var ageUnknown = false
        /// The server answered this device unresolved (contract § 7) and the applied body was kept:
        /// it can no longer be evaluated for this device, so it is reported stale until a body is
        /// applied again (`record`). A 304 cannot clear it either: `ConfigSync` does not confirm
        /// while the device is unresolved.
        var deviceUnresolved = false
    }

    private let lock = NSLock()
    private var entry: Entry?

    var current: Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entry
    }

    func record(_ source: SDKStatus.ConfigFreshness.Source, fetchedAt: Date, ageUnknown: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        entry = Entry(source: source, fetchedAt: fetchedAt, ageUnknown: ageUnknown)
    }

    /// An unresolved answer refused over the applied body (`Entry.deviceUnresolved`).
    func markDeviceUnresolved() {
        lock.lock()
        defer { lock.unlock() }
        entry?.deviceUnresolved = true
    }

    /// What an exposure event carries: the source and, only when the age is known, the age in ms.
    /// A launch cache stamped later than the device clock has no age to report, so it sends none
    /// rather than the 0 its clamped age reads. Saturates instead of trapping on an absurd clock.
    func exposureStamp(now: Date) -> (source: SDKStatus.ConfigFreshness.Source, ageMs: Int?)? {
        guard let entry = current else { return nil }
        guard !entry.ageUnknown else { return (entry.source, nil) }
        return (entry.source, Int(saturating: max(0, now.timeIntervalSince(entry.fetchedAt)) * 1000))
    }

    /// A 304: the server confirmed the applied body, which keeps its source.
    func confirm(at date: Date) {
        lock.lock()
        defer { lock.unlock() }
        if let entry { self.entry = Entry(source: entry.source, fetchedAt: date) }
    }

    func clear() {
        lock.lock()
        defer { lock.unlock() }
        entry = nil
    }

    /// What `status()` reports, measured at `now`. A clock that went backwards reads as age 0; an
    /// entry whose age is unknown (`Entry.ageUnknown`), or kept over an unresolved answer
    /// (`Entry.deviceUnresolved`), is stale whatever its age reads. `staleAfter` may be `.infinity`
    /// (never stale by age).
    func snapshot(now: Date, staleAfter: TimeInterval) -> SDKStatus.ConfigFreshness? {
        guard let entry = current else { return nil }
        let age = max(0, now.timeIntervalSince(entry.fetchedAt))
        return SDKStatus.ConfigFreshness(
            source: entry.source,
            fetchedAt: entry.fetchedAt,
            age: age,
            isStale: entry.ageUnknown || entry.deviceUnresolved || age > staleAfter
        )
    }
}

extension Int {
    /// `Int(value)` that saturates instead of trapping. 🔴 For every age, limit or millisecond value
    /// converted from a `TimeInterval`: watchOS runs arm64_32, where `Int` is 32-bit, so a plain
    /// `Int(age * 1000)` traps for anything older than ~24.8 days, and since 0.10.2 a cache that old
    /// is applied (and reported) inside `create(config:)`. NaN reads as 0.
    init(saturating value: Double) {
        if value.isNaN {
            self = 0
        } else if value >= Double(Int.max) {
            self = .max
        } else if value <= Double(Int.min) {
            self = .min
        } else {
            self = Int(value)
        }
    }
}
