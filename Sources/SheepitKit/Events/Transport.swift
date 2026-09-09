import Foundation

/// Handles flushing events to the /v1/ingest endpoint.
/// Mirrors packages/sdk-js/src/transport.ts
actor Transport {
    private let http: HTTPClient
    private let queue: EventQueue
    private let offlineQueue: OfflineQueue
    private let connectivity: ConnectivityMonitor
    private let log: Logger
    /// Audit L-005 / X2-001 — explicit app version from SheepitConfig.
    /// Stamped on every batch as `context.app.version` so the ingest
    /// release-resolver attributes events to a Release row. nil → falls
    /// back to Bundle.main.CFBundleShortVersionString below.
    private let appVersion: String?
    private let diagnostics: DiagnosticBus?
    /// Mirrors `lastFlushAt` outside the actor so `SheepitClient.status()` can
    /// stay synchronous.
    private let lastFlushClock: LastFlushClock?
    private(set) var lastFlushAt: Date?
    /// Set when the server returns 429. `flush()` is a no-op until it
    /// passes so a rate-limited client stops hammering the endpoint.
    private var rateLimitedUntil: Date?

    init(
        http: HTTPClient,
        queue: EventQueue,
        offlineQueue: OfflineQueue,
        connectivity: ConnectivityMonitor,
        log: Logger,
        appVersion: String? = nil,
        diagnostics: DiagnosticBus? = nil,
        lastFlushClock: LastFlushClock? = nil
    ) {
        self.http = http
        self.queue = queue
        self.offlineQueue = offlineQueue
        self.connectivity = connectivity
        self.log = log
        self.appVersion = appVersion
        self.diagnostics = diagnostics
        self.lastFlushClock = lastFlushClock
    }

    func flush() async {
        if let until = rateLimitedUntil {
            guard Date() >= until else { return }
            rateLimitedUntil = nil
        }

        let events = queue.drain()
        guard !events.isEmpty else { return }

        if !connectivity.isOnline {
            offlineQueue.enqueue(events)
            diagnostics?.emit(
                .debug,
                .transport,
                code: "transport.offline_queued",
                message: "Offline — queued \(events.count) events",
                data: ["count": AnyCodable(events.count)]
            )
            return
        }

        do {
            let payload = buildPayload(events)
            _ = try await http.postRaw(path: SDKEndpoints.ingest, body: payload)
            let flushedAt = Date()
            lastFlushAt = flushedAt
            lastFlushClock?.mark(flushedAt)
            log.debug("Flushed \(events.count) events")
            diagnostics?.emit(
                .debug,
                .transport,
                code: "transport.flush_succeeded",
                message: "Flushed \(events.count) events",
                data: ["count": AnyCodable(events.count)]
            )
        } catch {
            handleFlushFailure(error, events: events)
        }
    }

    /// Route a failed flush by error class.
    ///
    /// This GENERALISES `packages/sdk-js/src/transport.ts:120-135` rather
    /// than mirroring it: the JS SDK special-cases exactly 400, so any
    /// other 4xx (401 from a revoked key, 413 from an oversized batch)
    /// falls through to `return true` and is reported as a successful
    /// flush. Dropping the whole non-429 4xx class is the deliberate
    /// choice here; aligning JS to match is a separate change.
    ///
    /// The previous behaviour — every failure into the offline queue —
    /// meant a permanently-rejected batch (HTTP 400 from a malformed
    /// payload, 401 from a revoked key, 413 from an oversized batch) was
    /// re-sent on every drain forever, a poison loop that also blocked
    /// the good events behind it.
    ///
    ///   - 4xx except 429 → DROP. The server will never accept it.
    ///   - 429           → re-queue for the next flush cycle, honouring
    ///                     `Retry-After` before that cycle runs.
    ///   - 5xx / network → offline queue. Retryable.
    ///
    /// The 429 path is BOUNDED-loss, not lossless, and deliberately so
    /// (it matches `sdk-js`, which also re-queues in memory):
    ///
    ///   - Re-queued events go back into the in-memory `EventQueue`, so a
    ///     host calling `track()` faster than `maxQueueSize` per back-off
    ///     window evicts the oldest. That eviction is reported as
    ///     `queue.overflow_evicted` rather than being silent.
    ///   - Unlike the 5xx path, they are NOT persisted, so process death
    ///     during a back-off loses them.
    ///
    /// Persisting 429s to the disk-backed offline queue would close both
    /// gaps but diverge from the JS SDK; that is a cross-platform decision,
    /// not a Swift-side one.
    private func handleFlushFailure(_ error: Error, events: [EnrichedEvent]) {
        switch error {
        case SDKError.badRequest(let message):
            log.error("Ingest 400: dropping \(events.count) events. \(message)")
            diagnostics?.emit(
                .error,
                .transport,
                code: "transport.batch_dropped",
                message: "Ingest rejected the batch (400) — dropped \(events.count) events",
                data: [
                    "count": AnyCodable(events.count),
                    "status_code": AnyCodable(400),
                    "detail": AnyCodable(String(message.prefix(500))),
                ]
            )

        case SDKError.httpError(let status) where (400..<500).contains(status):
            log.error("Ingest \(status): dropping \(events.count) events.")
            diagnostics?.emit(
                .error,
                .transport,
                code: "transport.batch_dropped",
                message: "Ingest rejected the batch (\(status)) — dropped \(events.count) events",
                data: [
                    "count": AnyCodable(events.count),
                    "status_code": AnyCodable(status),
                ]
            )

        case SDKError.rateLimited(let retryAfter):
            let backoff = retryAfter ?? SDKDefaults.defaultRetryAfter
            log.warn("Rate limited — re-queuing \(events.count) events, backing off \(Int(backoff))s")
            requeue(events)
            rateLimitedUntil = Date().addingTimeInterval(backoff)
            diagnostics?.emit(
                .warn,
                .transport,
                code: "transport.rate_limited",
                message: "Rate limited — re-queued \(events.count) events",
                data: [
                    "count": AnyCodable(events.count),
                    "retry_after_seconds": AnyCodable(backoff),
                ]
            )

        default:
            // 5xx, network failure, invalid response — retryable, so keep
            // the events across process restarts.
            log.warn("Flush failed: \(error.localizedDescription)")
            offlineQueue.enqueue(events)
            diagnostics?.emit(
                .warn,
                .transport,
                code: "transport.flush_failed",
                message: "Flush failed — moved \(events.count) events to the offline queue",
                data: [
                    "count": AnyCodable(events.count),
                    "error": AnyCodable(error.localizedDescription),
                ]
            )
        }
    }

    /// Put events back on the in-memory queue for the next flush cycle.
    /// Matches `packages/sdk-js/src/transport.ts:140` — `EventQueue` is
    /// bounded and evicts oldest-first when full, so a sustained rate
    /// limit degrades by dropping the stalest events rather than growing
    /// without bound.
    private func requeue(_ events: [EnrichedEvent]) {
        for event in events { queue.add(event) }
    }

    /// Build the ingest API payload from enriched events.
    /// Matches the format in packages/sdk-js/src/transport.ts buildBody()
    private func buildPayload(_ events: [EnrichedEvent]) -> IngestRequest {
        let first = events[0]
        return IngestRequest(
            batch: events.map { event in
                IngestEvent(
                    type: "track",
                    event: event.eventName,
                    properties: event.eventProperties,
                    timestamp: event.timestamp
                )
            },
            context: IngestContext(
                app: IngestApp(
                    // L-005: prefer the host-provided appVersion (commit
                    // SHA / build tag) over CFBundleShortVersionString
                    // so events resolve to a Release row.
                    version: appVersion
                        ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String),
                    build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
                    namespace: Bundle.main.bundleIdentifier
                ),
                user: IngestUser(
                    id: first.userId,
                    anonymousId: first.anonymousId
                ),
                device: IngestDevice(
                    id: first.deviceId,
                    platform: first.platform,
                    model: nil,
                    osVersion: nil,
                    locale: first.locale,
                    country: Locale.current.region?.identifier
                ),
                session: IngestSession(id: first.sessionId),
                flags: nil,
                experiments: nil,
                account: nil,
                revenue: nil,
                releaseId: nil
            ),
            sentAt: ISO8601DateFormatter().string(from: Date())
        )
    }
}
