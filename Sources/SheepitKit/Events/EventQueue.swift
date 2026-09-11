import Foundation

/// Internal enriched event — flat structure that gets transformed to API format on flush.
struct EnrichedEvent: Codable, Sendable {
    let eventId: String
    let eventName: String
    let eventProperties: [String: AnyCodable]?
    let deviceId: String
    let anonymousId: String
    let sessionId: String
    let userId: String?
    let platform: String
    let sdkVersion: String
    let locale: String
    let timezone: String
    let timestamp: String

    /// Every field copied except `deviceId`. Used ONLY by
    /// `EventQueue.restampDeviceId(from:to:)` — see its doc for why a queued event's
    /// device id is ever rewritten after enqueue.
    func withDeviceId(_ newDeviceId: String) -> EnrichedEvent {
        EnrichedEvent(
            eventId: eventId,
            eventName: eventName,
            eventProperties: eventProperties,
            deviceId: newDeviceId,
            anonymousId: anonymousId,
            sessionId: sessionId,
            userId: userId,
            platform: platform,
            sdkVersion: sdkVersion,
            locale: locale,
            timezone: timezone,
            timestamp: timestamp
        )
    }
}

/// In-memory FIFO event queue with max capacity.
/// Mirrors packages/sdk-js/src/queue.ts
///
/// Every access is lock-guarded. `add(_:)` is called from whatever thread
/// the host app calls `SheepitClient.track()` on, while `drain()` and — since
/// the 429 re-queue path — `add(_:)` are also called from the `Transport`
/// actor's executor. Unsynchronized `Array` mutation across those two is a
/// genuine memory-corruption race, reproduced under ThreadSanitizer
/// (`Swift access race` → SEGV inside `Array.append`) during the review of
/// the transport error-classing change.
final class EventQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [EnrichedEvent] = []
    private let maxSize: Int
    private let diagnostics: DiagnosticBus?

    init(maxSize: Int = SDKDefaults.maxQueueSize, diagnostics: DiagnosticBus? = nil) {
        // Clamped to >= 1 HERE, not just in `SheepitConfig.init`: `add(_:)` below calls
        // `removeFirst()` once `count >= maxSize`, which traps on an empty array at
        // `maxSize == 0` — and `SheepitConfig.maxQueueSize` is a public `var`, so
        // `var cfg = ...; cfg.maxQueueSize = 0` reaches this initializer already unclamped
        // (2026-09 security follow-up round 3, finding MF-1). This is the actual consumer, so
        // it's the layer that has to hold regardless of what the config struct did.
        self.maxSize = max(1, maxSize)
        self.diagnostics = diagnostics
    }

    func add(_ event: EnrichedEvent) {
        lock.lock()
        var evicted: EnrichedEvent?
        if events.count >= maxSize {
            evicted = events.removeFirst()
        }
        events.append(event)
        lock.unlock()

        // Emitted OUTSIDE the lock: DiagnosticBus invokes subscribers
        // synchronously, and a subscriber that called back into the queue
        // would deadlock on this non-recursive lock.
        guard let evicted else { return }
        diagnostics?.emit(
            .warn,
            .transport,
            code: "queue.overflow_evicted",
            message: "Event queue full (\(maxSize)) — dropped the oldest event",
            data: [
                "max_size": AnyCodable(maxSize),
                "dropped_event": AnyCodable(evicted.eventName),
            ]
        )
    }

    func drain() -> [EnrichedEvent] {
        lock.lock()
        defer { lock.unlock() }
        let drained = events
        events.removeAll()
        return drained
    }

    func size() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return events.count
    }

    /// Re-stamp every currently-queued event still carrying `oldDeviceId` to `newDeviceId`.
    ///
    /// `track()` stamps each event with whatever `context.deviceId` was at the moment it was
    /// enqueued. On a device's first-ever launch that id is a LOCALLY-minted placeholder —
    /// registration is a detached, awaited-nowhere `Task`, so any event enqueued before it
    /// resolves (the SDK's own `$session_start`, or an eager host `track()` call) captures
    /// that placeholder, not the server-assigned id `context.setDeviceId()` adopts once the
    /// round trip completes. Without this, such an event never joins `device_assignments`
    /// (written under the SERVER id) and its whole history is permanently orphaned — the
    /// exact defect D-1 exists to close, just one step later in the pipeline.
    ///
    /// Scoped to an EXACT match on `oldDeviceId` so it can never touch an event that already
    /// carries a different id — including one a 429 already re-queued under some other
    /// device's identity, or one enqueued AFTER the swap that already carries the new id.
    func restampDeviceId(from oldDeviceId: String, to newDeviceId: String) {
        guard oldDeviceId != newDeviceId else { return }
        lock.lock()
        defer { lock.unlock() }
        for index in events.indices where events[index].deviceId == oldDeviceId {
            events[index] = events[index].withDeviceId(newDeviceId)
        }
    }
}
