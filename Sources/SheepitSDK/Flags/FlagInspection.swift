import Foundation

/// Where a flag's `effectiveValue` (as returned by `Sheepit.inspect`) came
/// from. Distinct from `flag(_:default:)`'s return, which only ever
/// exposes the effective value — a dev menu needs to explain the
/// precedence, not just the result.
public enum SheepitFlagValueSource: String, Sendable, CaseIterable {
    /// A local debug override is active (`Sheepit.overrideFlag`).
    case override
    /// The value came from the last-applied `/v1/config` response (live
    /// fetch or disk cache).
    case remote
    /// The server never sent this key — `effectiveValue` is the caller's
    /// `default:` argument.
    case fallback
}

/// Result of `Sheepit.inspect(_:default:)` — a non-exposing diagnostic
/// read for a debug/dev-menu flag inspector.
///
/// Once a flag is overridden, `flag(_:default:)` can no longer reach the
/// server value: the override short-circuits evaluation. A dev menu that
/// cannot show "server: off -> forced: on" is misleading, so `inspect`
/// surfaces both the remote value AND the override (when present)
/// alongside the value `flag(_:default:)` would currently return.
public struct SheepitFlagInspection: Sendable, Equatable {
    public let key: String
    /// The value from the last-applied `/v1/config`. `nil` = the server
    /// has never sent this key.
    public let remoteValue: FlagValue?
    /// The local debug override, if any. Always `nil` when overrides are
    /// disabled (`SheepitConfig.allowFlagOverrides ?? SheepitConfig.debug`
    /// is `false`).
    public let overrideValue: FlagValue?
    /// What `flag(key, default:)` returns right now.
    public let effectiveValue: FlagValue
    public let source: SheepitFlagValueSource

    /// Explicit because Swift synthesises only an INTERNAL memberwise
    /// initializer for a struct that declares none. Without it a customer
    /// cannot construct one to fixture or mock in their own tests. Same
    /// rationale as `SDKStatus`.
    public init(
        key: String,
        remoteValue: FlagValue?,
        overrideValue: FlagValue?,
        effectiveValue: FlagValue,
        source: SheepitFlagValueSource
    ) {
        self.key = key
        self.remoteValue = remoteValue
        self.overrideValue = overrideValue
        self.effectiveValue = effectiveValue
        self.source = source
    }
}
