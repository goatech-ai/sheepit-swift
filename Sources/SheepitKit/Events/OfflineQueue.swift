import Foundation

/// Disk-persisted queue for events a flush could not deliver (offline, 429, 5xx, network).
///
/// `Transport` sends from a `peek()` and removes each event only once its request is answered
/// (`remove(eventIds:)`): delivered, or permanently refused. The other ways an event leaves disk
/// are the capacity trim (`offline_queue.trimmed`) and a `save()` that drops an event which
/// cannot be encoded (`offline_queue.unencodable_dropped`).
///
/// 🔴 Assumes ONE instance per storage key. Each instance holds its own copy and `save()`
/// overwrites the key with it, so two live clients on the same suite can overwrite each other's
/// writes (see PENDING_WORK.md).
///
/// Lock-guarded for the same reason as `EventQueue`: `Transport` mutates it from its actor
/// while registration's restamp and `SheepitClient`'s connectivity callback reach it from
/// other threads.
/// `save()` / `load()` assume the lock is already held — they must never
/// take it themselves (NSLock is not recursive).
final class OfflineQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [EnrichedEvent] = []
    private let storage: StorageProvider
    private let maxSize: Int
    private let diagnostics: DiagnosticBus?

    init(
        storage: StorageProvider,
        maxSize: Int = SDKDefaults.offlineQueueMax,
        diagnostics: DiagnosticBus? = nil
    ) {
        self.storage = storage
        self.maxSize = maxSize
        self.diagnostics = diagnostics
        lock.lock()
        defer { lock.unlock() }
        load()
    }

    func enqueue(_ newEvents: [EnrichedEvent]) {
        lock.lock()
        events.append(contentsOf: newEvents)
        // Trim oldest if over capacity
        var trimmed = 0
        if events.count > maxSize {
            trimmed = events.count - maxSize
            events = Array(events.suffix(maxSize))
        }
        let unencodable = save()
        lock.unlock()

        // Outside the lock — see the note in EventQueue.add.
        if unencodable > 0 {
            diagnostics?.emit(
                .error,
                .transport,
                code: "offline_queue.unencodable_dropped",
                message: "Dropped \(unencodable) events that cannot be encoded as JSON (non-finite number?)",
                data: ["dropped_count": AnyCodable(unencodable)]
            )
        }
        guard trimmed > 0 else { return }
        diagnostics?.emit(
            .warn,
            .transport,
            code: "offline_queue.trimmed",
            message: "Offline queue full (\(maxSize)) — dropped \(trimmed) of the oldest events",
            data: [
                "max_size": AnyCodable(maxSize),
                "dropped_count": AnyCodable(trimmed),
            ]
        )
    }

    func drain() -> [EnrichedEvent] {
        lock.lock()
        defer { lock.unlock() }
        let drained = events
        events.removeAll()
        save()
        return drained
    }

    /// Every persisted event, oldest first, LEFT IN PLACE. `drain()` wrote the queue empty
    /// before any request went out, so a process killed mid-flush lost all of it.
    func peek() -> [EnrichedEvent] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }

    /// Remove events whose request was answered (delivered or permanently refused). An id no
    /// longer present — trimmed while its request was in flight — is ignored.
    func remove(eventIds: Set<String>) {
        guard !eventIds.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        let before = events.count
        events.removeAll { eventIds.contains($0.eventId) }
        if events.count != before { save() }
    }

    func size() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return events.count
    }

    /// The trim bound. Immutable, so no lock.
    var capacity: Int { maxSize }

    /// `EventQueue.restampDeviceId(from:to:)` for the persisted queue, same exact-match rule.
    /// Needed since S3c: a 429 on the first flush now persists events here instead of putting
    /// them back on the in-memory queue, which registration restamps.
    func restampDeviceId(from oldDeviceId: String, to newDeviceId: String) {
        guard oldDeviceId != newDeviceId else { return }
        lock.lock()
        defer { lock.unlock() }
        var changed = false
        for index in events.indices where events[index].deviceId == oldDeviceId {
            events[index] = events[index].withDeviceId(newDeviceId)
            changed = true
        }
        if changed { save() }
    }

    // MARK: - Persistence (callers must hold `lock`)

    /// Persist the queue. Returns how many events were removed because they cannot be encoded.
    ///
    /// The array is encoded as one value, so a single event holding a non-finite `Double`
    /// used to fail the WHOLE save under `try?` — silently leaving nothing on disk while every
    /// other event looked persisted. Such an event can never be sent either, so it is dropped.
    @discardableResult
    private func save() -> Int {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(events) {
            storage.set(data, forKey: StorageKeys.offlineQueue)
            return 0
        }
        let before = events.count
        events.removeAll { (try? encoder.encode($0)) == nil }
        if let data = try? encoder.encode(events) {
            storage.set(data, forKey: StorageKeys.offlineQueue)
        }
        return before - events.count
    }

    private func load() {
        guard let data = storage.data(forKey: StorageKeys.offlineQueue),
              let loaded = try? JSONDecoder().decode([EnrichedEvent].self, from: data) else { return }
        events = loaded
    }
}
