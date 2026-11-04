import Foundation

extension SDKStatus {
    /// How current the applied config is. Show it ("cached, 30 h old") or attach it to your own
    /// events; `$flag_exposure` and `$experiment_exposure` already carry `config_source` and
    /// `config_age_ms`.
    public struct ConfigFreshness: Sendable, Equatable {
        public enum Source: String, Sendable, Equatable {
            /// Fetched from the server in this process.
            case server
            /// Read from the on-device cache at launch; no fetch has replaced it yet.
            case cache
        }

        public let source: Source
        /// When the server last sent this config or confirmed it unchanged (a 304).
        public let fetchedAt: Date
        /// Seconds since `fetchedAt`, when `status()` was called.
        public let age: TimeInterval
        /// `age` is past `SheepitConfig.configStaleAfter`: a fetch was due and has not landed.
        public let isStale: Bool

        public init(source: Source, fetchedAt: Date, age: TimeInterval, isStale: Bool) {
            self.source = source
            self.fetchedAt = fetchedAt
            self.age = age
            self.isStale = isStale
        }
    }
}
