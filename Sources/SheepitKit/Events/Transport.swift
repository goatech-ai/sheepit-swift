import Foundation

/// Handles flushing events to the /v1/ingest endpoint.
/// Started as a mirror of packages/sdk-js/src/transport.ts; since S3c it diverges on retry
/// classes, response handling and request sizing (see `flush()` and `handleFlushFailure`).
actor Transport {
    private let http: HTTPClient
    private let queue: EventQueue
    private let offlineQueue: OfflineQueue
    private let connectivity: ConnectivityMonitor
    private let log: Logger
    private let diagnostics: DiagnosticBus?
    /// Mirrors `lastFlushAt` outside the actor so `SheepitClient.status()` can
    /// stay synchronous.
    private let lastFlushClock: LastFlushClock?
    private(set) var lastFlushAt: Date?
    /// No request is sent before this: `Retry-After` after a 429, or an exponential back-off
    /// after a 5xx / network failure (`SDKDefaults.failureBackoff`). Without the second, every
    /// flush re-sent the whole persisted backlog into an outage, each request retried by
    /// `HTTPClient` on top.
    private var backoffUntil: Date?
    /// Retryable failures since the last 2xx; sizes the back-off.
    private var consecutiveFailures = 0
    private let now: @Sendable () -> Date

    enum SendOutcome: Equatable {
        case delivered
        /// Permanently refused; the events are gone.
        case dropped
        /// Persisted for a later flush; stop sending for now.
        case retryLater
    }

    init(
        http: HTTPClient,
        queue: EventQueue,
        offlineQueue: OfflineQueue,
        connectivity: ConnectivityMonitor,
        log: Logger,
        diagnostics: DiagnosticBus? = nil,
        lastFlushClock: LastFlushClock? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.now = now
        self.http = http
        self.queue = queue
        self.offlineQueue = offlineQueue
        self.connectivity = connectivity
        self.log = log
        self.diagnostics = diagnostics
        self.lastFlushClock = lastFlushClock
    }

    /// The flush in progress. `flush()` suspends at every request, and without this two flushes
    /// interleave: both would send the same peeked backlog, each would size its live drain against
    /// a queue the other is changing, and neither would see the other's back-off until its own
    /// request failed.
    private var inFlight: Task<Void, Never>?

    /// Serialized: a call made while another flush runs waits for it, then runs its own pass.
    func flush() async {
        while let running = inFlight {
            await running.value
            // Cleared here as well as by its owner: awaiting a finished task does not suspend,
            // so waiting for the owner to resume could spin.
            if inFlight == running { inFlight = nil }
        }
        let pass = Task { await self.runFlush() }
        inFlight = pass
        await pass.value
        if inFlight == pass { inFlight = nil }
    }

    private func runFlush() async {
        if let until = backoffUntil {
            guard now() >= until else {
                // Nothing is sent inside a back-off, but what was tracked meanwhile goes to disk,
                // or a background flush or `destroy()` during a 5xx back-off would leave it only
                // in memory.
                persistLiveQueue()
                return
            }
            backoffUntil = nil
        }

        guard connectivity.isOnline else {
            let events = persistLiveQueue()
            guard !events.isEmpty else { return }
            diagnostics?.emit(
                .debug,
                .transport,
                code: "transport.offline_queued",
                message: "Offline — queued \(events.count) events",
                data: ["count": AnyCodable(events.count)]
            )
            return
        }

        // Oldest first: the offline queue holds what an earlier attempt could not deliver
        // (5xx, network loss, 429), possibly written by a previous process. Every item keeps the
        // id and timestamp it was tracked with.
        //
        // 🔴 PEEKED, not drained. Persisted events stay on disk until their own request is
        // answered, then are removed by event id. Draining wrote the queue empty before the first
        // request, so a process killed mid-flush lost every persisted event it had taken. This is
        // at-least-once: a kill after the server stored a request but before its removal resends
        // it, and the server dedups on `event_id` (founder decision, 2026-09-13).
        //
        // 🔴 The live queue contributes only what the offline queue has room for. A retryable
        // failure writes this flush's live events behind the backlog, and the offline queue trims
        // at `capacity`. What is left behind stays in memory for the next flush.
        let backlog = offlineQueue.peek()
        let persisted = Set(backlog.map(\.eventId))
        let events = backlog + queue.drain(upTo: offlineQueue.capacity - backlog.count)
        guard !events.isEmpty else { return }

        let requests = Transport.groupedBySession(events).flatMap { IngestChunking.chunks($0) }
        for (position, request) in requests.enumerated() {
            guard await send(request) == .retryLater else {
                // Answered — delivered or permanently refused — so its persisted events leave disk.
                offlineQueue.remove(eventIds: Set(request.map(\.eventId)).intersection(persisted))
                continue
            }
            // A retryable failure ends the flush: the rest would meet the same outage or rate
            // limit. Persisted events are still on disk; only this flush's live events (from the
            // failed request and the untried ones) are written, behind them, so FIFO order holds.
            let unsent = requests[position...].flatMap { $0 }.filter { !persisted.contains($0.eventId) }
            if !unsent.isEmpty { offlineQueue.enqueue(unsent) }
            break
        }
    }

    /// Split into runs of consecutive events sharing one session id, preserving order.
    ///
    /// Load-bearing until S3c, when requests still carried a batch-level context taken from
    /// the first event: an API without per-event context (#995) filed a two-session batch's
    /// tail under the head's session. Requests no longer carry one, so this now only keeps
    /// each request single-session; removing it is a separate, structural change.
    static func groupedBySession(_ events: [EnrichedEvent]) -> [[EnrichedEvent]] {
        var groups: [[EnrichedEvent]] = []
        for event in events {
            if var last = groups.last, last.first?.sessionId == event.sessionId {
                last.append(event)
                groups[groups.count - 1] = last
            } else {
                groups.append([event])
            }
        }
        return groups
    }

    private func send(_ events: [EnrichedEvent]) async -> SendOutcome {
        let body: Data
        do {
            body = try await http.postRaw(path: SDKEndpoints.ingest, body: Self.buildPayload(events))
        } catch {
            return handleFlushFailure(error, events: events)
        }
        consecutiveFailures = 0
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
        report(IngestAcknowledgement.reconcile(sent: events, body: body))
        return .delivered
    }

    /// Tell the host what a 2xx did not store. Nothing here re-queues: a 2xx acknowledges
    /// every event in the request (see `IngestAcknowledgement`).
    private func report(_ ack: IngestAcknowledgement) {
        if !ack.rejected.isEmpty {
            log.error("Ingest rejected \(ack.rejected.count) of \(ack.sent) events; they will not be retried")
            diagnostics?.emit(
                .error,
                .transport,
                code: "transport.events_rejected",
                message: "Ingest rejected \(ack.rejected.count) of \(ack.sent) events — not retried",
                data: [
                    "count": AnyCodable(ack.rejected.count),
                    "sent": AnyCodable(ack.sent),
                    "rejections": AnyCodable(ack.reportedRejections),
                    "unreported": AnyCodable(max(0, ack.rejected.count - IngestAcknowledgement.maxReportedRejections)),
                ]
            )
        }
        if !ack.decoded {
            log.warn("Ingest returned success with an unreadable body; treating \(ack.sent) events as delivered")
            diagnostics?.emit(
                .warn,
                .transport,
                code: "transport.ingest_response_undecodable",
                message: "Ingest succeeded but its response could not be read — \(ack.sent) events treated as delivered",
                data: ["sent": AnyCodable(ack.sent)]
            )
        } else if !ack.countsAgree {
            log.error("Ingest response does not account for the \(ack.sent) events sent")
            diagnostics?.emit(
                .error,
                .transport,
                code: "transport.rejection_unmatched",
                message: "Ingest response does not match the request — some rejected events cannot be identified",
                data: [
                    "sent": AnyCodable(ack.sent),
                    "accepted": AnyCodable(ack.accepted ?? 0),
                    "rejected_matched": AnyCodable(ack.rejected.count),
                    "rejected_unmatched": AnyCodable(ack.unmatched),
                ]
            )
        }
    }

    /// Route a failed request by error class (PILOT_CORRECTNESS_DESIGN.md §2.2: "429 honors
    /// Retry-After, 5xx/network retry, invalid schema is permanent and visible").
    ///
    ///   - 4xx except 429 → DROP, with an error diagnostic. The server will never accept it:
    ///     400 malformed, 401 revoked key, 413 oversized. `IngestChunking` keeps well-formed
    ///     flushes under the count and size limits, so a 400/413 here is a real defect.
    ///   - 429            → kept for retry (`flush()` persists it), and no request until
    ///                      `Retry-After` has passed.
    ///   - 5xx / network  → kept for retry, and no request until `SDKDefaults.failureBackoff`
    ///                      has passed. The whole request is ambiguous, so it is resent with
    ///                      the same event ids and timestamps and dedups server-side.
    ///   - encode failure → DROP. A non-finite `Double` property (NaN/±Infinity) can never be
    ///                      JSON; retrying it would loop forever. `IngestChunking` isolates
    ///                      such an event in its own request, so only it is lost.
    ///
    /// JS differs: it special-cases exactly 400 (any other 4xx reports success) and keeps 429s
    /// in memory. Swift persists 429s because process death during a back-off otherwise loses
    /// them (founder decision, S3c); aligning JS is a separate change.
    private func handleFlushFailure(_ error: Error, events: [EnrichedEvent]) -> SendOutcome {
        switch error {
        case is EncodingError:
            log.error("Ingest payload could not be encoded: dropping \(events.count) events")
            diagnostics?.emit(
                .error,
                .transport,
                code: "transport.event_unencodable",
                message: "Dropped \(events.count) events that cannot be encoded as JSON (non-finite number?)",
                data: [
                    "count": AnyCodable(events.count),
                    "events": AnyCodable(events.prefix(IngestAcknowledgement.maxReportedRejections).map(\.eventName)),
                ]
            )
            return .dropped

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
            return .dropped

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
            return .dropped

        case SDKError.rateLimited(let retryAfter):
            let backoff = retryAfter ?? SDKDefaults.defaultRetryAfter
            log.warn("Rate limited — keeping \(events.count) events for retry, backing off \(Int(backoff))s")
            extendBackoff(by: backoff)
            diagnostics?.emit(
                .warn,
                .transport,
                code: "transport.rate_limited",
                message: "Rate limited — \(events.count) events kept for retry",
                data: [
                    "count": AnyCodable(events.count),
                    "retry_after_seconds": AnyCodable(backoff),
                ]
            )
            return .retryLater

        default:
            consecutiveFailures += 1
            let backoff = SDKDefaults.failureBackoff(consecutiveFailures)
            log.warn("Flush failed: \(error.localizedDescription) — backing off \(Int(backoff))s")
            extendBackoff(by: backoff)
            diagnostics?.emit(
                .warn,
                .transport,
                code: "transport.flush_failed",
                message: "Flush failed — \(events.count) events kept for retry",
                data: [
                    "count": AnyCodable(events.count),
                    "error": AnyCodable(error.localizedDescription),
                    "retry_after_seconds": AnyCodable(backoff),
                ]
            )
            return .retryLater
        }
    }

    /// Move live events to disk, only as many as the offline queue has room for. The live queue
    /// holds up to 1000 and the offline queue trims at 500, so moving everything would trim the
    /// oldest persisted events to make room; the remainder stays in memory for the next pass.
    @discardableResult
    private func persistLiveQueue() -> [EnrichedEvent] {
        let events = queue.drain(upTo: offlineQueue.capacity - offlineQueue.size())
        if !events.isEmpty { offlineQueue.enqueue(events) }
        return events
    }

    /// Never shortens a wait already in force: a 429's `Retry-After` must survive a later
    /// 5xx back-off, and a short `Retry-After` must not cut an outage back-off.
    private func extendBackoff(by seconds: TimeInterval) {
        let until = now().addingTimeInterval(seconds)
        backoffUntil = max(backoffUntil ?? until, until)
    }

    /// Build the ingest API payload. Every event carries its own `event_id` and its own
    /// complete `context` (PILOT_CORRECTNESS_DESIGN.md §2.1–2.2).
    ///
    /// 🔴 No batch-level `context` (founder decision, S3c). It existed only for an API that
    /// predates per-event context (#995); on such an API these events now arrive with no
    /// user, device, session or app. That is why `swift-v*` is held until every install runs
    /// an API that includes #995.
    static func buildPayload(_ events: [EnrichedEvent], sentAt: Date = Date()) -> IngestRequest {
        IngestRequest(
            batch: events.map(wireEvent),
            context: nil,
            sentAt: ISO8601DateFormatter().string(from: sentAt)
        )
    }

    /// One element of `batch`. Shared with `IngestChunking.encodedSize` so the size budget
    /// measures exactly what is sent.
    static func wireEvent(_ event: EnrichedEvent) -> IngestEvent {
        IngestEvent(
            type: "track",
            event: event.eventName,
            properties: event.eventProperties,
            timestamp: event.timestamp,
            eventId: event.eventId,
            context: context(for: event)
        )
    }

    /// `ingestContextSchema.user.id` is `max(256)` UTF-16 units. `identify()` refuses a longer
    /// id, but a queue written by an earlier SDK can still hold one. Truncating would merge
    /// distinct users, so the event goes out anonymous instead of being rejected.
    static func storableUserId(_ userId: String?) -> String? {
        guard let userId, userId.utf16.count <= SDKDefaults.userIdMaxLength else { return nil }
        return userId
    }

    /// One event's complete context, built ONLY from that event's own fields.
    ///
    /// 🔴 Nothing here may read `Bundle`, `DeviceProfile`, `Locale` or any other live
    /// state. The server REPLACES the batch context with this one — it does not merge — so
    /// whatever is left out stays null, and that is the correct answer for an event queued
    /// by an SDK that never recorded it (`snapshot == nil`). Filling it from the process
    /// that happens to be flushing would attribute the event to an app version, OS or
    /// country it was never tracked under.
    static func context(for event: EnrichedEvent) -> IngestContext {
        let snapshot = event.snapshot
        return IngestContext(
            app: snapshot.map {
                // Re-bounded although `TrackSnapshot.capture` bounds them: a queue written
                // before that bound existed can hold a longer value, and one over-long
                // `app.version` costs the event (`ingestContextSchema.app`, max 64/64/256).
                IngestApp(
                    version: $0.appVersion.map { DeviceProfile.bounded($0, SDKDefaults.appVersionMaxLength) },
                    build: $0.appBuild.map { DeviceProfile.bounded($0, SDKDefaults.appVersionMaxLength) },
                    namespace: $0.appNamespace.map { DeviceProfile.bounded($0, 256) },
                    buildChannel: $0.buildChannel
                )
            },
            // Bounded to 32/64 chars by ingestContextSchema.sdk.{name,version} — both
            // SDKDefaults.sdkName and event.sdkVersion are well under that (see their
            // own doc comments), so no truncation is needed here. The NAME is the one
            // value not taken from the event: it is this package's compile-time
            // constant, and every queued event was produced by this package.
            sdk: IngestSDK(name: SDKDefaults.sdkName, version: event.sdkVersion),
            user: IngestUser(id: storableUserId(event.userId), anonymousId: event.anonymousId),
            device: IngestDevice(
                id: event.deviceId,
                platform: event.platform,
                model: snapshot?.deviceModel,
                osVersion: snapshot?.osVersion,
                osName: snapshot?.osName,
                timezone: event.timezone,
                // 🔴 `locale` is the raw `Locale.current.identifier`, which carries
                // Unicode extensions when the user picks a non-Gregorian calendar:
                // "en_US@calendar=japanese" is 23 chars against
                // `ingestContextSchema.device.locale`'s max(16) — measured, rejected.
                // `track()` now bounds it at capture; bounding again here covers events
                // queued by an SDK that persisted the raw identifier. It truncates the
                // event's OWN value, so it is not a fill from live state.
                locale: DeviceProfile.bounded(event.locale, 16),
                // Re-applied here although `TrackSnapshot.capture` already filters it, for
                // the same reason `locale` is re-bounded above: `country` is
                // `.length(2)`, a UN M.49 area ("419", es-419 devices) fails it, and one
                // failure costs the event. The capture filter alone was the only guard, so
                // a regression there would have shipped silently.
                country: TrackSnapshot.countryCode(snapshot?.country),
                type: snapshot?.deviceType
            ),
            session: IngestSession(id: event.sessionId),
            flags: nil,
            experiments: wireExperiments(event.assignments),
            experimentAssignments: wireExperimentAssignments(event.assignments),
            account: nil,
            revenue: nil,
            releaseId: nil
        )
    }

    /// `context.experiments`: experiment key → variant key, from the event's OWN track-time
    /// assignments only.
    ///
    /// 🔴 `identity_changed` entries are left out. This map is persisted as `active_experiments`,
    /// which the legacy readout (`compute-experiment-results.ts`) counts with no status column, so
    /// sending one would credit the new user to the previous user's arm. Leaving the key absent is
    /// consistent with `experiment_assignments`: the server compares variants only where both
    /// maps carry the key.
    static func wireExperiments(_ assignments: [String: EventAssignment]?) -> [String: AnyCodable]? {
        guard let assignments else { return nil }
        var variants: [String: AnyCodable] = [:]
        for (key, assignment) in assignments where assignment.subjectStatus != EventAssignment.identityChanged {
            guard let variantKey = assignment.variantKey else { continue }
            variants[key] = AnyCodable(variantKey)
        }
        return variants.isEmpty ? nil : variants
    }

    /// `context.experiment_assignments`: only entries carrying ALL the metadata. An entry from a
    /// config cached before `/v1/config` vended it is omitted, which leaves that experiment
    /// unattributed on this event rather than guessed.
    ///
    /// No subject value is ever sent: the server resolves it from this event's own user or device.
    /// Nothing is truncated to fit a bound. An event over the server's per-event size or entry
    /// limit is rejected visibly (`transport.events_rejected`), as the design requires.
    static func wireExperimentAssignments(
        _ assignments: [String: EventAssignment]?
    ) -> [String: IngestExperimentAssignment]? {
        guard let assignments else { return nil }
        var complete: [String: IngestExperimentAssignment] = [:]
        for (key, assignment) in assignments {
            guard let experimentId = assignment.experimentId,
                  let variantKey = assignment.variantKey,
                  let subjectKind = assignment.subjectKind,
                  // The API accepts exactly these two; any other kind costs the whole event.
                  subjectKind == "user" || subjectKind == "device",
                  let bucketingVersion = assignment.bucketingVersion,
                  let assignmentRevision = assignment.assignmentRevision
            else { continue }
            complete[key] = IngestExperimentAssignment(
                experimentId: experimentId,
                variantKey: variantKey,
                subjectKind: subjectKind,
                // The only status a client may send; the API rejects the whole event for any
                // other, so nothing else read back from disk is passed through.
                subjectStatus: assignment.subjectStatus == EventAssignment.identityChanged
                    ? EventAssignment.identityChanged
                    : nil,
                bucketingVersion: bucketingVersion,
                assignmentRevision: assignmentRevision
            )
        }
        return complete.isEmpty ? nil : complete
    }
}
