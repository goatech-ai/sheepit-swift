import Foundation

/// On-disk queue of crash reports waiting to be uploaded, kept apart from the live crash file.
///
/// The live file (`current.crash`) cannot hold a report across a launch: the C handler opens it
/// `O_TRUNC` and zeroes it on every install (`sheepit_crash_handler_install`). So `CrashReporter`
/// moves a previous session's report in here BEFORE installing, and uploads from here.
///
/// Lives in Application Support, not Caches: iOS purges Caches under storage pressure, which
/// would silently drop a report waiting out an outage. Excluded from backup.
///
/// Each report's retry state lives in its file name, `<firstSeenMs>_<attempts>_<id>.crash`, so
/// the counter and the report can never disagree: an attempt is recorded by an atomic rename.
/// `id` is a UUID minted when the report is first adopted and stable across every retry — it is
/// sent as `report_id`. At most `SDKDefaults.crashPendingMaxReports` files are kept: `adopt`
/// evicts the oldest to make room.
struct PendingCrashStore: Sendable {
    struct Entry: Sendable, Equatable {
        let url: URL
        let id: String
        /// When a launch first found this report (the SDK's clock, not the crash timestamp,
        /// which came from a device clock one launch ago).
        let firstSeen: Date
        /// Upload attempts that reached the server and counted (see `CrashReporter`).
        let attempts: Int
    }

    let directory: URL

    init(directory: URL) {
        self.directory = directory
    }

    /// `productionDirectory()`, except when XCTest is loaded, where it is a temp directory
    /// unique to this run. The package's own tests build ~140 clients through the public
    /// factories, and a host app's unit tests may build more; none of them may read or reap the
    /// developer's real queue. Release apps never load XCTest, so they get the production path.
    ///
    /// 🔴 Only the queue moves — never the live crash file (`CrashReporter.productionLiveDirectory`).
    /// The check is "XCTest is loaded", not "this is a test run": in a process where it misfires,
    /// a moved live file would be looked for somewhere new on every launch and crash capture
    /// would silently stop. A misfire here costs only cross-launch retries.
    static func defaultDirectory() -> URL {
        guard NSClassFromString("XCTestCase") != nil else { return productionDirectory() }
        return FileManager.default.temporaryDirectory.appendingPathComponent(
            "ai.goatech.sdk-xctest-\(ProcessInfo.processInfo.processIdentifier)-\(xctestRunID)/crashes/pending",
            isDirectory: true
        )
    }

    /// Makes `defaultDirectory()` unique per run, not just per PID: PIDs recycle, and a later
    /// run drawing the same PID would upload what an earlier one left queued. Fixed for the
    /// life of the process.
    private static let xctestRunID = UUID().uuidString

    /// `<Application Support>/ai.goatech.sdk/crashes/pending`.
    static func productionDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("ai.goatech.sdk/crashes/pending", isDirectory: true)
    }

    /// Move the live crash file into the queue, then evict the oldest OTHER reports so at most
    /// `maxReports` remain (ties on first-seen — e.g. several re-stamped to the same `now` —
    /// fall back to `id` order). `entry` is `nil` if the move failed — the report is still at
    /// `liveFile` and the next install will destroy it — and then nothing is evicted, since
    /// nothing was added. `evicted` were deleted.
    func adopt(liveFile: URL, now: Date, maxReports: Int) -> (entry: Entry?, evicted: [Entry]) {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var dirURL = directory
        try? dirURL.setResourceValues(values)

        let entry = makeEntry(id: UUID().uuidString, firstSeen: now, attempts: 0)
        do {
            try fm.moveItem(at: liveFile, to: entry.url)
        } catch {
            return (nil, [])
        }

        let others = entries().filter { $0.id != entry.id }
        let evicted = Array(others.prefix(max(0, others.count - (max(1, maxReports) - 1))))
        evicted.forEach(remove)
        return (entry, evicted)
    }

    /// Every queued report, oldest first. A file whose name does not parse is not a report
    /// this code wrote; it is deleted so it cannot sit on disk forever.
    func entries() -> [Entry] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var result: [Entry] = []
        for name in names {
            let url = directory.appendingPathComponent(name)
            if let entry = parse(name: name) {
                result.append(entry)
            } else {
                try? fm.removeItem(at: url)
            }
        }
        return result.sorted { ($0.firstSeen, $0.id) < ($1.firstSeen, $1.id) }
    }

    /// Record one more attempt, before it is made — so a kill or crash mid-upload still spends
    /// it. If the rename fails the attempt is not counted, and `crashUploadMaxAge` is what
    /// still bounds the report.
    func recordAttempt(_ entry: Entry) -> Entry {
        rename(entry, attempts: entry.attempts + 1)
    }

    /// Give back an attempt that `recordAttempt` took, for an upload the server never answered
    /// (or answered "later"). Same failure behaviour as `recordAttempt`.
    func refundAttempt(_ entry: Entry) -> Entry {
        rename(entry, attempts: max(0, entry.attempts - 1))
    }

    private func rename(_ entry: Entry, attempts: Int) -> Entry {
        guard attempts != entry.attempts else { return entry }
        let next = makeEntry(id: entry.id, firstSeen: entry.firstSeen, attempts: attempts)
        do {
            try FileManager.default.moveItem(at: entry.url, to: next.url)
            return next
        } catch {
            return entry
        }
    }

    /// Replace an implausible first-seen time (see `CrashReporter.withPlausibleFirstSeen`). Same
    /// failure behaviour as `recordAttempt`.
    func restamp(_ entry: Entry, firstSeen: Date) -> Entry {
        let next = makeEntry(id: entry.id, firstSeen: firstSeen, attempts: entry.attempts)
        guard next.url != entry.url else { return entry }
        do {
            try FileManager.default.moveItem(at: entry.url, to: next.url)
            return next
        } catch {
            return entry
        }
    }

    func remove(_ entry: Entry) {
        try? FileManager.default.removeItem(at: entry.url)
    }

    // MARK: - Naming

    private func makeEntry(id: String, firstSeen: Date, attempts: Int) -> Entry {
        let ms = Int64((firstSeen.timeIntervalSince1970 * 1000).rounded())
        return Entry(
            url: directory.appendingPathComponent("\(ms)_\(attempts)_\(id).crash"),
            id: id,
            firstSeen: Date(timeIntervalSince1970: Double(ms) / 1000),
            attempts: attempts
        )
    }

    private func parse(name: String) -> Entry? {
        guard name.hasSuffix(".crash") else { return nil }
        let parts = name.dropLast(".crash".count).split(separator: "_", maxSplits: 2)
        guard parts.count == 3,
              let ms = Int64(parts[0]),
              let attempts = Int(parts[1]), attempts >= 0,
              !parts[2].isEmpty
        else { return nil }
        return Entry(
            url: directory.appendingPathComponent(name),
            id: String(parts[2]),
            firstSeen: Date(timeIntervalSince1970: Double(ms) / 1000),
            attempts: attempts
        )
    }
}
