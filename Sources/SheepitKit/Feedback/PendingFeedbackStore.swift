import Foundation

/// On-disk queue of feedback waiting to be delivered (`FeedbackSender`). Modelled on
/// `PendingCrashStore`; not `OfflineQueue`, which keeps JSON events in `UserDefaults` and could not
/// hold up to 3 MiB of images per item.
///
/// One directory per storage scope (`StorageScope.hash`) under `baseDirectory`, so feedback written
/// under one apiUrl, environment and key is never sent with another's. One subdirectory per item,
/// `<firstSeenMs>_<id>`, holding `payload.json` and `screenshot-<n>.<jpg|png>`: written under a
/// `.tmp-` name and renamed into place, so a half-written item is never read. Next to the items,
/// `notBeforeFile` holds the retry floor (`Retry-After` / backoff) so a relaunch honours it. In
/// Application Support (Caches can be purged while an item waits), excluded from backup, files
/// written with `completeUntilFirstUserAuthentication` protection where the platform has it.
///
/// Every operation holds ONE process-wide lock, and `generation` is ONE process-wide counter,
/// shared by every store (each `SheepitClient` builds its own, one per key). So `clear()` — any
/// client's `reset()`, from any thread — cannot interleave with another client's write: an item
/// written for the logged-out user either lands before the clear and is deleted by it, or sees the
/// bumped generation and is not written at all. Likewise the start-time reaper cannot delete a
/// directory between another client's `createDirectory` and its rename, nor between its own
/// listing and delete. 🔴 Per PROCESS only: an app extension sharing the container would need a
/// file lock (queued in PENDING_WORK.md).
final class PendingFeedbackStore: @unchecked Sendable {
    struct Entry: Sendable, Equatable {
        let url: URL
        let id: String
        let firstSeen: Date
    }

    let directory: URL
    /// The parent of every scope's directory. Nil for a store that must never touch its siblings
    /// (tests that hand it a bare temp directory).
    let baseDirectory: URL?
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _generation: UInt64 = 0
    private var lock: NSLock { Self.lock }

    init(directory: URL, baseDirectory: URL? = nil) {
        self.directory = directory
        self.baseDirectory = baseDirectory
    }

    /// `<Application Support>/ai.goatech.sdk/feedback`, or a per-run temp directory when XCTest is
    /// loaded (same reasoning as `PendingCrashStore.defaultDirectory()`: no test may read or send
    /// a developer's real queue). The scope subdirectory is appended by the caller.
    static func defaultBaseDirectory() -> URL {
        guard NSClassFromString("XCTestCase") != nil else {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            return base.appendingPathComponent("ai.goatech.sdk/feedback", isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent(
            "ai.goatech.sdk-xctest-\(ProcessInfo.processInfo.processIdentifier)-\(xctestRunID)/feedback",
            isDirectory: true
        )
    }

    private static let xctestRunID = UUID().uuidString
    static let notBeforeFile = "not-before"
    private static let payloadFile = "payload.json"

    /// Queued files may be read while the device is locked (a background drain), but not before the
    /// first unlock after a reboot. macOS has no per-file data protection classes to ask for.
    private static let writeOptions: Data.WritingOptions = {
        #if os(macOS)
        return []
        #else
        return .completeFileProtectionUntilFirstUserAuthentication
        #endif
    }()

    /// Bumped by every store's `clear()` in the process. A sender that read it before an `await`
    /// compares again after.
    var generation: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return Self._generation
    }

    /// Writes `submission` as a new item, then deletes the oldest others so at most `maxItems`
    /// remain. Nothing is written when `clear()` ran since `generation` was read. `entry` is nil
    /// when nothing was written.
    func enqueue(
        _ submission: FeedbackSubmission,
        now: Date,
        ifGeneration generation: UInt64,
        maxItems: Int
    ) -> (entry: Entry?, evicted: [Entry]) {
        lock.lock(); defer { lock.unlock() }
        guard generation == Self._generation else { return (nil, []) }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            for var url in [baseDirectory, directory].compactMap({ $0 }) {
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? url.setResourceValues(values)
            }

            let id = UUID().uuidString
            // Strictly after the newest item, so two written in one millisecond (or after a clock
            // step back) still drain in the order they were written, not in UUID order.
            let newest = unlockedEntries().last.map { Int64(($0.firstSeen.timeIntervalSince1970 * 1000).rounded()) }
            let ms = max(Int64((now.timeIntervalSince1970 * 1000).rounded()), (newest ?? .min) + 1)
            let temp = directory.appendingPathComponent(".tmp-\(id)", isDirectory: true)
            let final = directory.appendingPathComponent("\(ms)_\(id)", isDirectory: true)
            try fm.createDirectory(at: temp, withIntermediateDirectories: false)
            do {
                try submission.payload.write(to: temp.appendingPathComponent(Self.payloadFile), options: Self.writeOptions)
                for (index, screenshot) in submission.screenshots.enumerated() {
                    try screenshot.data.write(
                        to: temp.appendingPathComponent("screenshot-\(index).\(screenshot.fileExtension)"),
                        options: Self.writeOptions
                    )
                }
                try fm.moveItem(at: temp, to: final)
            } catch {
                try? fm.removeItem(at: temp)
                throw error
            }
            let entry = Entry(url: final, id: id, firstSeen: Date(timeIntervalSince1970: Double(ms) / 1000))
            let others = unlockedEntries().filter { $0.id != id }
            let evicted = Array(others.prefix(max(0, others.count - (max(1, maxItems) - 1))))
            evicted.forEach { try? fm.removeItem(at: $0.url) }
            return (entry, evicted)
        } catch {
            return (nil, [])
        }
    }

    /// Every queued item, oldest first. Anything else in the directory (a `.tmp-` left by a
    /// process killed mid-write, a name this code did not write) is deleted.
    func entries() -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return unlockedEntries()
    }

    /// The item's payload and images; nil when it can no longer be read as one.
    func load(_ entry: Entry) -> FeedbackSubmission? {
        lock.lock(); defer { lock.unlock() }
        let fm = FileManager.default
        guard let payload = try? Data(contentsOf: entry.url.appendingPathComponent(Self.payloadFile)),
              let names = try? fm.contentsOfDirectory(atPath: entry.url.path)
        else { return nil }
        var indexed: [(Int, String)] = []
        for name in names where name != Self.payloadFile {
            guard name.hasPrefix("screenshot-"),
                  let index = Int(name.dropFirst("screenshot-".count).prefix { $0.isNumber })
            else { return nil }
            indexed.append((index, name))
        }
        var screenshots: [SheepitFeedbackScreenshot] = []
        for (_, name) in indexed.sorted(by: { $0.0 < $1.0 }) {
            guard let data = try? Data(contentsOf: entry.url.appendingPathComponent(name)),
                  let screenshot = SheepitFeedbackScreenshot(data: data)
            else { return nil }
            screenshots.append(screenshot)
        }
        return FeedbackSubmission(payload: payload, screenshots: screenshots)
    }

    func remove(_ entry: Entry) {
        lock.lock(); defer { lock.unlock() }
        try? FileManager.default.removeItem(at: entry.url)
    }

    /// The persisted retry floor, if any.
    func loadNotBefore() -> Date? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(Self.notBeforeFile)),
              let seconds = Double(String(decoding: data, as: UTF8.self)), seconds.isFinite
        else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Persists (or, for nil, removes) the retry floor. Only while the scope directory exists: with
    /// nothing queued there is nothing for a later launch to hold back. Nothing is written when any
    /// store's `clear()` ran since `generation` was read.
    func saveNotBefore(_ date: Date?, ifGeneration generation: UInt64) {
        lock.lock(); defer { lock.unlock() }
        guard generation == Self._generation else { return }
        let url = directory.appendingPathComponent(Self.notBeforeFile)
        guard let date else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try? Data(String(date.timeIntervalSince1970).utf8).write(to: url, options: Self.writeOptions)
    }

    /// Deletes every queued item and invalidates any write in flight. With a `baseDirectory`, every
    /// OTHER scope's queue goes too: `reset()` means forgetting this user under every key.
    func clear() {
        lock.lock(); defer { lock.unlock() }
        Self._generation &+= 1
        try? FileManager.default.removeItem(at: directory)
        if let baseDirectory {
            try? FileManager.default.removeItem(at: baseDirectory)
        }
    }

    /// Deletes the other scopes' directories (an old key, environment or apiUrl) once nothing in
    /// them can still be sent: every item is older than `maxAge`, or there is none. A directory
    /// with a write in progress (`.tmp-`) is left alone. Best effort; returns the scopes deleted.
    /// The lock is held for each scope's list-then-delete, never across scopes.
    @discardableResult
    func reapStrandedScopes(now: Date, maxAge: TimeInterval) -> [String] {
        guard let baseDirectory else { return [] }
        let fm = FileManager.default
        guard let scopes = try? fm.contentsOfDirectory(atPath: baseDirectory.path) else { return [] }
        var reaped: [String] = []
        for scope in scopes where scope != directory.lastPathComponent {
            lock.lock(); defer { lock.unlock() }
            let url = baseDirectory.appendingPathComponent(scope, isDirectory: true)
            let names = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
            guard !names.contains(where: { $0.hasPrefix(".tmp-") }) else { continue }
            let items = names.compactMap { Self.parse(name: $0, in: url) }
            guard items.allSatisfy({ now.timeIntervalSince($0.firstSeen) > maxAge }) else { continue }
            if (try? fm.removeItem(at: url)) != nil { reaped.append(scope) }
        }
        return reaped
    }

    private static func parse(name: String, in directory: URL) -> Entry? {
        let parts = name.split(separator: "_", maxSplits: 1)
        guard parts.count == 2, let ms = Int64(parts[0]), !parts[1].isEmpty else { return nil }
        return Entry(
            url: directory.appendingPathComponent(name, isDirectory: true),
            id: String(parts[1]),
            firstSeen: Date(timeIntervalSince1970: Double(ms) / 1000)
        )
    }

    private func unlockedEntries() -> [Entry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var result: [Entry] = []
        for name in names where name != Self.notBeforeFile {
            if let entry = Self.parse(name: name, in: directory) {
                result.append(entry)
            } else {
                try? fm.removeItem(at: directory.appendingPathComponent(name))
            }
        }
        return result.sorted { ($0.firstSeen, $0.id) < ($1.firstSeen, $1.id) }
    }
}
