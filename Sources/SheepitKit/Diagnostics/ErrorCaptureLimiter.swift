import Foundation

/// Client-side burst limiter for `SheepitClient.captureError(_:error:attributes:)`, applied
/// BEFORE `track()` so a host app that reports the same failure in a tight loop cannot flood its
/// own queue, its ingest quota or the crash breadcrumb ring.
///
/// Two independent limits, checked in this order:
///   1. **Per signature** (message + error type + domain + code): the first call is sent; every
///      further call with the same signature inside `window` seconds of that send is suppressed
///      and counted. The next call of that signature sent after the window carries the count as
///      `suppressed_count`.
///   2. **Global**: at most `globalCap` sends in any rolling `window`, across every signature.
///      A call over the cap is dropped and counted; the count rides on the next event that IS
///      sent, of any signature, as `dropped_count`.
///
/// Memory is bounded: at most `maxSignatures` signatures are tracked; past that the one sent
/// longest ago is evicted (never the one just admitted; ties broken by admission order), and any
/// suppressed count it still held moves to the `dropped_count` pool so no call goes uncounted. A
/// suppressed count whose signature never recurs (and is never evicted) is never reported — the
/// limiter does not emit events of its own.
///
/// 🔴 The clock is MONOTONIC (`ProcessInfo.systemUptime`), not the wall clock: a user or NTP
/// stepping the date back a year used to wedge every window — a brand-new signature stayed
/// suppressed, silently. `systemUptime` counts AWAKE time only (it pauses while the device
/// sleeps), so a window spanning a sleep lasts longer in wall time; it never runs backwards. A
/// negative delta is still treated as "window elapsed", defensively — which also empties the
/// global cap's window; unreachable with a monotonic source. The closure is injected only so tests
/// age a window without sleeping.
///
/// Known gap: the counts handed out by `.send` are cleared here, before `track()` runs. If
/// `track()` then drops the event (the client is destroyed between the two calls, or the event
/// is later evicted from a full queue), those counts are lost with it. `track()` reports no
/// outcome to commit against, and the loss is bounded by one event's counts.
///
/// Thread-safe: one lock, held for the clock read and the bookkeeping, never across a call into
/// host code (the caller's diagnostic and `track()` both run after `admit` returns).
final class ErrorCaptureLimiter: @unchecked Sendable {
    static let window: TimeInterval = 60
    static let globalCap = 30
    static let maxSignatures = 100

    enum Decision: Equatable {
        /// Send the event, stamping these counts (each only when non-zero).
        case send(suppressedCount: Int, droppedCount: Int)
        /// Do not send. `notify` is true at most once per `window`, so the caller's
        /// diagnostic is itself rate-limited.
        case suppress(notify: Bool)
    }

    private struct Entry {
        var lastSent: TimeInterval
        /// Admission order, the deterministic tie-break for eviction.
        var sequence: UInt64
        var suppressed: Int
    }

    private let lock = NSLock()
    private let uptime: @Sendable () -> TimeInterval
    private let globalCap: Int
    private var entries: [String: Entry] = [:]
    private var nextSequence: UInt64 = 0
    /// Times of the sends inside the current rolling window; never longer than `globalCap`.
    private var recentSends: [TimeInterval] = []
    private var droppedPool = 0
    private var lastNotice: TimeInterval?

    /// `globalCap` is overridable only so a test can fill the signature table under a constant
    /// clock; production always uses `ErrorCaptureLimiter.globalCap`.
    init(
        uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        globalCap: Int = ErrorCaptureLimiter.globalCap
    ) {
        self.uptime = uptime
        self.globalCap = globalCap
    }

    /// True when `window` has passed since `start`, or the clock went backwards.
    private static func elapsed(from start: TimeInterval, to time: TimeInterval) -> Bool {
        let delta = time - start
        return delta < 0 || delta >= window
    }

    func admit(signature: String) -> Decision {
        // Sampled UNDER the lock, deliberately. Sampled before it, two racing callers can enter in
        // the opposite order to their timestamps; the later one then sees a negative delta, which
        // counts as "window elapsed" and empties the global window — measured: 40 sends through a
        // 30 cap under `concurrentPerform`. The clock is `systemUptime` (or a test closure): a
        // system read that cannot call back into the SDK or the host.
        lock.lock()
        defer { lock.unlock() }
        let time = uptime()

        if var entry = entries[signature], !Self.elapsed(from: entry.lastSent, to: time) {
            entry.suppressed += 1
            entries[signature] = entry
            return .suppress(notify: claimNotice(at: time))
        }

        recentSends.removeAll { Self.elapsed(from: $0, to: time) }
        if recentSends.count >= globalCap {
            droppedPool += 1
            return .suppress(notify: claimNotice(at: time))
        }

        let suppressed = entries[signature]?.suppressed ?? 0
        let dropped = droppedPool
        droppedPool = 0
        recentSends.append(time)
        entries[signature] = Entry(lastSent: time, sequence: nextSequence, suppressed: 0)
        nextSequence += 1
        evictIfNeeded(keeping: signature)
        return .send(suppressedCount: suppressed, droppedCount: dropped)
    }

    private func claimNotice(at time: TimeInterval) -> Bool {
        if let lastNotice, !Self.elapsed(from: lastNotice, to: time) { return false }
        lastNotice = time
        return true
    }

    private func evictIfNeeded(keeping current: String) {
        while entries.count > Self.maxSignatures {
            let victim = entries
                .filter { $0.key != current }
                .min { ($0.value.lastSent, $0.value.sequence) < ($1.value.lastSent, $1.value.sequence) }
            guard let victim else { return }
            droppedPool += victim.value.suppressed
            entries.removeValue(forKey: victim.key)
        }
    }

    /// Test-only: what the limiter's clock reads now.
    var uptimeForTesting: TimeInterval { uptime() }

    /// Test-only: how many signatures are tracked.
    var trackedSignatureCountForTesting: Int {
        lock.lock(); defer { lock.unlock() }; return entries.count
    }

    /// Test-only: whether `signature` is still tracked.
    func isTrackedForTesting(_ signature: String) -> Bool {
        lock.lock(); defer { lock.unlock() }; return entries[signature] != nil
    }
}
