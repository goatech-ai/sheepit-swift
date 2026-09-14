import Foundation

/// Experiments are bucketed server-side. `/v1/config` returns
/// `experiments: { experimentKey: { variant_key, payload, … } }` — one entry
/// per experiment the device is enrolled in. The SDK caches the
/// assignment, emits a single exposure per session, surfaces the
/// variant, and snapshots every active assignment onto each tracked event.
///
/// No client-side bucketing. No traffic gates. All of that happens on the
/// server so every platform agrees on the assignment for a given device.
/// Lock-guarded for the same reason as `FlagManager`: `setAssignments`
/// runs on ConfigSync's async callback while `resolve` and `snapshot` run on
/// the host app's thread. `onExposure` and diagnostics are invoked OUTSIDE
/// the lock because they reach host closures, which may call back into the SDK.
final class ExperimentManager: @unchecked Sendable {
    private let lock = NSLock()
    private var assignments: [String: SDKExperimentAssignment] = [:]
    /// The identity `assignments` were fetched under: what the server's device row was known to
    /// hold for the whole fetch (`ConfigSync.identityProvider`). `snapshot(eventUserId:)` compares it with each event's
    /// user to detect an identity change that no `/v1/config` has answered yet.
    private var appliedIdentity: ConfigIdentity = .fetchedUnder(nil)
    /// Whether the current assignment set has already reported `experiment.identity_changed`.
    /// Bounds that diagnostic to one per applied set rather than one per event.
    private var identityChangeReported = false
    /// Persisted per-session: remembers which variant we last surfaced.
    private var stickyAssignments: [String: String] = [:]
    private var exposed = Set<String>()
    private let storage: StorageProvider
    private let diagnostics: DiagnosticBus?

    init(storage: StorageProvider, diagnostics: DiagnosticBus? = nil) {
        self.storage = storage
        self.diagnostics = diagnostics
        lock.lock()
        defer { lock.unlock() }
        loadStickyAssignments()
    }

    /// - Parameter appliedUnder: the identity the config was fetched under. Required, not
    ///   defaulted: a caller that forgets it would silently label every assignment anonymous.
    func setAssignments(_ assignments: [String: SDKExperimentAssignment], appliedUnder: ConfigIdentity) {
        lock.lock()
        defer { lock.unlock() }
        self.assignments = assignments
        appliedIdentity = appliedUnder
        identityChangeReported = false
    }

    /// `setAssignments(_:appliedUnder: .fetchedUnder(appliedUnderUserId))`.
    func setAssignments(_ assignments: [String: SDKExperimentAssignment], appliedUnderUserId: String?) {
        setAssignments(assignments, appliedUnder: .fetchedUnder(appliedUnderUserId))
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return assignments.count
    }

    /// Every active assignment, as it stands NOW, for an event being tracked by `eventUserId`.
    /// `nil` when none are active.
    ///
    /// A user-bucketed entry whose applied-under identity differs from the event's user —
    /// including an event with no user while the set was applied under one, and a set whose
    /// identity is `.unknown` — is marked `EventAssignment.identityChanged`: the server may have
    /// bucketed a different user, so the arm must not be credited to this one. A device-bucketed
    /// entry is never marked; `identify()` does not change the device. Every kind other than
    /// `"device"` counts as user-bucketed, including none (a config cached before `/v1/config`
    /// vended one) and one the SDK does not know: `Transport` omits those from
    /// `experiment_assignments` either way, and the mark keeps them out of the legacy
    /// `experiments` map.
    ///
    /// An anonymous event under an anonymous applied set is NOT marked, even for a user-kind
    /// entry: the server resolves the subject from the event and records `missing_user_identity`.
    func snapshot(eventUserId: String?) -> [String: EventAssignment]? {
        lock.lock()
        guard !assignments.isEmpty else {
            lock.unlock()
            return nil
        }
        let identityChanged = appliedIdentity != .fetchedUnder(eventUserId)
        var result: [String: EventAssignment] = [:]
        result.reserveCapacity(assignments.count)
        var marked = 0
        for (key, assignment) in assignments {
            let userBucketed = assignment.subjectKind != "device"
            let status = identityChanged && userBucketed ? EventAssignment.identityChanged : nil
            if status != nil { marked += 1 }
            result[key] = EventAssignment(
                variantKey: assignment.variantKey,
                experimentId: assignment.experimentId,
                subjectKind: assignment.subjectKind,
                bucketingVersion: assignment.bucketingVersion,
                assignmentRevision: assignment.assignmentRevision,
                subjectStatus: status
            )
        }
        let report = marked > 0 && !identityChangeReported
        if report { identityChangeReported = true }
        let appliedIdentified = appliedIdentity != .fetchedUnder(nil)
        lock.unlock()

        // Outside the lock — see the note on this type. No user ids: they are the customer's
        // end-user identifiers, and diagnostics reach host log pipelines.
        if report {
            diagnostics?.emit(
                .info,
                .experiment,
                code: "experiment.identity_changed",
                message: "Identity changed since experiment assignments were fetched — "
                    + "\(marked) user-bucketed assignments are sent as identity_changed until the next config",
                data: [
                    "assignments": AnyCodable(marked),
                    "applied_identified": AnyCodable(appliedIdentified),
                    "event_identified": AnyCodable(eventUserId != nil),
                ]
            )
        }
        return result
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

    /// Drop the STICKY map. Used by `identify()` when the user id changes.
    ///
    /// 🔴 Deliberately leaves `assignments` — the server's current bucketing —
    /// in place. `identify()` does not itself produce a new assignment; the next
    /// `/v1/config` does. Wiping them here would make `experiment()` answer
    /// "control" for every experiment until that fetch landed, and "control" is
    /// a real arm — reporting it for a subject that was never bucketed into it
    /// is worse than briefly reporting the previous one.
    ///
    /// 🔴 Leaves `appliedIdentity` too, still naming the PREVIOUS user. That is what lets
    /// `snapshot(eventUserId:)` mark the new user's events `identity_changed` until the next
    /// config is applied, instead of crediting them to the previous user's arm.
    func clearAssignments() {
        lock.lock()
        defer { lock.unlock() }
        clearLocked()
    }

    /// Forget everything about the logged-out user, including the server's
    /// in-memory assignments — variant AND payload — which are what `resolve()`
    /// and `snapshot(eventUserId:)` read, and the user they were applied under.
    /// Clearing the cached config alone is not enough: these are already
    /// hydrated, so `experiment()` would hand the next user the previous user's
    /// arm until a fetch landed.
    func clearForLogout() {
        // 🔴 ONE acquisition, not two. Releasing between clearing `assignments`
        // and calling `clearAssignments()` left a window in which ConfigSync's
        // callback thread could repopulate `assignments` via `setAssignments`,
        // after which only the sticky map got wiped — the logged-out user's
        // variant surviving a clear that appeared to succeed. `lock` is a
        // non-recursive NSLock, so the shared body is factored out rather than
        // re-entered.
        lock.lock()
        defer { lock.unlock() }
        assignments.removeAll()
        appliedIdentity = .fetchedUnder(nil)
        identityChangeReported = false
        clearLocked()
    }

    /// Shared body of `clearAssignments()` / `clearForLogout()`.
    /// 🔴 Callers MUST hold `lock`.
    private func clearLocked() {
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
