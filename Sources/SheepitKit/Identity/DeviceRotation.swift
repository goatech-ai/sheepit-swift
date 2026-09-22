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
/// row counts against the metered device total. A rotation clears the marker, so a `reset()` while
/// its registration is pending keeps the pending device: no identify can have been sent for it,
/// since identify waits for registration (`RegistrationGate`).
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

    /// Whether `reset()` must rotate, read BEFORE anything is cleared. See the type doc.
    func deviceMayBeBound() -> Bool {
        if deps.storage.string(forKey: StorageKeys.deviceBindAttempted) != nil { return true }
        if case .known(let userId?) = deps.context.serverHeldUser.user, !userId.isEmpty { return true }
        return false
    }

    /// Record, BEFORE an identify POST is sent for `deviceId`, that its row may hold a user.
    func markBindAttempted(deviceId: String) {
        deps.storage.set(deviceId, forKey: StorageKeys.deviceBindAttempted)
    }

    /// Called from `reset()` after the identity is cleared (so the anonymous id is rotated) and
    /// before the config reset gate moves (so no fetch that starts after it names the old device).
    func rotate() {
        let placeholder = UUID().uuidString
        let context = deps.context
        deps.storage.removeObject(forKey: StorageKeys.deviceRegistered)
        deps.storage.removeObject(forKey: StorageKeys.deviceBindAttempted)
        context.setDeviceId(placeholder)
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
        generation &+= 1
        let current = generation
        task?.cancel()
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
        deps.storage.set("1", forKey: StorageKeys.deviceRegistered)
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
