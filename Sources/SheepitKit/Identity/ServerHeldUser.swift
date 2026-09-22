import Foundation

/// What the SDK knows about the user the SERVER's device row holds — the user `/v1/config`
/// buckets `u:` on (`config-evaluation-context.ts`). It labels every fetched config, and
/// experiment attribution compares that label with each event's user.
///
/// It tracks the ROW, not the app's identity, so it can disagree with `ContextManager.userId`:
/// - `identify()` makes it `.unknown` at once: a POST is about to change the row, and until it
///   answers the SDK cannot say which user the row holds.
/// - A successful identify POST makes it `.known(postedUserId)`, whatever the app has identified
///   since. That is what the row holds.
/// - A failed or unanswered POST leaves it `.unknown`: the server may or may not have stored it.
/// - `reset()` on a device that may hold a user switches to a fresh device (`DeviceRotation`) and
///   makes it `.known(nil)`. On a device known to hold nobody, `reset()` leaves it alone.
/// - An identify POST answered after its device was rotated away is ignored: it describes the
///   abandoned row.
/// - Adopting a newly minted device id makes it `.known(nil)`: a new row holds no user.
///
/// Persisted with an explicit `state`, so `.unknown` survives a relaunch rather than reading back
/// as "no user".
enum ServerHeldUser: Sendable, Equatable, Codable {
    case known(String?)
    case unknown

    init(_ identity: ConfigIdentity) {
        switch identity {
        case .fetchedUnder(let userId): self = .known(userId)
        case .unknown: self = .unknown
        }
    }

    var configIdentity: ConfigIdentity {
        switch self {
        case .known(let userId): return .fetchedUnder(userId)
        case .unknown: return .unknown
        }
    }

    private enum CodingKeys: String, CodingKey {
        case state, userId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .state) {
        case "known": self = .known(try container.decodeIfPresent(String.self, forKey: .userId))
        default: self = .unknown
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .known(let userId):
            try container.encode("known", forKey: .state)
            try container.encodeIfPresent(userId, forKey: .userId)
        case .unknown:
            try container.encode("unknown", forKey: .state)
        }
    }
}
