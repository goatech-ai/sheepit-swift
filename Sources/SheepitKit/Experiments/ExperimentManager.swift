import Foundation

/// Why an exposure fired: the first read of the experiment, or a read after its arm changed.
enum ExperimentExposureReason: String, Sendable {
    case first
    case variantChanged = "variant_changed"
}

/// Experiments are bucketed server-side. `/v1/config` returns
/// `experiments: { experimentKey: { variant_key, payload, … } }` — one entry
/// per experiment the device is enrolled in. The SDK caches the
/// assignment, emits an exposure when an arm is first shown and again whenever
/// the arm changes, surfaces the variant, and captures the opaque config receipt
/// for each tracked event. Legacy per-entry inspection remains only for identity-gate regressions;
/// capture/transport never queue or serialize that map.
///
/// No client-side bucketing. No traffic gates. All of that happens on the
/// server so every platform agrees on the assignment for a given device.
/// Lock-guarded for the same reason as `FlagManager`: `setAssignments`
/// runs on ConfigSync's async callback while `resolve` and `receipt` run on
/// the host app's thread. `onExposure` and diagnostics are invoked OUTSIDE
/// the lock because they reach host closures, which may call back into the SDK.
final class ExperimentManager: @unchecked Sendable {
    private let lock = NSLock()
    private var assignments: [String: SDKExperimentAssignment] = [:]
    private var assignmentToken: String?
    /// The identity `assignments` were fetched under: what the server's device row was known to
    /// hold for the whole fetch (`ConfigSync.identityProvider`). `receipt` compares it with each
    /// event's user to detect an identity change that no `/v1/config` has answered yet.
    private var appliedIdentity: ConfigIdentity = .fetchedUnder(nil)
    /// Whether an `identify()` that SWITCHED users is still waiting for its config (`IdentitySwitch`).
    /// While it is, every receipt remains explicitly unattributed.
    private var identitySwitch: IdentitySwitch = .none
    /// Names each switch, so a settle from an earlier switch's POST (`identify(B); identify(A);
    /// identify(B)`, the first POST failing) cannot settle a later switch to the same user.
    private var lastSwitchToken: UInt64 = 0
    /// Whether the current assignment set has already reported `experiment.identity_changed`.
    /// Bounds that diagnostic to one per applied set rather than one per event.
    private var identityChangeReported = false
    /// Bumped whenever `assignments` is replaced, so a set captured before that (`capture()`) is
    /// recognisably stale and cannot consume the current set's `identityChangeReported`.
    private var generation: UInt64 = 0
    /// Bumped by logout or device replacement. A set captured before either belongs to the prior
    /// user, so an exposure tracked after it is stamped unattributed whatever the event says.
    private var logouts: UInt64 = 0
    /// experiment key → the variant its exposure was recorded for. Keyed per ARM:
    /// keyed per experiment, a subject moved to another arm was never exposed to
    /// it, which diluted the readout and hid the move from SRM.
    private var exposed: [String: String] = [:]
    /// Keys in `exposed` whose exposure went out MARKED (unattributed). Dropped from `exposed` when
    /// the wait ENDS (`setAssignments`), so the arm is exposed again once its claims can be
    /// attributed: spending the dedup on an unattributed exposure lost that subject's exposure for
    /// good. Not on every apply: that re-sent a `first` exposure per config while still marked.
    private var exposedWhileMarked: Set<String> = []
    /// The same, for `$flag_exposure`: flag keys whose exposure carried a marked entry. Handed to
    /// `FlagManager.forgetExposures` when the wait ends (`ExposureDecisionGate.apply`).
    private var flagsExposedWhileMarked: Set<String> = []
    private let storage: StorageProvider
    private let diagnostics: DiagnosticBus?
    /// Mirrors the arms into the crash context (`setVariantsObserver`); see FlagManager's
    /// `valuesObserver` for why its lock spans snapshot and delivery.
    private var variantsObserver: (@Sendable ([String: AnyCodable]) -> Void)?
    private let variantsObserverLock = NSLock()

    init(storage: StorageProvider, diagnostics: DiagnosticBus? = nil) {
        self.storage = storage
        self.diagnostics = diagnostics
    }

    /// SheepitKit ≤ 0.7.0 persisted a per-experiment "sticky" variant that nothing ever read;
    /// this SDK does not write it, and drops what an older one left.
    ///
    /// 🔴 Not in `init`: every `create()` candidate constructs this manager, including an inert
    /// client and a losing `initialize()` candidate, and neither may write to disk (findings
    /// E-001, MF3-1). `beginWork()` calls this, which only the published client runs.
    func dropLegacyStickyMap() {
        if storage.data(forKey: StorageKeys.experimentAssignments) != nil {
            storage.removeObject(forKey: StorageKeys.experimentAssignments)
        }
    }

    /// - Parameters:
    ///   - appliedUnder: the identity the config was fetched under. Required, not defaulted: a
    ///     caller that forgets it would silently label every assignment anonymous.
    ///   - origin: where the config came from. The launch cache never ends a switch, and a server
    ///     fetch ends a settled switch only if it started after the settle (`IdentitySwitch.after`).
    ///     Defaults to a server fetch started after every settle.
    /// - Returns: the flag keys whose marked exposures the caller must forget, when this config
    ///   ends a wait (`flagsExposedWhileMarked`).
    @discardableResult
    func setAssignments(
        _ assignments: [String: SDKExperimentAssignment],
        appliedUnder: ConfigIdentity,
        origin: ConfigApplyOrigin = .server(fetch: .max),
        assignmentToken: Any? = nil,
        eventIdentity: ConfigIdentity? = nil
    ) -> Set<String> {
        lock.lock()
        let wasSwitching = identitySwitch != .none
        let previousIdentity = appliedIdentity
        let normalizedToken = AssignmentReceipt.validToken(assignmentToken)
        let receiptRecovered = self.assignmentToken == nil && normalizedToken != nil
        self.assignmentToken = normalizedToken
        self.assignments = assignments
        appliedIdentity = appliedUnder
        identityChangeReported = false
        generation &+= 1
        identitySwitch = identitySwitch.after(applying: appliedUnder, origin: origin)
        // A wait ends when an identity switch ends, or when the applied label changes to a
        // confirmed one: a user, or `.fetchedUnder(nil)`, a confirmed anonymous row (a device
        // replacement). A re-sent exposure is marked again if that label is not the event's user.
        let switchEnded = wasSwitching && identitySwitch == .none
        let labelMoved = appliedUnder != previousIdentity && appliedUnder != .unknown && identitySwitch == .none
        var drainedFlags: Set<String> = []
        let currentIdentity = eventIdentity ?? appliedUnder
        // A token IS required (`testNullReceiptDoesNotReleaseAReadWhileAUsableLaterReceiptDoes`): a
        // re-sent exposure with no receipt claims nothing, so releasing on a null receipt would
        // duplicate the event without attributing it. The held exposures wait for a usable receipt.
        let receiptUsable = normalizedToken != nil && identitySwitch == .none
            && currentIdentity != .unknown && appliedUnder == currentIdentity
        if receiptUsable && (switchEnded || labelMoved || receiptRecovered) {
            for key in exposedWhileMarked { exposed[key] = nil }
            exposedWhileMarked.removeAll()
            drainedFlags = flagsExposedWhileMarked
            flagsExposedWhileMarked.removeAll()
        }
        // An experiment the server stopped sending is forgotten, so if the subject is
        // enrolled again its next read is a first exposure.
        exposed = exposed.filter { assignments[$0.key] != nil }
        lock.unlock()
        notifyVariants()
        return drainedFlags
    }

    /// A receipt belongs to the previous device row; retain decisions but invalidate captured aliases.
    func invalidateReceiptForDeviceChange() {
        lock.lock()
        assignmentToken = nil
        generation &+= 1
        logouts &+= 1
        lock.unlock()
    }

    /// Called with `activeVariants()` after the assignments change (`setAssignments`,
    /// `clearForLogout`), never under `lock`. Set by `SheepitClient` for the crash context.
    func setVariantsObserver(_ observer: (@Sendable ([String: AnyCodable]) -> Void)?) {
        variantsObserverLock.lock()
        variantsObserver = observer
        variantsObserverLock.unlock()
    }

    /// Experiment key → the variant key this device is in, for every active assignment.
    func activeVariants() -> [String: AnyCodable] {
        lock.lock()
        defer { lock.unlock() }
        return assignments.mapValues { AnyCodable($0.variantKey) }
    }

    private func notifyVariants() {
        variantsObserverLock.lock()
        if let variantsObserver { variantsObserver(activeVariants()) }
        variantsObserverLock.unlock()
    }

    /// `setAssignments(_:appliedUnder: .fetchedUnder(appliedUnderUserId))`.
    @discardableResult
    func setAssignments(_ assignments: [String: SDKExperimentAssignment], appliedUnderUserId: String?) -> Set<String> {
        setAssignments(assignments, appliedUnder: .fetchedUnder(appliedUnderUserId))
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return assignments.count
    }

    /// Receipt and exposure recovery use the same lock as assignments and identity switches.
    func receipt(
        _ decided: ExperimentAssignmentSet? = nil,
        eventUserId: String?,
        experimentKey: String? = nil,
        variant: String? = nil,
        flagKey: String? = nil
    ) -> (receipt: AssignmentReceipt, forgetFlag: Bool) {
        lock.lock()
        defer { lock.unlock() }
        let set = decided ?? currentSetLocked()
        let receipt = receiptLocked(set, eventUserId: eventUserId)
        let changed = receipt.status != nil
        let unattributed = changed || receipt.token == nil
        let stale = set.generation != generation
        if let experimentKey, let variant, exposed[experimentKey] == variant {
            if !unattributed { exposedWhileMarked.remove(experimentKey) }
            else if stale { exposed[experimentKey] = nil; exposedWhileMarked.remove(experimentKey) }
            else { exposedWhileMarked.insert(experimentKey) }
        }
        var forgetFlag = false
        if let flagKey {
            if !unattributed { flagsExposedWhileMarked.remove(flagKey) }
            else if stale { flagsExposedWhileMarked.remove(flagKey); forgetFlag = true }
            else { flagsExposedWhileMarked.insert(flagKey) }
        }
        return (receipt, forgetFlag)
    }

    /// The receipt for the current set, or nil when the lock is held: never waits, so sampling on a
    /// UI thread cannot stall behind a config apply. No exposure bookkeeping, unlike `receipt(...)`.
    func tryReceipt(eventUserId: String?) -> AssignmentReceipt? {
        guard lock.try() else { return nil }
        defer { lock.unlock() }
        return receiptLocked(currentSetLocked(), eventUserId: eventUserId)
    }

    private func receiptLocked(_ set: ExperimentAssignmentSet, eventUserId: String?) -> AssignmentReceipt {
        let changed = set.logouts != logouts || set.identitySwitchPending || identitySwitch != .none
            || set.appliedIdentity != .fetchedUnder(eventUserId)
        return AssignmentReceipt(token: set.assignmentToken, identityChanged: changed)
    }

    /// The active assignments and the identity they were applied under, frozen in one lock
    /// acquisition. `flag()` and `experiment()` take this at DECISION time and hand it to the
    /// exposure's `track`, so a config applied between the read and the event cannot pair the
    /// value the app was given with a different arm.
    func capture() -> ExperimentAssignmentSet {
        lock.lock()
        defer { lock.unlock() }
        return currentSetLocked()
    }

    /// Resolve the current variant for an experiment. Returns control if
    /// the device is not enrolled.
    ///
    /// `onExposure` receives the assignment set captured in the SAME lock acquisition that read
    /// the variant, so the exposure receipt names the config whose arm the app received.
    /// Attribution is decided by `receipt` against that occurrence's identity.
    func resolve(
        experimentKey: String,
        onExposure: (String, String, ExperimentExposureReason, ExperimentAssignmentSet) -> Void
    ) -> SheepitExperimentResult {
        lock.lock()

        guard let assignment = assignments[experimentKey] else {
            lock.unlock()
            return SheepitExperimentResult(variant: "control")
        }

        let variantKey = assignment.variantKey
        let seen = exposed[experimentKey]
        let reason: ExperimentExposureReason? = seen == variantKey ? nil : (seen == nil ? .first : .variantChanged)
        let decided = reason == nil ? nil : currentSetLocked()
        if decided != nil { exposed[experimentKey] = variantKey }
        lock.unlock()

        // Outside the lock — see the note on this type.
        if let reason, let decided {
            onExposure(experimentKey, variantKey, reason, decided)
        }

        // Audit E-008 — pass through `[String: AnyCodable]` directly
        // instead of stripping to `Any`. Keeps the public type Sendable
        // under Swift 6 strict concurrency.
        let payload: [String: AnyCodable]? = assignment.payload.isEmpty
            ? nil
            : assignment.payload
        return SheepitExperimentResult(variant: variantKey, payload: payload)
    }

    /// `identify()` is switching to `userId`: mark every entry until the config for `userId` lands
    /// (`IdentitySwitch`). Only a real switch calls this: re-sending the same user does not.
    /// Returns the switch's token, for `identityBindSettledWithoutAck(_:)`.
    ///
    /// 🔴 Arms only. `identify()` calls it BEFORE storing the new user and calls
    /// `clearExposures()` AFTER: clearing first let a read in between re-fire a `first` exposure
    /// as the PREVIOUS user, unmarked.
    ///
    /// 🔴 Deliberately leaves `assignments` — the server's current bucketing —
    /// in place. `identify()` does not itself produce a new assignment; the next
    /// `/v1/config` does. Wiping them here would make `experiment()` answer
    /// "control" for every experiment until that fetch landed, and "control" is
    /// a real arm — reporting it for a subject that was never bucketed into it
    /// is worse than briefly reporting the previous one.
    ///
    /// 🔴 Leaves `appliedIdentity` too, still naming the PREVIOUS user. That is what lets
    /// `receipt` marks the new user's events `identity_changed` until the next
    /// config is applied, instead of crediting them to the previous user's arm.
    @discardableResult
    func beginIdentitySwitch(to userId: String) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        lastSwitchToken &+= 1
        identitySwitch = .awaitingBind(userId, token: lastSwitchToken)
        return lastSwitchToken
    }

    /// Forget which arms were exposed, so the new user's reads fire again. `identify()` calls it
    /// once the new user is stored (`beginIdentitySwitch(to:)`).
    func clearExposures() {
        lock.lock()
        defer { lock.unlock() }
        clearLocked()
    }

    /// The bind of the switch named `token` ended without binding (rejected, exhausted,
    /// unanswered, or never sent). The next config applied ends the switch, so a bind that never
    /// succeeds marks only user-kind entries from then on instead of every claim for the session.
    /// A later automatic retry that binds the user is NOT waited for: that trade is the stuck-on
    /// rule the sdk-js twin's review set, and server-side stitching handles the crossover it leaves.
    /// - Parameter afterFetch: `ConfigSync.fetchesStarted.current` at the settle. Only a server fetch
    ///   numbered above it ends the switch: one already in flight may predate the bind's end.
    /// - Returns: whether it settled the current switch. The caller then owes a server config
    ///   (`refetchUnconditionally`): a poll answered 304 applies nothing and ends nothing.
    @discardableResult
    func identityBindSettledWithoutAck(_ token: UInt64, afterFetch: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard case .awaitingBind(_, token) = identitySwitch else { return false }
        identitySwitch = .bindSettled(afterFetch: afterFetch)
        return true
    }

    /// Forget everything about the logged-out user, including the server's
    /// in-memory assignments — variant AND payload — which are what `resolve()`
    /// and `receipt(eventUserId:)` read, and the user they were applied under.
    /// Clearing the cached config alone is not enough: these are already
    /// hydrated, so `experiment()` would hand the next user the previous user's
    /// arm until a fetch landed.
    func clearForLogout() {
        // 🔴 ONE acquisition, not two. Releasing between clearing `assignments`
        // and clearing the exposures left a window in which ConfigSync's
        // callback thread could repopulate `assignments` via `setAssignments`,
        // after which only the exposures got wiped — the logged-out user's
        // variant surviving a clear that appeared to succeed. `lock` is a
        // non-recursive NSLock, so the shared body is factored out rather than
        // re-entered.
        lock.lock()
        assignments.removeAll()
        assignmentToken = nil
        appliedIdentity = .fetchedUnder(nil)
        identityChangeReported = false
        generation &+= 1
        logouts &+= 1
        identitySwitch = .none
        clearLocked()
        lock.unlock()
        notifyVariants()
    }

    // MARK: - Private

    /// Shared body of `clearExposures()` / `clearForLogout()`.
    /// 🔴 Callers MUST hold `lock`.
    private func clearLocked() {
        exposed.removeAll()
        exposedWhileMarked.removeAll()
        flagsExposedWhileMarked.removeAll()
    }

    /// 🔴 Callers MUST hold `lock`.
    private func currentSetLocked() -> ExperimentAssignmentSet {
        ExperimentAssignmentSet(
            assignments: assignments,
            assignmentToken: assignmentToken,
            appliedIdentity: appliedIdentity,
            identitySwitchPending: identitySwitch != .none,
            generation: generation,
            logouts: logouts
        )
    }

    /// Report the already-enqueued occurrence outside the client's core locks and host callbacks.
    func reportIdentityChange(_ receipt: AssignmentReceipt, set: ExperimentAssignmentSet, eventUserId: String?) {
        guard receipt.status == "identity_changed" else { return }
        lock.lock()
        let stale = set.generation != generation
        guard stale || !identityChangeReported else { lock.unlock(); return }
        if !stale { identityChangeReported = true }
        lock.unlock()
        diagnostics?.emit(
            .info, .experiment, code: "experiment.identity_changed",
            message: "Identity changed since the applied config; the captured receipt is unattributed",
            data: [
                "outcome": AnyCodable("identity_changed"),
                "assignments": AnyCodable(set.assignments.count),
                "applied_identified": AnyCodable(set.appliedIdentity != .fetchedUnder(nil)),
                "event_identified": AnyCodable(eventUserId != nil),
                "identity_switch": AnyCodable(set.identitySwitchPending),
                "stale_set": AnyCodable(stale),
            ]
        )
    }

}

/// Where an `identify()` that switched users stands. Only `ExperimentManager` reads it.
private enum IdentitySwitch: Equatable {
    case none
    /// Switched to this user; no config for them yet, and the switch's bind has not ended unbound.
    case awaitingBind(String, token: UInt64)
    /// The switch's bind ended unbound (`identityBindSettledWithoutAck`); the next server fetch
    /// STARTED after that ends it.
    case bindSettled(afterFetch: Int)

    /// The switch after a config applied under `appliedUnder`. Ends on the switched-to user's own
    /// server config, or on a server fetch started after their bind settled unbound. 🔴 Any other
    /// config (the launch cache, whatever its label, or a fetch already in flight at the settle)
    /// leaves it pending; ending the switch still requires a matching receipt before attribution.
    func after(applying appliedUnder: ConfigIdentity, origin: ConfigApplyOrigin) -> IdentitySwitch {
        guard case .server(let fetch) = origin else { return self }
        switch self {
        case .none:
            return .none
        case .awaitingBind(let user, _):
            return appliedUnder == .fetchedUnder(user) ? .none : self
        case .bindSettled(let settledAfter):
            return fetch > settledAfter ? .none : self
        }
    }
}

/// The assignment set one read saw, and the identity it was applied under (`ExperimentManager.capture()`).
struct ExperimentAssignmentSet: Sendable {
    let assignments: [String: SDKExperimentAssignment]
    let assignmentToken: String?
    let appliedIdentity: ConfigIdentity
    /// Whether an identity switch awaited its config when this was captured.
    let identitySwitchPending: Bool
    /// `ExperimentManager`'s generation when this was captured.
    let generation: UInt64
    /// `ExperimentManager`'s logout count when this was captured.
    let logouts: UInt64
}
