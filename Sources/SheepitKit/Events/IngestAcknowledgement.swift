import Foundation

/// What a 2xx from `/v1/ingest` says about the events that were sent
/// (PILOT_CORRECTNESS_DESIGN.md §2.2, "HTTP success means durably accepted").
///
/// 🔴 A 2xx acknowledges EVERY sent event, whatever this finds. Each rejection reason the
/// route produces (32 KB, invalid context, duplicate id, outside the storable window, schema)
/// is permanent, and re-sending an event the server did not store — matched or not — would
/// duplicate it on an API that predates per-event `event_id` dedup (S2). So this type decides
/// only what the host is TOLD; it never puts anything back on a queue.
struct IngestAcknowledgement: Equatable {
    struct Rejection: Equatable {
        let index: Int
        let event: String
        let eventId: String
        let reason: String
    }

    /// Bounds on what one request may put into the diagnostics ring buffer.
    static let maxReportedRejections = 10
    static let maxReasonLength = 200

    let sent: Int
    /// `nil` when the body did not decode as an `IngestResponse` (an intermediary's 200, a
    /// future shape). The request is still acknowledged.
    let accepted: Int?
    /// Rejections that name a sent event by index, agree on its name and, when the server
    /// echoed one, on its `event_id`.
    let rejected: [Rejection]
    /// Rejections that could not be pinned to a sent event: an index out of range or repeated,
    /// or a name/`event_id` that disagrees with the event at that index.
    let unmatched: Int

    var decoded: Bool { accepted != nil }

    /// Whether `accepted` and the rejections add up to what was sent. A mismatch means the
    /// body describes some other request, or a server that dropped events without saying so.
    var countsAgree: Bool {
        guard let accepted else { return true }
        return unmatched == 0 && accepted + rejected.count == sent
    }

    static func reconcile(sent events: [EnrichedEvent], body: Data) -> IngestAcknowledgement {
        guard let response = try? JSONDecoder().decode(ApiDataResponse<IngestResponse>.self, from: body).data
        else {
            return IngestAcknowledgement(sent: events.count, accepted: nil, rejected: [], unmatched: 0)
        }
        var rejected: [Rejection] = []
        var unmatched = 0
        var claimed = Set<Int>()
        for rejection in response.rejected ?? [] {
            // `index` is authoritative: an API before #995 never echoes `event_id`.
            guard events.indices.contains(rejection.index), claimed.insert(rejection.index).inserted else {
                unmatched += 1
                continue
            }
            let event = events[rejection.index]
            // Swift mints UPPERCASE UUIDs; the server's uuid check is case-insensitive.
            let idAgrees = rejection.eventId.map {
                $0.caseInsensitiveCompare(event.eventId) == .orderedSame
            } ?? true
            guard idAgrees, rejection.event == event.eventName else {
                unmatched += 1
                continue
            }
            rejected.append(Rejection(
                index: rejection.index,
                event: event.eventName,
                eventId: event.eventId,
                reason: rejection.reason
            ))
        }
        return IngestAcknowledgement(
            sent: events.count,
            accepted: response.accepted,
            rejected: rejected,
            unmatched: unmatched
        )
    }

    /// At most `maxReportedRejections` entries, each reason cut to `maxReasonLength`. Plain
    /// `[String: Any]` values so `AnyCodable` can encode them.
    var reportedRejections: [[String: Any]] {
        rejected.prefix(Self.maxReportedRejections).map {
            [
                "index": $0.index,
                "event": String($0.event.prefix(Self.maxReasonLength)),
                "event_id": $0.eventId,
                "reason": String($0.reason.prefix(Self.maxReasonLength)),
            ]
        }
    }
}
