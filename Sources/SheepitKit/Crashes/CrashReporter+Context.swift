import Foundation
import SheepitCrashHandler
#if os(iOS) || os(tvOS) || os(watchOS)
import os
#endif

/// The writers that mirror SDK state into the mmap'd crash context between crashes. Each is a
/// plain store into the mapped struct, safe from any thread; the next launch reads it back
/// through `CrashReportReader`. Every one runs inside `contextWrites`, which `stop()` closes
/// before the context is unmapped: a check of `sheepit_get_crash_context()` alone races the
/// `munmap`. Lock order is `AppForegroundState`'s lock, then the gate — never the reverse.
extension CrashReporter {
    /// Update the screen name in the crash context.
    nonisolated func setScreen(_ name: String) {
        contextWrites.perform {
            guard let ctx = sheepit_get_crash_context() else { return }
            writeString(name, to: &ctx.pointee.screen_name)
        }
    }

    /// Update the foreground state in the crash context. A plain one-byte store into the mapped
    /// struct, which the signal handler never writes and the next launch reads back. Called by
    /// `AppForegroundState` on every transition, under its lock.
    nonisolated func setForeground(_ isForeground: Bool) {
        contextWrites.perform {
            guard let ctx = sheepit_get_crash_context() else { return }
            ctx.pointee.is_foreground = isForeground
        }
    }

    /// Write the flag values the app is running with into the crash context's 4 KB buffer.
    /// Called on every config apply, override change and reset (`SheepitClient`).
    nonisolated func setFlagState(_ flags: [String: AnyCodable]) {
        let json = Self.boundedJSONObject(flags, maxBytes: Self.contextJSONBytes)
        contextWrites.perform {
            guard let ctx = sheepit_get_crash_context() else { return }
            writeString(json, to: &ctx.pointee.active_flags_json)
        }
    }

    /// `active_flags_json` / `active_experiments_json` are `char[4096]`; one byte is the NUL.
    static let contextJSONBytes = MemoryLayout.size(ofValue: sheepit_crash_context_t().active_flags_json) - 1

    /// Write the experiment arms (experiment key → variant key) into the crash context.
    nonisolated func setExperimentState(_ experiments: [String: AnyCodable]) {
        let json = Self.boundedJSONObject(experiments, maxBytes: Self.contextJSONBytes)
        contextWrites.perform {
            guard let ctx = sheepit_get_crash_context() else { return }
            writeString(json, to: &ctx.pointee.active_experiments_json)
        }
    }

    /// `values` as a JSON object of at most `maxBytes` UTF-8 bytes that is always valid: entries
    /// in key order, each kept whole when it still fits and skipped when it does not. A byte cut
    /// of the full object would leave invalid JSON, which the reader drops — every flag lost.
    /// Deterministic: the same map always yields the same object.
    static func boundedJSONObject(_ values: [String: AnyCodable], maxBytes: Int) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var parts: [String] = []
        var used = 2  // the braces
        for key in values.keys.sorted() {
            guard let value = values[key],
                  let data = try? encoder.encode([key: value]),
                  let object = String(data: data, encoding: .utf8),
                  object.count > 2
            else { continue }
            let entry = String(object.dropFirst().dropLast())  // "key":value
            let cost = entry.utf8.count + (parts.isEmpty ? 0 : 1)
            guard used + cost <= maxBytes else { continue }
            parts.append(entry)
            used += cost
        }
        return "{" + parts.joined(separator: ",") + "}"
    }

    /// Sample available memory into `free_memory_mb`.
    nonisolated func refreshFreeMemory() {
        writeFreeMemory(Self.availableMemoryMB())
    }

    /// Store `mb` while `contextWrites` is open. The sampling task and the memory-warning block run
    /// on other threads and can be mid-call when `stop()` begins; `stop()` closes the gate first,
    /// which waits for a write in progress, so none lands after the context is unmapped.
    nonisolated func writeFreeMemory(_ mb: UInt32?) {
        guard let mb else { return }
        contextWrites.perform {
            guard let ctx = sheepit_get_crash_context() else { return }
            ctx.pointee.free_memory_mb = mb
        }
    }

    /// Memory the process may still allocate before the OS kills it, in MB; nil where
    /// `os_proc_available_memory()` does not exist (macOS). iOS 13+, so within the iOS 16 floor.
    static func availableMemoryMB() -> UInt32? {
        #if os(iOS) || os(tvOS) || os(watchOS)
        return UInt32(clamping: os_proc_available_memory() / (1024 * 1024))
        #else
        return nil
        #endif
    }

    /// Add a breadcrumb. Thread-safe (the C layer uses atomic writes).
    nonisolated func addBreadcrumb(category: String, message: String) {
        contextWrites.perform { sheepit_add_breadcrumb(category, message) }
    }

    // MARK: - Helpers

    /// Write a Swift string into a C fixed-size char array, cut on a whole character: a
    /// byte-wise cut could split a multi-byte character and read back as U+FFFD.
    nonisolated func writeString<T>(_ string: String, to dest: inout T) {
        withUnsafeMutablePointer(to: &dest) { ptr in
            let size = MemoryLayout<T>.size
            ptr.withMemoryRebound(to: CChar.self, capacity: size) { cstr in
                DeviceProfile.boundedUTF8(string, size - 1).withCString { src in
                    let len = min(strlen(src), size - 1)
                    memcpy(cstr, src, len)
                    cstr[len] = 0
                }
            }
        }
    }
}

/// A latch around writes into the mapped crash context from threads the reporter does not own.
final class CrashContextWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private enum State { case uninstalled, open, closed }
    private var state = State.uninstalled

    var canInstall: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .uninstalled
    }

    /// Only the reporter that successfully installed the native handler activates this gate.
    func activate() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard state == .uninstalled else { return false }
        state = .open
        return true
    }

    /// Run `body` under the lock, unless the gate is closed.
    func perform(_ body: () -> Void) {
        lock.lock()
        defer { lock.unlock() }
        if state == .open { body() }
    }

    /// Close for good; returns once any `perform` in progress has finished.
    func close() {
        lock.lock()
        state = .closed
        lock.unlock()
    }
}
