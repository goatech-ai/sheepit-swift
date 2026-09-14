import Foundation

/// Splits one flush into requests `/v1/ingest` will accept (PILOT_CORRECTNESS_DESIGN.md §2.1).
///
/// Two limits, both enforced server-side on the WHOLE request, so exceeding either loses
/// every event in it rather than one:
///   - `ingestBatchSchema.batch.max(100)` → 400, which `Transport` drops as permanent.
///   - Fastify's `bodyLimit: 1_048_576` on the route → 413, also dropped. This SDK does not
///     gzip, so the limit applies to the JSON as encoded.
///
/// A group only ever exceeded 100 by accident — a 429 back-off or a 500-event offline drain
/// landing in one flush — which is exactly when the events are the oldest and least
/// replaceable.
enum IngestChunking {
    static let maxEventsPerRequest = 100
    /// Summed encoded size of the events in one request. Leaves ~140 KB of the 1 MiB body
    /// limit for the envelope (`batch`, `sent_at`, separators), which is a few dozen bytes.
    static let maxRequestBytes = 900_000

    /// Order-preserving. An event larger than `maxRequestBytes` on its own still gets a
    /// request of its own: the server then rejects exactly that one (32 KB per-event limit)
    /// instead of taking its neighbours down with it.
    static func chunks(
        _ events: [EnrichedEvent],
        encodedSize: (EnrichedEvent) -> Int = IngestChunking.encodedSize
    ) -> [[EnrichedEvent]] {
        var result: [[EnrichedEvent]] = []
        var current: [EnrichedEvent] = []
        var bytes = 0
        for event in events {
            let size = encodedSize(event) + 1 // the separating comma
            if !current.isEmpty, current.count == maxEventsPerRequest || bytes + size > maxRequestBytes {
                result.append(current)
                current = []
                bytes = 0
            }
            current.append(event)
            bytes += size
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// The bytes this event contributes to `Transport.buildPayload`'s `batch` array, measured
    /// with the same encoder `HTTPClient` uses. An event that cannot be encoded counts as the
    /// whole budget, isolating it in its own request.
    static func encodedSize(_ event: EnrichedEvent) -> Int {
        (try? JSONEncoder().encode(Transport.wireEvent(event)).count) ?? maxRequestBytes
    }
}
