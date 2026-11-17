import Foundation
import SheepitCrashHandler

/// Strict, saved v3 occurrence identity; legacy formats never borrow this launch's context.
struct CrashIdentityCohort: Sendable, Equatable {
    let userId: String?
    let deviceId: String
    let sessionId: String?
    let assignmentToken: String?
    let identityChanged: Bool

    init?(_ value: sheepit_crash_cohort_t) {
        guard value.valid == 1, value.generation & 1 == 0,
              value.has_user <= 1, value.has_session <= 1, value.reserved == 0,
              value.assignment.identity_changed <= 1,
              let user = Self.identity(value.user_id),
              let device = Self.identity(value.device_id), !device.isEmpty,
              let session = Self.identity(value.session_id),
              let token = Self.string(value.assignment.token), token.utf8.count <= 96,
              value.has_user != 0 || user.isEmpty,
              value.has_session != 0 || session.isEmpty else { return nil }
        userId = value.has_user == 0 ? nil : user
        deviceId = device
        sessionId = value.has_session == 0 ? nil : session
        assignmentToken = token.isEmpty ? nil : token
        identityChanged = value.assignment.identity_changed != 0
    }

    private static func identity<T>(_ tuple: T) -> String? {
        guard let text = string(tuple), text.utf16.count <= SDKDefaults.userIdMaxLength else { return nil }
        return text
    }

    private static func string<T>(_ tuple: T) -> String? {
        withUnsafeBytes(of: tuple) { bytes in
            guard let end = bytes.firstIndex(of: 0), bytes[end...].allSatisfy({ $0 == 0 }) else { return nil }
            return String(bytes: bytes[..<end], encoding: .utf8)
        }
    }
}

/// Distinguishes an older report from a claimed but invalid/unavailable v3 cohort.
enum CrashIdentityCapture: Sendable {
    case legacy
    case coherent(CrashIdentityCohort)
    case unavailable

    var cohort: CrashIdentityCohort? {
        if case .coherent(let value) = self { return value }
        return nil
    }
    var outcome: String {
        switch self { case .legacy: return "legacy"; case .coherent: return "coherent"; case .unavailable: return "unavailable" }
    }
    static func read(path: String, timestamp: UInt64, imageCount: Int) -> Self {
        var raw = sheepit_crash_cohort_t()
        let outcome = sheepit_read_crash_cohort(path, timestamp, UInt32(clamping: imageCount), &raw)
        if outcome == SHEEPIT_COHORT_LEGACY { return .legacy }
        guard outcome == SHEEPIT_COHORT_COHERENT, let cohort = CrashIdentityCohort(raw) else { return .unavailable }
        return .coherent(cohort)
    }
}

extension CrashReporter {
    /// Call only within the client's exposure gate; this method never calls back into it or host code.
    @discardableResult
    nonisolated func publishIdentity(
        _ snapshot: EventContextSnapshot, assignmentToken: String? = nil, identityChanged: Bool = false
    ) -> Bool {
        var published = false
        contextWrites.perform {
            guard let ctx = sheepit_get_crash_context() else { return }
            let strings = [snapshot.userId, snapshot.deviceId, snapshot.sessionId, assignmentToken]
            guard !strings.contains(where: { $0?.contains("\0") == true }) else {
                sheepit_crash_cohort_set(nil, nil, nil, nil, false)
                return
            }
            published = Self.withCString(snapshot.userId) { user in
                snapshot.deviceId.withCString { device in
                    Self.withCString(snapshot.sessionId) { session in
                        Self.withCString(assignmentToken) { token in
                            sheepit_crash_cohort_set(user, device, session, token, identityChanged)
                        }
                    }
                }
            }
            // Frozen fields retain their historical representation for older readers.
            writeString(snapshot.userId ?? "", to: &ctx.pointee.user_id)
            writeString(snapshot.deviceId, to: &ctx.pointee.device_id)
            writeString(snapshot.sessionId ?? "", to: &ctx.pointee.session_id)
            ctx.pointee.magic = UInt32(SHEEPIT_CRASH_CONTEXT_MAGIC)
        }
        return published
    }

    /// Called after exposure/context locks are released; diagnostics may invoke host listeners.
    nonisolated func recordIdentityPublication(_ published: Bool) {
        diagnostics?.emit(
            .debug, .identity,
            code: "identity.crash_cohort",
            message: "Updated the crash occurrence identity.",
            data: ["outcome": AnyCodable(published ? "published" : "unavailable")]
        )
    }

    private nonisolated static func withCString<T>(
        _ text: String?, _ body: (UnsafePointer<CChar>?) -> T
    ) -> T {
        if let text { return text.withCString(body) }
        return body(nil)
    }
}
