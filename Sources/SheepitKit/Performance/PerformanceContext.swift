import Foundation

/// The per-process parts of a context: bundle, hardware, OS and region do not change under a running
/// process, and a capture runs per slow frame on main, so they are computed once per `appVersion` override.
private enum PerfProcessConstants {
    struct Values: Sendable { let appVersion: String?; let buildNumber: String?; let country: String? }
    private static let cache = LockedValue<[String: Values]>([:])

    static func values(appVersion: String?) -> Values {
        let key = appVersion.map { "v" + $0 } ?? "n"
        if let hit = cache.value[key] { return hit }
        let made = Values(appVersion: DeviceProfile.wireAppVersion(override: appVersion),
            buildNumber: DeviceProfile.wireBuildNumber(),
            country: TrackSnapshot.countryCode(Locale.current.region?.identifier))
        cache.value[key] = made
        return made
    }
}

/// Complete occurrence context; P5 replaces the batch context with each metric's override.
extension PerfBatchContext {
    /// A contended sampling gate leaves the metric wholly unattributed, without waiting.
    static func unattributed(appVersion: String?) -> PerfBatchContext {
        let constants = PerfProcessConstants.values(appVersion: appVersion)
        return PerfBatchContext(platform: DeviceProfile.platform,
            appVersion: constants.appVersion,
            buildNumber: constants.buildNumber, osVersion: DeviceProfile.osVersion(),
            deviceModel: DeviceProfile.deviceModel(), userId: nil, sessionId: nil, deviceId: nil,
            country: nil, networkType: nil, activeFlags: nil)
    }

    static func capture(_ ctx: EventContextSnapshot, appVersion: String?, receipt: AssignmentReceipt) -> PerfBatchContext {
        let constants = PerfProcessConstants.values(appVersion: appVersion)
        var result = PerfBatchContext(
            platform: ctx.platform,
            appVersion: constants.appVersion,
            buildNumber: constants.buildNumber,
            osVersion: DeviceProfile.osVersion(),
            deviceModel: DeviceProfile.deviceModel(),
            userId: ctx.userId,
            sessionId: ctx.sessionId,
            deviceId: ctx.deviceId,
            country: constants.country,
            networkType: nil,
            activeFlags: nil
        )
        result.assignmentToken = receipt.token
        result.assignmentStatus = receipt.status
        return result
    }

    /// Same user and device: what a receipt is bound to. The session rolls on its own clock and is not identity.
    /// A `live` context with no device (everything was contended) is an unknown identity, which is
    /// never "the same": whatever was captured ships with no receipt.
    func sameIdentity(as live: PerfBatchContext) -> Bool {
        guard let liveDevice = live.deviceId else { return false }
        return userId == live.userId && deviceId == liveDevice
    }

    /// The same measurement with no user, session, device or receipt.
    func anonymized() -> PerfBatchContext {
        var copy = withoutReceipt()
        copy.userId = nil; copy.sessionId = nil; copy.deviceId = nil
        return copy
    }

    /// This occurrence's measurements under the live identity, claiming no assignment: how a
    /// cumulative window ships once the identity it was captured under is gone.
    func withoutReceipt() -> PerfBatchContext {
        var copy = self
        copy.assignmentToken = nil
        copy.assignmentStatus = nil
        return copy
    }
}

/// Advances when the identity a captured performance context belongs to goes away (`reset()`). Anything captured under an older value must not outlive it:
/// open spans, the cumulative frame window, a pending warm start. A leaf lock: safe to advance
/// from inside the decision gate.
final class IdentityEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var resets: UInt64 = 0
    private var windows: UInt64 = 0

    /// Moves on `reset()` and a device-id change: ends open spans and an ANR freeze context.
    var current: UInt64 { lock.lock(); defer { lock.unlock() }; return resets }
    /// Moves on everything `current` does AND on `identify()` of another user: cumulative windows
    /// (frame summary, warm start) restart. A span started under one user keeps that user.
    var window: UInt64 { lock.lock(); defer { lock.unlock() }; return windows }
    func advance() { lock.lock(); resets &+= 1; windows &+= 1; lock.unlock() }
    func advanceWindow() { lock.lock(); windows &+= 1; lock.unlock() }
}

/// Counts gate-contended samples so the diagnostic is logarithmic, not one event per slow frame.
final class SamplingContentionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// The running count, and whether it is a power of two (the occurrences worth reporting).
    func record() -> (count: Int, report: Bool) {
        lock.lock(); defer { lock.unlock() }
        count += 1
        return (count, count & (count - 1) == 0)
    }
}

extension PerfBatchContext {
    /// The production sampling closure. Never waits: a contended decision gate or experiment lock
    /// ships the identity WITHOUT a receipt (a null token claims no assignment), a contended context
    /// lock ships it wholly unattributed. Either way the drop is counted on the diagnostic bus.
    static func sample(
        gate: ExposureDecisionGate, context: ContextManager, experiments: ExperimentManager,
        appVersion: String?, diagnostics: DiagnosticBus, contention: SamplingContentionCounter
    ) -> PerfBatchContext {
        let gated: PerfBatchContext? = gate.tryWithLock {
            guard let snapshot = context.tryEventContext(),
                  let receipt = experiments.tryReceipt(eventUserId: snapshot.userId) else { return nil }
            return capture(snapshot, appVersion: appVersion, receipt: receipt)
        }
        if let gated { return gated }
        let seen = contention.record()
        if seen.report {
            // `.identity` is reused on purpose: `DiagnosticCategory` is public, and a new case would
            // break customers' exhaustive switches. Off the sampling path: subscribers are host
            // callbacks, and this runs on main per slow frame.
            DispatchQueue.global(qos: .utility).async {
            diagnostics.emit(.info, .identity, code: "performance.context_sampling_contended",
                message: "performance context sampled without a receipt: a lock was contended",
                data: ["count": AnyCodable(seen.count)])
            }
        }
        guard let snapshot = context.tryEventContext() else { return unattributed(appVersion: appVersion) }
        return capture(snapshot, appVersion: appVersion, receipt: AssignmentReceipt())
    }
}
