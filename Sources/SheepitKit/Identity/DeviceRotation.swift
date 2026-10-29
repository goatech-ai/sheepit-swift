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
/// **How.** Synchronously in `reset()`: a locally minted placeholder id replaces the old one (so
/// no request after the logout names the old device), and the label becomes `.known(nil)`. Then
/// the device is registered with no id, so the server mints one, under the rotated anonymous id —
/// the same path a fresh install takes, including re-stamping queued events from the
/// placeholder. A failed registration is retried with backoff and never falls back to the old id;
/// until it succeeds, config fetched under the placeholder resolves no row and evaluates
/// anonymously.
final class DeviceRotation: @unchecked Sendable {
    struct Dependencies {
        let context: ContextManager
        let deviceManager: DeviceManager
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
    }

    private let deps: Dependencies
    private let lock = NSLock()
    /// Bumped by every rotation and by `cancel()`. A registration from an older generation adopts
    /// nothing.
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?
    private var _retryDelayOverride: (@Sendable (Int) -> Duration)?

    init(_ deps: Dependencies) {
        self.deps = deps
    }

    /// Test-only: replaces `retryDelay(afterFailures:)`.
    var retryDelayOverride: (@Sendable (Int) -> Duration)? {
        get { lock.lock(); defer { lock.unlock() }; return _retryDelayOverride }
        set { lock.lock(); _retryDelayOverride = newValue; lock.unlock() }
    }

    /// 1 s doubling to a 60 s ceiling.
    static func retryDelay(afterFailures failures: Int) -> Duration {
        .seconds(min(1 << min(failures, 6), 60))
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
    /// Nothing is registered while a persisted backoff window is open, and a cap, a terminal refusal
    /// or a 429 writes one, so a fleet of unknown devices cannot hammer the environment. The id is
    /// server-minted, as for a rotation: re-registering the old one would resurrect an erased device.
    ///
    /// One attempt (`maxAttempts: 1`): the identify chain waits on this.
    func replaceUnknown(_ deviceId: String) async -> String? {
        let context = deps.context
        guard !deps.isDestroyed() else { return nil }
        // Already moved off it. After a `reset()` the ladder stops anyway (`isCurrent`); after the
        // launch registration adopted its own id, that is the device to bind.
        let inUse = context.deviceId
        if inUse != deviceId { return inUse }
        if RegistrationBackoff.isActive(storage: deps.storage, now: deps.now()) {
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
        let started = currentGeneration()
        let outcome = await deps.deviceManager.register(
            anonymousId: context.anonymousId,
            existingDeviceId: nil,
            maxAttempts: 1
        )
        let failure: (outcome: String, data: [String: AnyCodable])
        switch outcome {
        case .success(let fresh):
            switch swapInReplacement(fresh, for: deviceId, generation: started) {
            case .swapped:
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
        case .transientFailure:
            failure = ("transient", [:])
        case .terminalFailure(let rejection):
            RegistrationBackoff.record(storage: deps.storage, now: deps.now())
            failure = ("rejected", rejection.diagnosticData)
        case .capReached(let rejection):
            RegistrationBackoff.record(
                storage: deps.storage,
                now: deps.now(),
                duration: SDKDefaults.deviceRegistrationCapBackoff
            )
            failure = ("device_cap_reached", rejection.diagnosticData)
        case .rateLimited(let retryAfter):
            // Persisted, unlike `register(placeholder:generation:)`: that loop paces itself, but a
            // replacement is one request, and the retry tick that re-runs the ladder also fires on
            // every reconnect. Same as sdk-js (`persistBackoffUntil` on `rate_limited`).
            let wait = RegistrationRetryPolicy.delay(afterFailures: 0, retryAfter: retryAfter).components
            RegistrationBackoff.record(
                storage: deps.storage,
                now: deps.now(),
                duration: TimeInterval(wait.seconds) + TimeInterval(wait.attoseconds) / 1e18
            )
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
        deps.queue.restampDeviceId(from: deviceId, to: fresh)
        deps.offlineQueue.restampDeviceId(from: deviceId, to: fresh)
        BindMarker.insert(fresh, ifContains: deviceId, in: deps.storage)
        // The launch registration adopts without this lock; the compare-and-set covers it.
        guard context.replaceDeviceId(deviceId, with: fresh) else { return .moved(context.deviceId) }
        deps.storage.set(fresh, forKey: StorageKeys.deviceRegistered)
        RegistrationBackoff.clear(storage: deps.storage)
        return .swapped
    }

    /// Called from `reset()` after the identity is cleared (so the anonymous id is rotated) and
    /// before the config reset gate moves (so no fetch that starts after it names the old device).
    func rotate() {
        let placeholder = UUID().uuidString
        let context = deps.context
        // 🔴 Generation first, and all of it under `lock`: see `swapInReplacement`.
        lock.lock()
        generation &+= 1
        let current = generation
        task?.cancel()
        deps.storage.removeObject(forKey: StorageKeys.deviceRegistered)
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

    private func register(placeholder: String, generation: UInt64) async {
        var failures = 0
        while isCurrent(generation) {
            let outcome = await deps.deviceManager.register(
                anonymousId: deps.context.anonymousId,
                existingDeviceId: nil
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
            switch outcome {
            case .success(let deviceId):
                adopt(deviceId, replacing: placeholder, attempts: failures + 1)
                return
            case .transientFailure:
                failures += 1
                let delay = retryDelayOverride?(failures - 1) ?? Self.retryDelay(afterFailures: failures - 1)
                deps.diagnostics.emit(
                    .warn,
                    .identity,
                    code: "identity.device_rotation_failed",
                    message: "Registering the fresh device failed — retrying with backoff",
                    data: [
                        "attempt": AnyCodable(failures),
                        "outcome": AnyCodable("retrying"),
                        "retry_in_ms": AnyCodable(Int(delay / .milliseconds(1))),
                    ]
                )
                try? await Task.sleep(for: delay)
            case .terminalFailure(let rejection):
                // Same backoff marker `start()` writes: the next launches do not hammer a revoked
                // key. The placeholder stays — never the old device.
                // (`isCurrent` above is this path's supersession guard.)
                RegistrationBackoff.record(storage: deps.storage, now: deps.now())
                deps.diagnostics.emit(
                    .error,
                    .identity,
                    code: "identity.device_rotation_failed",
                    message: "Registering the fresh device was rejected (\(rejection.statusCode)) — not retried",
                    data: rejection.diagnosticData.merging([
                        "attempt": AnyCodable(failures + 1),
                        "outcome": AnyCodable("rejected"),
                    ]) { _, new in new }
                )
                return
            case .capReached(let rejection):
                // Fix round 1 (PR #1170 review), item 15: unlike `.terminalFailure`, this
                // does NOT give up — it keeps retrying, just on the LONGER, jittered,
                // `RegistrationRetryPolicy` schedule (up to 1h) instead of the ≤60s transient
                // one, since a cap/rate-limit condition is not this device's fault and can
                // clear on its own. `RegistrationBackoff` is still written on every occurrence
                // (harmless to repeat) so a kill-and-relaunch mid-wait doesn't hammer either.
                failures += 1
                RegistrationBackoff.record(
                    storage: deps.storage,
                    now: deps.now(),
                    duration: SDKDefaults.deviceRegistrationCapBackoff
                )
                let delay = RegistrationRetryPolicy.delay(afterFailures: failures - 1, retryAfter: nil)
                deps.diagnostics.emit(
                    .warn,
                    .identity,
                    code: "identity.device_rotation_failed",
                    message: "Registering the fresh device was rejected (\(rejection.statusCode), cap reached) — retrying with backoff",
                    data: rejection.diagnosticData.merging([
                        "attempt": AnyCodable(failures),
                        "outcome": AnyCodable("device_cap_reached"),
                        "retry_in_ms": AnyCodable(Int(delay / .milliseconds(1))),
                    ]) { _, new in new }
                )
                try? await Task.sleep(for: delay)
            case .rateLimited(let retryAfter):
                // Same shape as `.capReached` above, but the delay honors the server's own
                // `Retry-After` when it asks for longer than the jittered exponential value.
                //
                // Fix round 2 (PR #1170 review), item 12: unlike `.capReached`, this does NOT
                // call `RegistrationBackoff.record` — a 429 is the network/gateway telling this
                // client to slow down, not a durable capacity fact about the environment the
                // way a 402/422 is. Persisting the 1h cap window here would gate the NEXT cold
                // start and `retryIdentityIfUnknown()` on a condition that may already have
                // cleared by the time either runs. The in-session retry loop above already
                // paces itself with `RegistrationRetryPolicy`; nothing durable needs to survive
                // a reload for this outcome, same as `.transientFailure`.
                failures += 1
                let delay = RegistrationRetryPolicy.delay(afterFailures: failures - 1, retryAfter: retryAfter)
                deps.diagnostics.emit(
                    .warn,
                    .identity,
                    code: "identity.device_rotation_failed",
                    message: "Registering the fresh device was rate limited (429) — retrying with backoff",
                    data: [
                        "attempt": AnyCodable(failures),
                        "outcome": AnyCodable("rate_limited"),
                        "retry_in_ms": AnyCodable(Int(delay / .milliseconds(1))),
                    ]
                )
                try? await Task.sleep(for: delay)
            }
        }
    }

    /// The fresh-install adoption order (`SheepitClient.start()`): re-stamp both queues first, so a
    /// flush between these statements sends only re-stamped events, then adopt the id.
    private func adopt(_ deviceId: String, replacing placeholder: String, attempts: Int) {
        let context = deps.context
        deps.queue.restampDeviceId(from: placeholder, to: deviceId)
        deps.offlineQueue.restampDeviceId(from: placeholder, to: deviceId)
        context.setServerHeldUser(.known(nil))
        context.setDeviceId(deviceId)
        deps.storage.set(deviceId, forKey: StorageKeys.deviceRegistered)
        RegistrationBackoff.clear(storage: deps.storage)
        deps.onDeviceIdChanged()
        deps.diagnostics.emit(
            .info,
            .identity,
            code: "identity.device_rotated_on_reset",
            message: "Logged out on a bound device — now on a fresh device",
            data: ["attempts": AnyCodable(attempts)]
        )
        // Detached from the gate's task: an identify waiting on the gate need not wait for config.
        let configSync = deps.configSync
        Task { await configSync.refetchUnconditionally(deviceId: deviceId) }
    }
}
