import Foundation

/// Disk-persisted queue for events that couldn't be sent due to offline state.
/// Mirrors packages/sdk-js/src/offline.ts
///
/// Lock-guarded for the same reason as `EventQueue`: the connectivity
/// monitor's `onOnline` callback drains it on one queue while the
/// `Transport` actor enqueues failed batches from another.
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
        save()
        lock.unlock()

        // Outside the lock — see the note in EventQueue.add.
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

    func size() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return events.count
    }

    // MARK: - Persistence (callers must hold `lock`)

    private func save() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        storage.set(data, forKey: StorageKeys.offlineQueue)
    }

    private func load() {
        guard let data = storage.data(forKey: StorageKeys.offlineQueue),
              let loaded = try? JSONDecoder().decode([EnrichedEvent].self, from: data) else { return }
        events = loaded
    }
}
