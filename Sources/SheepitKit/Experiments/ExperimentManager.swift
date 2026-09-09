import Foundation

/// Experiments are bucketed server-side. `/v1/config` returns
/// `experiments: { experimentKey: { variant_key, payload } }` — one entry
/// per experiment the device is enrolled in. The SDK caches the
/// assignment, emits a single exposure per session, and surfaces the
/// variant.
///
/// No client-side bucketing. No traffic gates. All of that happens on the
/// server so every platform agrees on the assignment for a given device.
/// Lock-guarded for the same reason as `FlagManager`: `setAssignments`
/// runs on ConfigSync's async callback while `resolve` runs on the host
/// app's thread. `onExposure` is invoked OUTSIDE the lock because it
/// reaches the customer's `onEvent` closure, which may call back into the
/// SDK.
final class ExperimentManager: @unchecked Sendable {
    private let lock = NSLock()
    private var assignments: [String: SDKExperimentAssignment] = [:]
    /// Persisted per-session: remembers which variant we last surfaced.
    private var stickyAssignments: [String: String] = [:]
    private var exposed = Set<String>()
    private let storage: StorageProvider

    init(storage: StorageProvider) {
        self.storage = storage
        lock.lock()
        defer { lock.unlock() }
        loadStickyAssignments()
    }

    func setAssignments(_ assignments: [String: SDKExperimentAssignment]) {
        lock.lock()
        defer { lock.unlock() }
        self.assignments = assignments
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return assignments.count
    }

    /// Resolve the current variant for an experiment. Returns control if
    /// the device is not enrolled.
    func resolve(
        experimentKey: String,
        onExposure: (String, String) -> Void
    ) -> SheepitExperimentResult {
        lock.lock()

        guard let assignment = assignments[experimentKey] else {
            lock.unlock()
            return SheepitExperimentResult(variant: "control")
        }

        let variantKey = assignment.variantKey

        if stickyAssignments[experimentKey] != variantKey {
            stickyAssignments[experimentKey] = variantKey
            saveStickyAssignments()
        }

        let isFirstExposure = exposed.insert(experimentKey).inserted
        lock.unlock()

        // Outside the lock — see the note on this type.
        if isFirstExposure {
            onExposure(experimentKey, variantKey)
        }

        // Audit E-008 — pass through `[String: AnyCodable]` directly
        // instead of stripping to `Any`. Keeps the public type Sendable
        // under Swift 6 strict concurrency.
        let payload: [String: AnyCodable]? = assignment.payload.isEmpty
            ? nil
            : assignment.payload
        return SheepitExperimentResult(variant: variantKey, payload: payload)
    }

    func clearAssignments() {
        lock.lock()
        defer { lock.unlock() }
        stickyAssignments.removeAll()
        exposed.removeAll()
        storage.removeObject(forKey: StorageKeys.experimentAssignments)
    }

    // MARK: - Private (callers must hold `lock`)

    private func loadStickyAssignments() {
        guard let data = storage.data(forKey: StorageKeys.experimentAssignments),
              let loaded = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        stickyAssignments = loaded
    }

    private func saveStickyAssignments() {
        guard let data = try? JSONEncoder().encode(stickyAssignments) else { return }
        storage.set(data, forKey: StorageKeys.experimentAssignments)
    }
}
