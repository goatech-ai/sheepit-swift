import Foundation

/// Switches to a freshly registered device when `reset()` (logout) runs on a device a user may be
/// bound to. Owned by `SheepitClient`; web counterpart: `packages/sdk-js/src/device-registration.ts`.
///
/// 🔴 Why. `/v1/config` evaluates the server's device row for the request's `X-Device-ID`, and that
/// row's user is written only by `POST /v1/devices/:id/identify` — there is no unbind. A logout
/// that kept the device id therefore had the next config fetch re-deliver the logged-out user's
/// flag values and experiment variants on a shared device.
///
/// **Which devices rotate.** One an identify POST was SENT for (`StorageKeys.deviceBindAttempted`,
/// written before the request, so an unanswered POST counts), or whose persisted `ServerHeldUser`
/// names a user (an install upgraded from an SDK that predates the marker). Keyed on the attempt,
/// not on a confirmed registration: a registration that timed out client-side can still have
/// landed, and the identify after it then binds that row. A device no identify was sent for is
/// kept — including an upgraded install whose label is the default `.unknown` — because every new
/// row counts against the metered device total. The marker holds the devices recent POSTs were sent
/// for (`BindMarker`) and counts only while it holds this client's CURRENT id, so after a rotation
/// it no longer matches and a `reset()` while the new registration is pending keeps the pending
/// device: no identify can have been sent for it, since identify waits for registration
/// (`RegistrationGate`).
///
/// 🔴 The marker is shared by every scope (`StorageScope`) and never cleared here: two live clients
/// on different keys hold the same device, and one client's rotation or bind must not erase what the
/// other's unanswered POST recorded, in this launch or an earlier one. A stale id simply stops
/// matching.
///
/// **How.** Synchronously in `reset()`: a freshly minted UUIDv4 replaces the old id (so no request
/// after the logout names the old device), and the label becomes `.known(nil)`. Then that id is
/// PROPOSED to `POST /v1/devices/register` under the rotated anonymous id — the same path a fresh
/// install takes (`Docs/Technical/SDK_DEVICE_REGISTRATION_CONTRACT.md` § 1). When the server
/// honours it nothing more changes; only a replaced id re-stamps queued events and refetches
/// config. A failed registration is retried under `RegistrationPolicy` and never falls back to the
/// old id; until it succeeds, config fetched under the new id resolves no row and evaluates
/// anonymously.
final class DeviceRotation: @unchecked Sendable {
    struct Dependencies {
        let context: ContextManager
        let deviceManager: DeviceManager
        let policy: RegistrationPolicy
        let queue: EventQueue
        let offlineQueue: OfflineQueue
        let storage: StorageProvider
        let diagnostics: DiagnosticBus
        let configSync: ConfigSync
        let registrationGate: RegistrationGate
        let now: @Sendable () -> Date
        let isDestroyed: @Sendable () -> Bool
        /// The device id changed (placeholder, then the adopted id): refresh what crash reports carry.
        let onDeviceIdChanged: @Sendable () -> Void
        /// C5 swapped a fresh device in for an anonymous install. Its exposure subject was the
        /// device, so every flag and arm must be exposed again for the fresh id (sdk-js
        /// `dropErasedDevicePayload`). Not for an identified install: its subject is the user.
        var onAnonymousDeviceReplaced: @Sendable () -> Void = {}
        /// Called BEFORE every write that changes the in-memory device id, so the receipt issued for
        /// the old device is already invalid when the new id becomes visible: a capture can never pair
        /// the old device's token with the new device id (`SheepitClient.deviceIdWillChange`).
        var beforeDeviceIdChange: @Sendable () -> Void = {}
    }

    private let deps: Dependencies
    /// F-2: C5 swapped a fresh device in for an identified install, whose label is now unknown.
    /// `SheepitClient.start()` sets it to its existing identity retry (`retryIdentityIfUnknown`), so
    /// the fresh row is bound at once, as sdk-js `enqueueBind`, not at the next refresh tick.
    let onIdentifiedDeviceReplaced = LockedValue<(@Sendable () -> Void)?>(nil)
    private let lock = NSLock()
    /// Bumped by every rotation and by `cancel()`. A registration from an older generation adopts
    /// nothing.
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    /// The replacement registering for a device id, if any (`replacement(for:)`): single-flight, so
    /// an identify 404 and C5 for the same erased device register ONE replacement (SK-Q12).
    private var replacing: (from: String, task: Task<String?, Never>)?
    private var _retryDelayOverride: (@Sendable (TimeInterval) -> Duration)?

    init(_ deps: Dependencies) {
        self.deps = deps
    }

    /// Test-only: maps the policy's wait (seconds) to the real sleep.
    var retryDelayOverride: (@Sendable (TimeInterval) -> Duration)? {
        get { lock.lock(); defer { lock.unlock() }; return _retryDelayOverride }
        set { lock.lock(); _retryDelayOverride = newValue; lock.unlock() }
    }

    private func sleep(seconds: TimeInterval) async {
        try? await Task.sleep(for: retryDelayOverride?(seconds) ?? .seconds(seconds))
    }

    /// Whether `reset()` must rotate, read BEFORE anything is cleared but after the reset token moves,
    /// which is what makes a racing identify either unsent or already marked (`IdentifyLadder`). See
    /// the type doc.
    func deviceMayBeBound() -> Bool {
        if BindMarker.contains(deps.context.deviceId, in: deps.storage) { return true }
        if case .known(let userId?) = deps.context.serverHeldUser.user, !userId.isEmpty { return true }
        return false
    }

    /// Record, BEFORE an identify POST is sent for `deviceId`, that its row may hold a user.
    func markBindAttempted(deviceId: String) {
        BindMarker.insert(deviceId, in: deps.storage)
    }

    /// An identify POST got 404 `NOT_FOUND` for `deviceId`: the server has no row for it (purged,
    /// erased, another environment's id). Returns the device to retry on: a replacement registered
    /// here, or the device already in use when the client has moved off `deviceId` (the launch
    /// registration adopted its own id meanwhile). Nil keeps the current device (`IdentifyLadder`).
    /// Web counterpart: `DeviceRegistration.replaceUnknown()`.
    ///
    /// 🔴 The old id stays in use until a replacement exists: registering first and swapping only on
    /// success means a cap, a rate limit or an outage never leaves the app with no device at all.
    /// Nothing is registered while a persisted backoff window is open, every failure writes one, and
    /// the attempt comes out of the launch budget, so a fleet of unknown devices cannot hammer the
    /// environment. The replacement is a FRESH local UUIDv4, proposed: re-registering the old id
    /// would resurrect an erased device.
    ///
    /// One request (`DeviceManager.register` never retries): the identify chain waits on this.
    /// Single-flight per device id: a caller arriving while a replacement for `deviceId` registers
    /// waits for that one (`replacement(for:)`).
    func replaceUnknown(_ deviceId: String) async -> String? {
        await replacement(for: deviceId, onMinted: nil).task.value
    }

    /// The replacement for `deviceId`: the one already registering (`joined`), or a new one. Under
    /// `lock`, so two callers cannot both start one. A caller arriving after it finished starts a new
    /// one, which returns the device already in use without registering (`registerReplacement`).
    /// `onMinted` belongs to the caller that starts it: called when ITS registration is answered
    /// with a device, swapped in or not; a joiner's is never called.
    private func replacement(
        for deviceId: String, onMinted: (@Sendable () -> Void)?
    ) -> (task: Task<String?, Never>, joined: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if let replacing, replacing.from == deviceId { return (replacing.task, true) }
        let task = Task<String?, Never> { [weak self] in
            guard let self else { return nil }
            let result = await self.registerReplacement(for: deviceId, onMinted: onMinted)
            self.finishReplacement(from: deviceId)
            return result
        }
        replacing = (deviceId, task)
        return (task, false)
    }

    private func finishReplacement(from deviceId: String) {
        lock.lock()
        defer { lock.unlock() }
        if replacing?.from == deviceId { replacing = nil }
    }

    private func registerReplacement(for deviceId: String, onMinted: (@Sendable () -> Void)?) async -> String? {
        let context = deps.context
        guard !deps.isDestroyed() else { return nil }
        // Already moved off it. After a `reset()` the ladder stops anyway (`isCurrent`); after the
        // launch registration adopted its own id, that is the device to bind.
        let inUse = context.deviceId
        if inUse != deviceId { return inUse }
        if deps.policy.openWindow() != nil {
            deps.diagnostics.emit(
                .warn,
                .identity,
                code: "identity.device_replacement_deferred",
                message: "The server has no record of this device, but registration is backing off — keeping it for now"
            )
            return nil
        }
        deps.diagnostics.emit(
            .warn,
            .identity,
            code: "identity.device_unknown_reregistering",
            message: "The server has no record of this device — registering a replacement"
        )
        guard deps.policy.takeAttempt() else { return nil }
        let started = currentGeneration()
        let proposal = ContextManager.mintDeviceId()
        let outcome = await deps.deviceManager.register(anonymousId: context.anonymousId, proposedDeviceId: proposal)
        let failure: (outcome: String, data: [String: AnyCodable])
        switch outcome {
        case .success(let fresh):
            onMinted?()
            switch swapInReplacement(fresh, for: deviceId, generation: started) {
            case .swapped:
                // The erased row's cached body goes now: with no age limit nothing else removes
                // it, and the next launch would apply it to the fresh id (SK-Q18). Only here, on
                // a swap: a failed or deferred replacement keeps it, and its C5 stamp, for a retry.
                deps.configSync.dropPersistedCacheForDeviceReplacement(freshId: fresh)
                deps.onDeviceIdChanged()
                deps.diagnostics.emit(
                    .info,
                    .identity,
                    code: "identity.device_replaced_unknown",
                    message: "Now on a fresh device in place of one the server did not know"
                )
                return fresh
            case .moved(let current):
                deps.diagnostics.emit(
                    .debug,
                    .identity,
                    code: "identity.device_registration_superseded",
                    message: "A replacement registered after the client moved to another device — discarded"
                )
                return current
            case .superseded:
                deps.diagnostics.emit(
                    .debug,
                    .identity,
                    code: "identity.device_registration_superseded",
                    message: "A device registration finished after the client moved on — discarded"
                )
                return nil
            }
        case .transientFailure(let reason, let retryAfter):
            deps.policy.recordFailure(.transient, retryAfter: retryAfter)
            failure = (reason, [:])
        case .terminalFailure(let rejection):
            deps.policy.recordFailure(.terminal)
            failure = ("rejected", rejection.diagnosticData)
        case .capReached(let rejection, let retryAfter):
            deps.policy.recordFailure(.cap, retryAfter: retryAfter)
            failure = ("device_cap_reached", rejection.diagnosticData)
        case .rateLimited(let retryAfter):
            deps.policy.recordFailure(.rateLimited, retryAfter: retryAfter)
            failure = ("rate_limited", [:])
        }
        deps.diagnostics.emit(
            .warn,
            .identity,
            code: "identity.device_replacement_failed",
            message: "Registering a replacement for an unknown device failed — keeping the current id",
            data: failure.data.merging(["outcome": AnyCodable(failure.outcome)]) { _, new in new }
        )
        return nil
    }

    /// C5 (contract § 7): `/v1/config` answered `unknown_device` for `deviceId` after a body it
    /// resolved for that id was applied, so the row was erased or purged. The identify-404
    /// replacement (`replaceUnknown`: fresh UUIDv4, same backoff, budget and swap), then the refetch
    /// a replaced id owes, so a kill switch lands now rather than after the next re-registration.
    ///
    /// The fresh row holds no user. An identified app's label becomes unknown, so the next refresh
    /// tick re-sends its identify (`retryIdentityIfUnknown`) and no body is labelled with a user the
    /// row does not hold; an anonymous one's becomes `.known(nil)`, as after any new registration.
    ///
    /// Claims (or joins) the replacement synchronously and returns whether it JOINED one already
    /// registering for `deviceId` (an identify 404's): then it registers nothing and leaves the label
    /// to that caller, whose identify binds the fresh row, but still refetches so the kill switch
    /// lands. Called from inside `ConfigSync`, so the rest runs in a task. If nothing replaces the
    /// device (the registration failed or was deferred), `outcome.unreplaced` drops its values.
    /// A nil `outcome` is a capped trigger: only say whether the client is still on `deviceId`.
    func replaceErasedDevice(
        _ deviceId: String, outcome: ConfigSync.ErasedDeviceOutcome?
    ) -> ConfigSync.ErasedDeviceClaim {
        let context = deps.context
        // Already off it (a logout rotated, or an identify 404 replaced it): `replaceUnknown` would
        // return the device in use, which is not a replacement and must be neither relabelled nor
        // refetched here.
        guard !deps.isDestroyed(), context.deviceId == deviceId else { return .notCurrent }
        guard let outcome else { return .capped }
        let (task, joined) = replacement(for: deviceId, onMinted: outcome.minted)
        let (configSync, isDestroyed) = (deps.configSync, deps.isDestroyed)
        let onAnonymousDeviceReplaced = deps.onAnonymousDeviceReplaced
        let retryIdentity = onIdentifiedDeviceReplaced
        Task {
            guard let fresh = await task.value, fresh != deviceId else {
                if !isDestroyed(), context.deviceId == deviceId { await outcome.unreplaced() }
                return
            }
            guard context.deviceId == fresh else { return }
            let anonymous = !joined && context.userId == nil
            if !joined {
                if anonymous {
                    context.setServerHeldUser(.known(nil))
                } else {
                    context.markServerHeldUserUnknown()
                    // A joined replacement belongs to the identify that owns it, which binds it.
                    retryIdentity.value?()
                }
            }
            await configSync.refetchAfterRegistration(
                deviceId: fresh, replaced: true, isCurrent: { !isDestroyed() && context.deviceId == fresh })
            // 🔴 After the refetch, whatever its outcome (F-1): until then the erased device's arms
            // are still applied, and a read re-armed earlier exposed them under the fresh id. Held
            // until here, such a read emits nothing; the first read after exposes the fresh arm.
            if anonymous, !isDestroyed(), context.deviceId == fresh { onAnonymousDeviceReplaced() }
        }
        return joined ? .joined : .replacing
    }

    private enum ReplacementSwap {
        case swapped
        /// The client moved to another device; the replacement is not used.
        case moved(String)
        /// A `reset()` or `destroy()` ran since the registration started.
        case superseded
    }

    /// 🔴 Under `lock`, which `rotate()` also holds while it bumps the generation, clears the
    /// registered marker and installs its placeholder: one runs entirely before the other.
    /// Otherwise a swap landing inside a rotation persisted `deviceRegistered` for the placeholder,
    /// and the next launch skipped registering an id the server never issued.
    ///
    /// The replaced id stays in the bind marker: it may hold a user for ANOTHER client whose POST is
    /// unanswered. The replacement is added when the replaced id was marked, so a `reset()` from the
    /// swap until the ladder's next `markBound` still rotates away from the device it is about to bind.
    /// 🔴 Added BEFORE the id is swapped in: `deviceMayBeBound()` does not take `lock`, so a `reset()`
    /// reading between the two would see the fresh id current and unmarked. A replacement that is then
    /// not swapped in (`.moved`) stays in the marker; it never becomes current, so it never matches.
    private func swapInReplacement(
        _ fresh: String,
        for deviceId: String,
        generation started: UInt64
    ) -> ReplacementSwap {
        lock.lock()
        defer { lock.unlock() }
        guard started == generation, !Task.isCancelled, !deps.isDestroyed() else { return .superseded }
        let context = deps.context
        let current = context.deviceId
        guard current == deviceId else { return .moved(current) }
        // Re-stamp first, then adopt, as `adopt` does: a flush between the two then sends only
        // re-stamped events (a batch carries one device id).
        // Marked before the id is written anywhere, even ahead to disk (see the doc above), and
        // persisted before any event is re-stamped to it (contract § 1, same order as the launch).
        BindMarker.insert(fresh, ifContains: deviceId, in: deps.storage)
        context.persistDeviceIdAhead(fresh)
        deps.queue.restampDeviceId(from: deviceId, to: fresh)
        deps.offlineQueue.restampDeviceId(from: deviceId, to: fresh)
        // The launch registration adopts without this lock; the compare-and-set covers it.
        deps.beforeDeviceIdChange()
        guard context.replaceDeviceId(deviceId, with: fresh) else {
            context.persistDeviceIdAhead(context.deviceId)
            return .moved(context.deviceId)
        }
        deps.policy.recordSuccess(fresh)
        return .swapped
    }

    /// Called from `reset()` after the identity is cleared (so the anonymous id is rotated) and
    /// before the config reset gate moves (so no fetch that starts after it names the old device).
    func rotate() {
        let placeholder = ContextManager.mintDeviceId()
        let context = deps.context
        // 🔴 Generation first, and all of it under `lock`: see `swapInReplacement`.
        lock.lock()
        generation &+= 1
        let current = generation
        task?.cancel()
        deps.policy.clearRegistered()
        deps.beforeDeviceIdChange()
        context.setDeviceId(placeholder)
        lock.unlock()
        deps.onDeviceIdChanged()
        // The placeholder has no row, and the device it replaces is no longer asked about.
        context.setServerHeldUser(.known(nil))
        deps.diagnostics.emit(
            .info,
            .identity,
            code: "identity.device_rotation_started",
            message: "reset() on a device a user may be bound to — registering a fresh device"
        )

        lock.lock()
        // A newer rotation (or `destroy()`) ran since the first section: its task is the gate's.
        guard generation == current else {
            lock.unlock()
            return
        }
        let newTask = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.register(placeholder: placeholder, generation: current)
        }
        task = newTask
        lock.unlock()
        // A persisted window still open: the task waits it out before its first attempt. Past
        // IDENTIFY_WAIT_BUDGET the gate is NOT armed with it, so `identify()` never waits up to 24 h;
        // a shorter window is waited out through the gate (same rule as `start()`).
        if let window = deps.policy.openWindow(), window > RegistrationPolicy.identifyWaitBudgetSeconds {
            deps.registrationGate.setTask(nil)
            return
        }
        // `identify()` and the SDK's own auto-flush triggers wait on the gate, so an identify issued
        // now binds the NEW device. The public `flush()` (and the one `reset()` itself fires) does
        // not wait: an event tracked after the logout can still be sent under the placeholder
        // before registration re-stamps the queue — the same residual a fresh install has.
        deps.registrationGate.setTask(newTask)
    }

    func cancel() {
        lock.lock()
        generation &+= 1
        task?.cancel()
        task = nil
        lock.unlock()
    }

    /// Synchronous so the lock is never taken in an async context.
    private func currentGeneration() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    private func isCurrent(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == self.generation && !Task.isCancelled && !deps.isDestroyed()
    }

    /// Registers `placeholder`, the fresh id `rotate()` switched to, by proposing it. Waits out any
    /// open backoff window first, then retries under `RegistrationPolicy` until success, a terminal
    /// answer, the launch budget, or supersession.
    private func register(placeholder: String, generation: UInt64) async {
        if let window = deps.policy.openWindow() { await sleep(seconds: window) }
        var attempts = 0
        while isCurrent(generation) {
            guard deps.policy.takeAttempt() else { return }
            attempts += 1
            let outcome = await deps.deviceManager.register(
                anonymousId: deps.context.anonymousId,
                proposedDeviceId: placeholder
            )
            guard isCurrent(generation) else {
                deps.diagnostics.emit(
                    .debug,
                    .identity,
                    code: "identity.device_registration_superseded",
                    message: "A device registration finished after the client moved on — discarded"
                )
                return
            }
            let wait: TimeInterval?
            let failure: (outcome: String, data: [String: AnyCodable])
            switch outcome {
            case .success(let deviceId):
                adopt(deviceId, replacing: placeholder, attempts: attempts)
                return
            case .transientFailure(let reason, let retryAfter):
                wait = deps.policy.recordFailure(.transient, retryAfter: retryAfter)
                failure = (reason, [:])
            case .terminalFailure(let rejection):
                // The placeholder stays — never the old device.
                wait = deps.policy.recordFailure(.terminal)
                failure = ("rejected", rejection.diagnosticData)
            case .capReached(let rejection, let retryAfter):
                wait = deps.policy.recordFailure(.cap, retryAfter: retryAfter)
                failure = ("device_cap_reached", rejection.diagnosticData)
            case .rateLimited(let retryAfter):
                wait = deps.policy.recordFailure(.rateLimited, retryAfter: retryAfter)
                failure = ("rate_limited", [:])
            }
            var data = failure.data
            data["attempt"] = AnyCodable(attempts)
            data["outcome"] = AnyCodable(failure.outcome)
            if let wait { data["retry_in_ms"] = AnyCodable(Int(wait * 1000)) }
            deps.diagnostics.emit(
                wait == nil ? .error : .warn,
                .identity,
                code: "identity.device_rotation_failed",
                message: wait == nil
                    ? "Registering the fresh device was rejected — not retried"
                    : "Registering the fresh device failed — retrying with backoff",
                data: data
            )
            guard let wait else { return }
            await sleep(seconds: wait)
        }
    }

    /// The proposal honoured (the normal case): `rotate()` already switched to it, so the
    /// registered marker is written — no re-stamp, no change callback — and config is refetched
    /// unless a body the server resolved for it already applies: every fetch since the rotation
    /// named a device with no row (`ConfigSync.refetchAfterRegistration`). Replaced
    /// by the server: the launch swap order (`SheepitClient.adoptLaunchRegistration`) — persist the
    /// id, re-stamp both queues, adopt it in memory, label the new row, then refetch its config.
    ///
    /// 🔴 Adopted by compare-and-set (SK-Q9): a second `reset()` landing after the register loop's
    /// `isCurrent` check installs its own placeholder, and a plain write clobbered it with this
    /// rotation's replaced id. The newer rotation then keeps its id, on disk too.
    private func adopt(_ deviceId: String, replacing placeholder: String, attempts: Int) {
        let context = deps.context
        let replaced = deviceId != placeholder
        if replaced {
            context.persistDeviceIdAhead(deviceId)
            deps.queue.restampDeviceId(from: placeholder, to: deviceId)
            deps.offlineQueue.restampDeviceId(from: placeholder, to: deviceId)
            deps.beforeDeviceIdChange()
            guard context.replaceDeviceId(placeholder, with: deviceId) else {
                context.persistDeviceIdAhead(context.deviceId)
                deps.diagnostics.emit(
                    .debug,
                    .identity,
                    code: "identity.device_registration_superseded",
                    message: "A device registration finished after the client moved on — discarded"
                )
                return
            }
            context.setServerHeldUser(.known(nil))
        }
        deps.policy.recordSuccess(deviceId)
        if replaced { deps.onDeviceIdChanged() }
        deps.diagnostics.emit(
            .info,
            .identity,
            code: "identity.device_rotated_on_reset",
            message: "Logged out on a bound device — now on a fresh device",
            data: ["attempts": AnyCodable(attempts), "outcome": AnyCodable(replaced ? "replaced" : "proposed")]
        )
        // Detached from the gate's task: an identify waiting on the gate need not wait for config.
        guard !deps.isDestroyed() else { return }
        let configSync = deps.configSync
        let isDestroyed = deps.isDestroyed
        let isCurrent: @Sendable () -> Bool = { !isDestroyed() && context.deviceId == deviceId }
        Task {
            await configSync.refetchAfterRegistration(
                deviceId: deviceId, replaced: replaced, isCurrent: isCurrent)
        }
    }
}
