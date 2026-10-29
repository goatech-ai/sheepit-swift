import Foundation

/// Sends feedback to `POST /v1/feedback/sdk` and retries what could not be delivered from
/// `PendingFeedbackStore`.
///
/// One POST at a time: `submit` and `drain` take the same send gate. A submission made while a
/// request is out is not parked (it would hold up to 3 MiB per caller): it is saved and `.queued`
/// returns at once, and the drain sends it after the request in flight. Only `drain()` ever waits
/// on the gate, and only one drain runs, so at most one caller waits. One attempt per call, no `HTTPClient` retry
/// ladder: a submission that fails for a retryable reason (network error or timeout, 408, 429,
/// 5xx) is saved and retried by `drain()`, one item at a time, oldest first, stopping at the first
/// retryable failure. The wait before the next drain is the server's `Retry-After` when it sent one
/// (1 s to 1 h), else `SDKDefaults.failureBackoff` (5 s doubling to 5 min); it is saved next to the
/// queue, so a relaunch inside it waits too. While it runs, a new submission is saved without a
/// request. Any other 4xx is final: the item is dropped and the caller told why. Items older than
/// `maxAge` are dropped unsent; at most `maxItems` are kept, oldest evicted first.
///
/// Every outcome emits a `transport.feedback_upload` diagnostic whose `outcome` names the branch.
actor FeedbackSender {
    static let maxItems = 10
    static let maxAge: TimeInterval = 7 * 24 * 60 * 60
    static let retryAfterFloor: TimeInterval = 1
    static let retryAfterCeiling: TimeInterval = 60 * 60

    nonisolated let store: PendingFeedbackStore
    /// `SheepitConfig.appVersion`, for the payload context (`DeviceProfile.wireAppVersion`).
    nonisolated let appVersionOverride: String?
    private let http: HTTPClient
    private let diagnostics: DiagnosticBus
    private let log: Logger
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async -> Void

    /// The retry floor. Read from disk on first use (`retryFloor()`), written on every back-off.
    private var notBefore: Date?
    private var notBeforeLoaded = false
    private var consecutiveFailures = 0
    private var draining = false
    private var scheduled: Task<Void, Never>?
    private var stopped = false
    /// The send gate: true while a POST is out. Only `drain()` waits on it (`sendWaiters`).
    private var sending = false
    private var sendWaiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameter sleep: test seam for the wait before a scheduled drain. Returns early when the
    ///   task is cancelled.
    init(
        http: HTTPClient,
        store: PendingFeedbackStore,
        diagnostics: DiagnosticBus,
        log: Logger,
        appVersionOverride: String?,
        now: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    ) {
        self.http = http
        self.store = store
        self.diagnostics = diagnostics
        self.log = log
        self.appVersionOverride = appVersionOverride
        self.now = now
        self.sleep = sleep
    }

    // MARK: - Submit

    func submit(_ submission: FeedbackSubmission) async -> SheepitFeedbackResult {
        guard !stopped else { return .rejected(.clientUnavailable) }
        let generation = store.generation
        if remainingWindow() != nil {
            return enqueue(submission, generation: generation, reason: nil)
        }
        // A request is out: save this one for the drain instead of parking the caller.
        guard !sending else {
            return enqueue(submission, generation: generation, reason: nil)
        }
        sending = true
        let outcome = await send(submission)
        releaseSend()
        switch outcome {
        case .sent(let id):
            clearBackOff()
            emit(.sent, data: ["feedback_id": AnyCodable(id)])
            if !store.entries().isEmpty { schedule(after: 0) }
            return .sent(id: id)
        case .rejected(let status, let code):
            emit(.rejected, status: status, code: code)
            return .rejected(.server(statusCode: status, code: code))
        case .retry(let retryAfter, let status):
            backOff(retryAfter: retryAfter)
            return enqueue(submission, generation: generation, reason: status)
        }
    }

    private func enqueue(_ submission: FeedbackSubmission, generation: UInt64, reason status: Int?) -> SheepitFeedbackResult {
        let (entry, evicted) = store.enqueue(submission, now: now(), ifGeneration: generation, maxItems: Self.maxItems)
        for old in evicted {
            emit(.droppedQueueFull, data: ["feedback_queue_id": AnyCodable(old.id)])
        }
        guard entry != nil else {
            // A `reset()` since this call began is not a disk failure: the feedback belongs to the
            // user who logged out, and it is dropped with their queue.
            emit(.notQueued, status: status)
            return .rejected(.queueUnavailable)
        }
        // After the write: the floor is saved only into an existing scope directory.
        if remainingWindow() != nil { store.saveNotBefore(notBefore, ifGeneration: generation) }
        emit(.queued, status: status)
        schedule(after: remainingWindow() ?? 0)
        return .queued
    }

    // MARK: - Drain

    /// Sends queued items oldest first until the queue is empty or a retryable failure stops it.
    func drain() async {
        guard !stopped, !draining else { return }
        if let wait = remainingWindow() {
            schedule(after: wait)
            return
        }
        draining = true
        defer { draining = false }
        var seen: Set<String> = []
        while !stopped, let entry = store.entries().first(where: { !seen.contains($0.id) }) {
            seen.insert(entry.id)
            let generation = store.generation
            if now().timeIntervalSince(entry.firstSeen) > Self.maxAge {
                store.remove(entry)
                emit(.droppedExpired, data: ["feedback_queue_id": AnyCodable(entry.id)])
                continue
            }
            guard let submission = store.load(entry) else {
                store.remove(entry)
                emit(.droppedUnreadable, data: ["feedback_queue_id": AnyCodable(entry.id)])
                continue
            }
            await acquireSend()
            guard !stopped else { releaseSend(); return }
            if let wait = remainingWindow() {
                // A submission sent while this drain waited for the gate was told to back off.
                releaseSend()
                draining = false
                schedule(after: wait)
                return
            }
            let outcome = await send(submission)
            releaseSend()
            // `reset()` cleared the queue while this request was out: nothing left to update.
            guard generation == store.generation, !stopped else { return }
            switch outcome {
            case .sent(let id):
                clearBackOff()
                store.remove(entry)
                emit(.sentFromQueue, data: ["feedback_id": AnyCodable(id), "feedback_queue_id": AnyCodable(entry.id)])
            case .rejected(let status, let code):
                store.remove(entry)
                emit(.droppedRejected, status: status, code: code, data: ["feedback_queue_id": AnyCodable(entry.id)])
                // Nothing left to hold back: an old 429 floor and failure count must not delay the
                // next fresh submission.
                if store.entries().isEmpty { clearBackOff() }
            case .retry(let retryAfter, let status):
                backOff(retryAfter: retryAfter)
                store.saveNotBefore(notBefore, ifGeneration: generation)
                emit(.retainedForRetry, status: status, data: ["feedback_queue_id": AnyCodable(entry.id)])
                draining = false
                schedule(after: remainingWindow() ?? 0)
                return
            }
        }
    }

    /// Stops scheduled retries (`destroy()`). Queued items stay on disk for the next client.
    func stop() {
        stopped = true
        scheduled?.cancel()
        scheduled = nil
    }

    // MARK: - Testing

    var notBeforeForTesting: Date? { retryFloor() }

    // MARK: - Private

    private func schedule(after delay: TimeInterval) {
        guard !stopped, !draining else { return }
        scheduled?.cancel()
        let sleep = self.sleep
        scheduled = Task { [weak self] in
            await sleep(delay)
            guard !Task.isCancelled else { return }
            await self?.drain()
        }
    }

    private func backOff(retryAfter: TimeInterval?) {
        consecutiveFailures += 1
        let delay = retryAfter.map { min(Self.retryAfterCeiling, max(Self.retryAfterFloor, $0)) }
            ?? SDKDefaults.failureBackoff(consecutiveFailures)
        notBeforeLoaded = true
        notBefore = now().addingTimeInterval(delay)
    }

    private func clearBackOff() {
        consecutiveFailures = 0
        if retryFloor() != nil {
            notBefore = nil
            store.saveNotBefore(nil, ifGeneration: store.generation)
        }
    }

    /// The floor, loaded from disk the first time. A saved one is never trusted further out than
    /// `retryAfterCeiling` from now, so a clock moved back cannot park the queue for longer.
    private func retryFloor() -> Date? {
        if !notBeforeLoaded {
            notBeforeLoaded = true
            notBefore = store.loadNotBefore().map { min($0, now().addingTimeInterval(Self.retryAfterCeiling)) }
        }
        return notBefore
    }

    /// Seconds until the floor, or nil when sending is allowed now.
    private func remainingWindow() -> TimeInterval? {
        guard let floor = retryFloor() else { return nil }
        let wait = floor.timeIntervalSince(now())
        return wait > 0 ? wait : nil
    }

    private func acquireSend() async {
        guard sending else {
            sending = true
            return
        }
        await withCheckedContinuation { sendWaiters.append($0) }
    }

    /// Hands the gate to the next waiter (it stays taken), or opens it.
    private func releaseSend() {
        if sendWaiters.isEmpty {
            sending = false
        } else {
            sendWaiters.removeFirst().resume()
        }
    }

    enum Outcome: Equatable {
        case sent(id: String)
        case rejected(status: Int, code: String?)
        /// `status` is nil for a network error.
        case retry(retryAfter: TimeInterval?, status: Int?)
    }

    private func send(_ submission: FeedbackSubmission) async -> Outcome {
        let (body, contentType) = MultipartFormData.encoded(submission)
        do {
            let (data, response) = try await http.postMultipartOnce(
                path: SDKEndpoints.feedbackSubmit, body: body, contentType: contentType
            )
            return Self.classify(status: response.statusCode, body: data, retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
        } catch {
            log.debug("[Feedback] Upload failed: \(error.localizedDescription)")
            return .retry(retryAfter: nil, status: nil)
        }
    }

    static func classify(status: Int, body: Data, retryAfter: String?) -> Outcome {
        switch status {
        case 200...299:
            let id = (try? JSONDecoder().decode(Created.self, from: body))?.data.id ?? ""
            return .sent(id: id)
        case 408, 429, 500...599:
            return .retry(retryAfter: HTTPClient.parseRetryAfter(retryAfter), status: status)
        default:
            return .rejected(status: status, code: (try? JSONDecoder().decode(Refused.self, from: body))?.error.code)
        }
    }

    private struct Created: Decodable {
        struct Row: Decodable { let id: String }
        let data: Row
    }

    private struct Refused: Decodable {
        struct Body: Decodable { let code: String? }
        let error: Body
    }

    private func emit(_ outcome: FeedbackUploadOutcome, status: Int? = nil, code: String? = nil, data extra: [String: AnyCodable] = [:]) {
        var data = extra
        data["outcome"] = AnyCodable(outcome.rawValue)
        if let status { data["status_code"] = AnyCodable(status) }
        if let code { data["error_code"] = AnyCodable(code) }
        diagnostics.emit(outcome.severity, .transport, code: "transport.feedback_upload", message: outcome.message, data: data)
    }
}

/// `outcome` of a `transport.feedback_upload` diagnostic.
enum FeedbackUploadOutcome: String, Sendable {
    case sent
    case sentFromQueue = "sent_from_queue"
    case rejected
    case queued
    case notQueued = "not_queued"
    case retainedForRetry = "retained_for_retry"
    case droppedRejected = "dropped_rejected"
    case droppedExpired = "dropped_expired"
    case droppedQueueFull = "dropped_queue_full"
    case droppedUnreadable = "dropped_unreadable"

    var severity: DiagnosticSeverity {
        switch self {
        case .sent, .sentFromQueue: return .info
        case .queued, .retainedForRetry: return .warn
        case .rejected, .notQueued, .droppedRejected, .droppedExpired, .droppedQueueFull, .droppedUnreadable: return .error
        }
    }

    var message: String {
        switch self {
        case .sent: return "Feedback sent"
        case .sentFromQueue: return "Queued feedback sent"
        case .rejected: return "Feedback rejected by the server; not queued"
        case .queued: return "Feedback could not be sent now; queued for retry"
        case .notQueued: return "Feedback could not be sent or queued"
        case .retainedForRetry: return "Queued feedback upload failed; kept for retry"
        case .droppedRejected: return "Queued feedback rejected by the server; dropped"
        case .droppedExpired: return "Queued feedback older than 7 days; dropped unsent"
        case .droppedQueueFull: return "Feedback queue full; oldest item dropped unsent"
        case .droppedUnreadable: return "Queued feedback could not be read; dropped"
        }
    }
}
