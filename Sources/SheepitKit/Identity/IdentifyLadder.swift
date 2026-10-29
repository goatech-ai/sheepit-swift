import Foundation

/// The retry ladder behind an identify POST (`POST /v1/devices/:id/identify`). Web counterpart:
/// `packages/sdk-js/src/identify-ladder.ts` (R7 fix plan A3; this is A3s).
///
/// Before this, a 404 was a final `.rejected` and the user stayed unbound for the session, and
/// for every later launch's retry tick: config kept evaluating the device anonymously with nothing
/// reported. A 404 means the server has no row for the device (purged, erased, another
/// environment's id), and the route documents that "the SDK re-registers"
/// (`apps/api/src/lib/device-identify.ts`). Now:
///
/// - transient failures (network, timeout, 408, 429, 5xx) retry after 1 s, 2 s and 4 s, or the
///   server's `Retry-After` when longer (capped at 5 s), each jittered up by up to half (never
///   shorter, so clients that failed together spread out);
/// - a 404 whose body is our `NOT_FOUND` registers a replacement device once and retries at once
///   against it; a 404 with any other body (a proxy, a WAF) is final like any other 4xx;
/// - every attempt marks its device, then checks the bind is still wanted (no `reset()`,
///   `destroy()`), and only then sends.
///
/// 🔴 Mark, THEN check. `SheepitClient.reset()` moves the reset token before it reads the marker
/// (`DeviceRotation.deviceMayBeBound()`), so the two sides order each other: a reset whose token
/// moved before the check stops the send, and one whose token moved after it reads the marker
/// already written and rotates the device. Checked only before the mark, a reset landing between
/// the two kept a device the POST then bound to the logged-out user. A check before the mark as
/// well spares a bind already unwanted its mark; one that fails only after it makes a later
/// `reset()` rotate once more than it had to, which is the safe direction.
///
/// 🔴 Unlike sdk-js, a 2xx is `bound` even if the bind stopped being wanted while it was on the
/// wire: the row does hold that user. `SheepitClient.postIdentity` records it as such unless the
/// client has since left that device (a `reset()` rotates it), so in practice this matters for a
/// re-sent POST whose user the app has since replaced (`automaticIdentifySendGuard`).
enum IdentifyLadder {
    /// Waits before retries 1, 2 and 3.
    static let retryDelays: [TimeInterval] = [1, 2, 4]
    /// Upper bound on a server-requested wait (`Retry-After`, sent with `503 IDENTIFY_BUSY`).
    static let retryAfterCap: TimeInterval = 5
    /// The API's code for a device it has no row for; any other 404 body is not ours.
    static let deviceNotFoundCode = "NOT_FOUND"

    /// How the bind ended. `stale` is not a failure: the app moved on before it finished.
    enum Outcome: String, Sendable {
        case bound
        case boundAfterRetry = "bound_after_retry"
        case boundAfterReregister = "bound_after_reregister"
        case rejected
        case notFound = "not_found"
        case exhausted
        case stale

        var isBound: Bool { self == .bound || self == .boundAfterRetry || self == .boundAfterReregister }
    }

    struct Result: Sendable, Equatable {
        let outcome: Outcome
        /// Requests sent, including the one after a re-registration.
        let attempts: Int
        /// The last HTTP status, or 0 for a network error, a timeout, or nothing sent.
        let status: Int
        /// The device the user was (or was last attempted to be) bound to.
        let deviceId: String
    }

    struct Dependencies {
        /// One identify request; nil when nothing was sent (its precondition stopped holding).
        let post: (String) async -> IdentifyResponse?
        /// The server does not know `deviceId`: the device to retry on, or nil.
        let reregister: (String) async -> String?
        /// Called for every attempt with the device it names, BEFORE `isCurrent` (see the type doc).
        let markBound: (String) -> Void
        /// False once the app has reset or the client was destroyed. Read again after `markBound`.
        let isCurrent: () -> Bool
        let sleep: (TimeInterval) async -> Void
        var delays: [TimeInterval] = IdentifyLadder.retryDelays
        var random: () -> Double = { Double.random(in: 0..<1) }
    }

    static func isTransient(_ status: Int) -> Bool {
        status == 0 || status == 408 || status == 429 || status >= 500
    }

    static func run(deviceId: String, _ deps: Dependencies) async -> Result {
        var current = deviceId
        var attempts = 0
        var retries = 0
        var reregistered = false
        var status = 0

        func result(_ outcome: Outcome) -> Result {
            Result(outcome: outcome, attempts: attempts, status: status, deviceId: current)
        }

        while true {
            // The first check only spares a bind already unwanted its mark; the second is the guard.
            guard deps.isCurrent() else { return result(.stale) }
            deps.markBound(current)
            guard deps.isCurrent() else { return result(.stale) }
            guard let response = await deps.post(current) else { return result(.stale) }
            attempts += 1
            status = response.status

            if (200..<300).contains(status) {
                return result(reregistered ? .boundAfterReregister : retries > 0 ? .boundAfterRetry : .bound)
            }
            guard deps.isCurrent() else { return result(.stale) }

            if status == 404 {
                guard response.code == deviceNotFoundCode else { return result(.rejected) }
                guard !reregistered else { return result(.notFound) }
                reregistered = true
                let fresh = await deps.reregister(current)
                guard deps.isCurrent() else { return result(.stale) }
                guard let fresh, fresh != current else { return result(.notFound) }
                current = fresh
                continue
            }

            guard isTransient(status) else { return result(.rejected) }
            guard retries < deps.delays.count else { return result(.exhausted) }
            let delay = deps.delays[retries]
            retries += 1
            let serverDelay = (response.retryAfter ?? 0) > 0 ? min(response.retryAfter ?? 0, retryAfterCap) : 0
            await deps.sleep(max(delay, serverDelay) * (1 + deps.random() * 0.5))
        }
    }
}

/// One identify request's answer, as `IdentifyLadder` reads it.
struct IdentifyResponse: Sendable, Equatable {
    /// The HTTP status, or 0 for a network error or timeout.
    let status: Int
    /// The server's `Retry-After`, in seconds.
    let retryAfter: TimeInterval?
    /// The API's `error.code`, when the body is its error envelope.
    let code: String?
}
