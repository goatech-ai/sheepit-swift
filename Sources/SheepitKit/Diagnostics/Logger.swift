import Foundation
import os.log

/// Internal logger — outputs only when debug mode is enabled.
final class Logger: Sendable {
    private let isDebug: Bool
    private let osLog = OSLog(subsystem: "ai.goatech.sdk", category: "SDK")

    init(debug: Bool) {
        self.isDebug = debug
    }

    func debug(_ message: String, _ context: Any?...) {
        guard isDebug else { return }
        os_log(.debug, log: osLog, "[Sheepit] %{public}@", message)
    }

    func warn(_ message: String, _ context: Any?...) {
        os_log(.default, log: osLog, "[Sheepit] ⚠️ %{public}@", message)
    }

    func error(_ message: String, _ context: Any?...) {
        // %{private}@ — error messages can carry host/attacker-influenced strings (e.g. a
        // rejected apiUrl's rejection reason), and the redaction regex protecting that one
        // string has already had an under-redaction bug of its own
        // (`SheepitClient.redactingUserinfo`, 2026-09 security follow-up round 3, finding
        // SF-1). Default to NOT dumping error content into the unredacted unified log /
        // sysdiagnose rather than trusting every caller to have already sanitized it.
        os_log(.error, log: osLog, "[Sheepit] ❌ %{private}@", message)
    }
}
