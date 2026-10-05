import Foundation

/// Retry-delay policy for a `cap` (402/422) or `rateLimited` (429) registration outcome —
/// fix round 1 (PR #1170 review), items 15/17. Shared by `DeviceRotation`'s retry loop and
/// `SheepitClient`'s launch-path retry loop so the two never drift.
///
/// Deliberately SEPARATE from `DeviceRotation.retryDelay(afterFailures:)`, which stays a
/// plain 1s-doubling-to-60s ceiling with NO jitter for `transientFailure` (network/5xx) —
/// unchanged by this PR. A `cap`/`rateLimited` outcome means the SERVER is explicitly saying
/// "not now" for a reason retrying sooner cannot fix, so it backs off up to an HOUR instead,
/// with full jitter (AWS Builders' Library: `random_between(0, min(cap, base * 2^attempt))`)
/// so every client capped/limited at the same moment doesn't retry in lockstep.
enum RegistrationRetryPolicy {
    static let baseSeconds: TimeInterval = 1
    static let ceilingSeconds: TimeInterval = 60 * 60

    /// `retryAfter` (429 only — `nil` for a 402/422 cap) dominates the jittered exponential
    /// value when it asks for longer, floored at 1s, capped at an hour so a malformed or
    /// deliberately huge header can't wedge registration indefinitely.
    static func delay(afterFailures failures: Int, retryAfter: TimeInterval?) -> Duration {
        let exponentialCeiling = min(ceilingSeconds, baseSeconds * pow(2, Double(failures)))
        let jittered = Double.random(in: 0..<max(exponentialCeiling, 0.001))
        let retryAfterSeconds = max(0, retryAfter ?? 0)
        let seconds = min(max(1, jittered, retryAfterSeconds), ceilingSeconds)
        return .seconds(seconds)
    }
}
