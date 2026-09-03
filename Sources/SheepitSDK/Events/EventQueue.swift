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
}

/// In-memory FIFO event queue with max capacity.
/// Mirrors packages/sdk-js/src/queue.ts
///
/// Every access is lock-guarded. `add(_:)` is called from whatever thread
/// the host app calls `Sheepit.track()` on, while `drain()` and — since
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
        self.maxSize = maxSize
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
}
