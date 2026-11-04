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
    }

    private let lock = NSLock()
    private var entry: Entry?

    var current: Entry? {
        lock.lock()
        defer { lock.unlock() }
        return entry
    }

    func record(_ source: SDKStatus.ConfigFreshness.Source, fetchedAt: Date) {
        lock.lock()
        defer { lock.unlock() }
        entry = Entry(source: source, fetchedAt: fetchedAt)
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

    /// What `status()` reports, measured at `now`. A clock that went backwards reads as age 0.
    func snapshot(now: Date, staleAfter: TimeInterval) -> SDKStatus.ConfigFreshness? {
        guard let entry = current else { return nil }
        let age = max(0, now.timeIntervalSince(entry.fetchedAt))
        return SDKStatus.ConfigFreshness(
            source: entry.source,
            fetchedAt: entry.fetchedAt,
            age: age,
            isStale: age > staleAfter
        )
    }
}
