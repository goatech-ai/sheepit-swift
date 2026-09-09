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
        os_log(.error, log: osLog, "[Sheepit] ❌ %{public}@", message)
    }
}
