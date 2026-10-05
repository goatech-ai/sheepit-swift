import XCTest
import SheepitCrashHandler
@testable import SheepitKit

/// A crash report whose upload fails for a retryable reason must survive to the next launch.
///
/// Before this existed, `CrashReporter.start()` uploaded the pending report and THEN installed
/// the handler — and `sheepit_crash_handler_install` opens the crash file `O_TRUNC` and zeroes
/// it. So the "keep the file for retry" branch kept nothing: offline, a 5xx, a proxy/WAF 403 or
/// the daily-cap 402 all lost the report on the very next line. The 4xx branch was dead too: it
/// tested a private `HTTPClientError` that nothing throws (`HTTPClient` throws `SDKError`).
///
/// Every test drives two "launches" against the same temp crash directory, the way a real
/// device does, and never raises a signal. `start()` installs the process-global handler into
/// that temp dir's `current.crash`; `stop()` uninstalls it before the test returns (same
/// discipline as `CrashContextDeviceProfileTests`).
final class CrashUploadRetentionTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sheepit-crash-retention-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Harness

    /// What a crashed previous session leaves behind: a report with the frozen magic at the
    /// live crash path. Built on the heap: the struct is ~320 KB, and these async tests run on
    /// a cooperative-pool thread whose 512 KB stack a local copy of it overflows (SIGBUS).
    private func writeCrashFromPreviousSession() throws {
        try writeCrashReport(to: dir.appendingPathComponent("current.crash"))
    }

    /// A readable report at `url` — for seeding the pending queue directly.
    private func writeCrashReport(to url: URL) throws {
        let size = MemoryLayout<sheepit_crash_report_t>.size
        let raw = try XCTUnwrap(calloc(1, size))
        defer { free(raw) }
        raw.advanced(by: MemoryLayout<sheepit_crash_report_t>.offset(of: \.magic)!)
            .assumingMemoryBound(to: UInt32.self)
            .pointee = UInt32(SHEEPIT_CRASH_REPORT_MAGIC)
        try Data(bytes: raw, count: size).write(to: url)
    }

    /// One app launch: build a reporter over `dir`, run `start()` to completion (adopt, install,
    /// upload), then tear it down. Returns the diagnostics that launch emitted.
    @discardableResult
    private func launch(
        _ stub: StubURLProtocol.Stub,
        storage: StorageProvider,
        enabled: Bool = true,
        now: @escaping @Sendable () -> Date = { Date() }
    ) async -> [DiagnosticEvent] {
        StubURLProtocol.stub = stub
        let bus = DiagnosticBus()
        let reporter = CrashReporter(
            http: HTTPClient(
                config: SheepitConfig(
                    apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))",
                    // The REAL retry config (SDKDefaults.retryAttempts = 3): crash uploads must make
                    // a single in-process attempt regardless, so no backoff sleep happens here.
                    apiUrl: "https://stub.invalid"
                ),
                log: Logger(debug: false),
                urlProtocolClasses: [StubURLProtocol.self]
            ),
            context: ContextManager(storage: InMemoryStorage()),
            config: CrashConfig(enabled: enabled),
            storage: storage,
            log: Logger(debug: false),
            crashDirectory: dir,
            diagnostics: bus,
            now: now
        )
        await reporter.start()
        await reporter.stop()
        return bus.getRecentDiagnostics()
    }

    private func outcomes(_ events: [DiagnosticEvent]) -> [String] {
        events.filter { $0.code == "transport.crash_upload" }
            .compactMap { $0.data?["outcome"]?.value as? String }
    }

    private func pendingReportCount() -> Int {
        let pending = dir.appendingPathComponent("pending", isDirectory: true)
        return ((try? FileManager.default.contentsOfDirectory(atPath: pending.path)) ?? [])
            .filter { $0.hasSuffix(".crash") }.count
    }

    /// Launch 1 fails with `failure`; launch 2 succeeds. The report must reach the server on
    /// launch 2 — the assertion the old code failed for every retryable failure.
    private func assertSurvivesToNextLaunch(
        after failure: StubURLProtocol.Stub,
        _ label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        try writeCrashFromPreviousSession()
        let storage = InMemoryStorage()

        let first = await launch(failure, storage: storage)
        XCTAssertEqual(StubURLProtocol.requestCount, 1, "\(label): launch 1 must attempt the upload", file: file, line: line)
        XCTAssertEqual(outcomes(first), ["retained_for_retry"], "\(label): launch 1 outcome", file: file, line: line)

        let before = StubURLProtocol.requestCount
        let second = await launch(.status(202, body: "{}"), storage: storage)
        XCTAssertEqual(
            StubURLProtocol.requestCount - before, 1,
            "\(label): the report kept for retry must be uploaded on the next launch — it was "
                + "lost because install() truncated the crash file after a failed upload",
            file: file, line: line
        )
        XCTAssertEqual(outcomes(second), ["uploaded"], "\(label): launch 2 outcome", file: file, line: line)
        XCTAssertEqual(pendingReportCount(), 0, "\(label): an uploaded report is deleted", file: file, line: line)
    }

    // MARK: - Retryable failures survive

    func testReportSurvivesA5xxToTheNextLaunch() async throws {
        try await assertSurvivesToNextLaunch(after: .status(503, body: "{}"), "503")
    }

    func testReportSurvivesBeingOfflineToTheNextLaunch() async throws {
        try await assertSurvivesToNextLaunch(after: .failure(URLError(.notConnectedToInternet)), "offline")
    }

    func testReportSurvivesTheDailyCap402ToTheNextLaunch() async throws {
        try await assertSurvivesToNextLaunch(after: .status(402, body: "{}"), "402 daily cap")
    }

    func testReportSurvivesAProxyOrWAF403ToTheNextLaunch() async throws {
        try await assertSurvivesToNextLaunch(after: .status(403, body: "{}"), "403 proxy/WAF")
    }

    func testReportSurvivesA429ToTheNextLaunch() async throws {
        try await assertSurvivesToNextLaunch(after: .status(429, body: "{}"), "429")
    }

    // MARK: - Non-retryable and exhausted reports are dropped

    func testA400DropsTheReportWithoutRetrying() async throws {
        try writeCrashFromPreviousSession()
        let storage = InMemoryStorage()

        let first = await launch(.status(400, body: "{\"error\":{}}"), storage: storage)
        XCTAssertEqual(outcomes(first), ["dropped_non_retryable"])
        XCTAssertEqual(pendingReportCount(), 0)

        let before = StubURLProtocol.requestCount
        await launch(.status(202, body: "{}"), storage: storage)
        XCTAssertEqual(StubURLProtocol.requestCount, before, "a 400 is not retried on a later launch")
    }

    func testA413DropsTheReportWithoutRetrying() async throws {
        try writeCrashFromPreviousSession()
        let first = await launch(.status(413, body: "{}"), storage: InMemoryStorage())
        XCTAssertEqual(outcomes(first), ["dropped_non_retryable"])
        XCTAssertEqual(pendingReportCount(), 0)
    }

    func testAPermanentlyRejectedReportStopsRetryingAfterTheAttemptBudget() async throws {
        try writeCrashFromPreviousSession()
        let storage = InMemoryStorage()

        for attempt in 1...SDKDefaults.crashUploadMaxAttempts {
            let events = await launch(.status(503, body: "{}"), storage: storage)
            XCTAssertEqual(outcomes(events), ["retained_for_retry"], "attempt \(attempt)")
        }
        XCTAssertEqual(StubURLProtocol.requestCount, SDKDefaults.crashUploadMaxAttempts)

        let last = await launch(.status(503, body: "{}"), storage: storage)
        XCTAssertEqual(outcomes(last), ["dropped_retry_exhausted"])
        XCTAssertEqual(
            StubURLProtocol.requestCount, SDKDefaults.crashUploadMaxAttempts,
            "an exhausted report is dropped without another request"
        )
        XCTAssertEqual(pendingReportCount(), 0)
    }

    func testAReportOlderThanTheAgeLimitIsDroppedWithoutARequest() async throws {
        try writeCrashFromPreviousSession()
        let storage = InMemoryStorage()
        let t0 = Date()

        await launch(.status(503, body: "{}"), storage: storage, now: { t0 })
        XCTAssertEqual(StubURLProtocol.requestCount, 1)

        let later = t0.addingTimeInterval(SDKDefaults.crashUploadMaxAge + 60)
        let events = await launch(.status(202, body: "{}"), storage: storage, now: { later })
        XCTAssertEqual(outcomes(events), ["dropped_retry_exhausted"])
        XCTAssertEqual(StubURLProtocol.requestCount, 1, "an aged-out report is not sent")
        XCTAssertEqual(pendingReportCount(), 0)
    }

    func testAQueuedFileThatIsNotACrashReportIsDroppedAsUnreadable() async throws {
        let pending = dir.appendingPathComponent("pending", isDirectory: true)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        try Data("not a crash report".utf8).write(to: pending.appendingPathComponent("\(ms)_0_abc.crash"))
        try Data("stray".utf8).write(to: pending.appendingPathComponent("not-ours.crash"))

        let events = await launch(.status(202, body: "{}"), storage: InMemoryStorage())
        XCTAssertEqual(outcomes(events), ["dropped_unreadable"])
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
        XCTAssertEqual(pendingReportCount(), 0, "neither file may sit on disk forever")
    }

    func testOnlyMalformedTooLargeAndUnprocessableAreNonRetryable() {
        XCTAssertTrue(CrashReporter.isNonRetryable(SDKError.badRequest("x")))
        XCTAssertTrue(CrashReporter.isNonRetryable(SDKError.httpError(413)))
        XCTAssertTrue(CrashReporter.isNonRetryable(SDKError.httpError(422)))
        for code in [401, 402, 403, 404, 409] {
            XCTAssertFalse(CrashReporter.isNonRetryable(SDKError.httpError(code)), "\(code)")
        }
        XCTAssertFalse(CrashReporter.isNonRetryable(SDKError.serverError(503)))
        XCTAssertFalse(CrashReporter.isNonRetryable(SDKError.rateLimited(retryAfter: nil)))
        XCTAssertFalse(CrashReporter.isNonRetryable(SDKError.networkError(URLError(.timedOut))))
        XCTAssertFalse(CrashReporter.isNonRetryable(CancellationError()))
    }

    // MARK: - Only a server answer spends the attempt budget

    func testOfflineLaunchesDoNotSpendTheAttemptBudget() async throws {
        try writeCrashFromPreviousSession()
        let storage = InMemoryStorage()

        for launchNumber in 1...(SDKDefaults.crashUploadMaxAttempts + 2) {
            let events = await launch(.failure(URLError(.notConnectedToInternet)), storage: storage)
            XCTAssertEqual(outcomes(events), ["retained_for_retry"], "offline launch \(launchNumber)")
        }

        let events = await launch(.status(202, body: "{}"), storage: storage)
        XCTAssertEqual(
            outcomes(events), ["uploaded"],
            "a week of offline launches must not exhaust a report the server never saw"
        )
    }

    func testAProxyOrWAF403DoesNotSpendTheAttemptBudget() async throws {
        // Founder decision 2026-09-28: a misconfigured customer proxy/WAF must not cost crashes
        // while it is being fixed. 401/403/404 are bounded by age and the queue cap only.
        try writeCrashFromPreviousSession()
        let storage = InMemoryStorage()

        for launchNumber in 1...(SDKDefaults.crashUploadMaxAttempts + 2) {
            let events = await launch(.status(403, body: "{}"), storage: storage)
            XCTAssertEqual(outcomes(events), ["retained_for_retry"], "403 launch \(launchNumber)")
        }
        let events = await launch(.status(202, body: "{}"), storage: storage)
        XCTAssertEqual(outcomes(events), ["uploaded"], "the report survives until the proxy is fixed")
    }

    func testACrashUploadMakesOneInProcessAttemptPerLaunch() async throws {
        // The cross-launch queue is the retry mechanism. HTTPClient's own 3-try ladder would
        // multiply every launch's upload (and sleep 1 s + 5 s at launch).
        try writeCrashFromPreviousSession()
        await launch(.status(503, body: "{}"), storage: InMemoryStorage())
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    func testTheDailyCap402DoesNotSpendTheAttemptBudget() async throws {
        try writeCrashFromPreviousSession()
        let storage = InMemoryStorage()

        for launchNumber in 1...(SDKDefaults.crashUploadMaxAttempts + 2) {
            let events = await launch(.status(402, body: "{}"), storage: storage)
            XCTAssertEqual(outcomes(events), ["retained_for_retry"], "402 launch \(launchNumber)")
        }
        XCTAssertEqual(pendingReportCount(), 1, "a capped day is waited out, bounded by age only")
    }

    // MARK: - Idempotency key

    func testTheSameReportIdIsSentOnEveryAttempt() async throws {
        try writeCrashFromPreviousSession()
        let storage = InMemoryStorage()

        await launch(.status(503, body: "{}"), storage: storage)
        await launch(.status(202, body: "{}"), storage: storage)

        let ids = StubURLProtocol.requestBodies.map { body -> String? in
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            return json?["report_id"] as? String
        }
        XCTAssertEqual(ids.count, 2)
        let first = try XCTUnwrap(ids.first ?? nil, "every crash upload carries report_id")
        XCTAssertFalse(first.isEmpty)
        XCTAssertEqual(ids.last ?? nil, first, "a retry is the same report, so the same id")
    }

    // MARK: - Queue bound

    func testTheQueueIsCappedWhenANewCrashIsAdopted() async throws {
        var all: [String] = []
        for _ in 1...(SDKDefaults.crashPendingMaxReports + 1) {
            try writeCrashFromPreviousSession()
            // Fresh storage per launch: six crashes inside a minute would otherwise (correctly)
            // trip crash-loop protection, which stops adoption — a different path.
            all += outcomes(await launch(.failure(URLError(.notConnectedToInternet)), storage: InMemoryStorage()))
        }
        XCTAssertEqual(pendingReportCount(), SDKDefaults.crashPendingMaxReports)
        XCTAssertEqual(all.filter { $0 == "dropped_queue_full" }.count, 1)
    }

    func testAReportStampedUnderA1970ClockIsNotTheOneEvictedFromAFullQueue() async throws {
        // Eviction takes the oldest first-seen. A report adopted at a boot before NTP settled
        // is stamped 1970 — it must be judged by when the clock was right, not always lose.
        let pending = dir.appendingPathComponent("pending", isDirectory: true)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        let now = Date()
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let max = SDKDefaults.crashPendingMaxReports
        try writeCrashReport(to: pending.appendingPathComponent("0_0_epoch.crash"))
        for hoursAgo in 1..<max {
            try writeCrashReport(
                to: pending.appendingPathComponent("\(nowMs - Int64(hoursAgo) * 3_600_000)_0_real\(hoursAgo).crash")
            )
        }
        try writeCrashFromPreviousSession()

        let events = await launch(.failure(URLError(.notConnectedToInternet)),
                                  storage: InMemoryStorage(), now: { now })

        let names = (try? FileManager.default.contentsOfDirectory(atPath: pending.path)) ?? []
        XCTAssertEqual(names.count, max)
        XCTAssertTrue(names.contains { $0.hasSuffix("_epoch.crash") }, "the 1970-stamped report was evicted: \(names)")
        XCTAssertFalse(names.contains { $0.hasSuffix("_real\(max - 1).crash") }, "the oldest real report goes: \(names)")
        XCTAssertEqual(outcomes(events).filter { $0 == "dropped_queue_full" }.count, 1)
    }

    // MARK: - Crash-loop protection and a disabled reporter do not strand the queue

    func testQueuedReportsStillUploadWhileCrashLoopProtectionIsLatched() async throws {
        try writeCrashFromPreviousSession()
        let storage = InMemoryStorage()
        await launch(.status(503, body: "{}"), storage: storage)
        XCTAssertEqual(pendingReportCount(), 1)

        storage.set("1", forKey: "sheepit_crash_loop_disabled")
        let events = await launch(.status(202, body: "{}"), storage: storage)

        XCTAssertEqual(
            outcomes(events), ["uploaded"],
            "the latch disables the HANDLER; it must not strand reports already queued"
        )
        XCTAssertEqual(pendingReportCount(), 0)
    }

    func testALatchedLaunchLeavesTheLiveCrashFileAlone() async throws {
        let storage = InMemoryStorage()
        storage.set("1", forKey: "sheepit_crash_loop_disabled")
        try writeCrashFromPreviousSession()

        await launch(.status(202, body: "{}"), storage: storage)

        XCTAssertTrue(
            sheepit_has_pending_crash_report(dir.appendingPathComponent("current.crash").path),
            "no adoption while latched: the handler is not installed, so the live file is safe"
        )
        XCTAssertEqual(StubURLProtocol.requestCount, 0)
    }

    // MARK: - Device clock skew

    func testAReportAdoptedUnderA1970ClockIsNotAgedOutOnceTheClockIsFixed() async throws {
        // A crash found at a boot before NTP settles: the device clock reads the epoch. The
        // next launch, with a real clock, must not see a 56-year-old report and drop it.
        try writeCrashFromPreviousSession()
        let storage = InMemoryStorage()

        await launch(.status(503, body: "{}"), storage: storage, now: { Date(timeIntervalSince1970: 0) })
        let events = await launch(.status(202, body: "{}"), storage: storage)

        XCTAssertEqual(outcomes(events), ["uploaded"])
    }

    func testAFutureDatedReportIsRestampedSoItAgesOutOnRealTime() async throws {
        // Adopted under a clock 30 days fast: without a re-stamp it could never age out and
        // would hold a queue slot for 30 + 7 days of offline launches.
        try writeCrashFromPreviousSession()
        let storage = InMemoryStorage()
        let real = Date()

        await launch(.failure(URLError(.notConnectedToInternet)), storage: storage,
                     now: { real.addingTimeInterval(30 * 24 * 3600) })
        await launch(.failure(URLError(.notConnectedToInternet)), storage: storage, now: { real })
        let aged = real.addingTimeInterval(SDKDefaults.crashUploadMaxAge + 3600)
        let events = await launch(.failure(URLError(.notConnectedToInternet)), storage: storage, now: { aged })

        XCTAssertEqual(outcomes(events), ["dropped_retry_exhausted"], "ages out 7 days after the clock was fixed")
    }

    // MARK: - Crash-loop accounting

    func testARetainedReportIsCountedAsACrashOnlyOnce() async throws {
        try writeCrashFromPreviousSession()
        let storage = InMemoryStorage()

        await launch(.status(503, body: "{}"), storage: storage)
        await launch(.status(503, body: "{}"), storage: storage)

        let recorded = (storage.string(forKey: "sheepit_crash_timestamps") ?? "")
            .split(separator: ",").count
        XCTAssertEqual(
            recorded, 1,
            "a report carried across launches for retry is ONE crash — counting it again on every "
                + "retry would trip crash-loop protection and disable the reporter"
        )
    }

    func testTwoCrashesWhileOfflineAreBothKeptAndBothUploaded() async throws {
        let storage = InMemoryStorage()

        try writeCrashFromPreviousSession()
        await launch(.failure(URLError(.notConnectedToInternet)), storage: storage)
        try writeCrashFromPreviousSession()
        await launch(.failure(URLError(.notConnectedToInternet)), storage: storage)
        XCTAssertEqual(pendingReportCount(), 2, "a new crash must not overwrite one still awaiting upload")

        let events = await launch(.status(202, body: "{}"), storage: storage)
        XCTAssertEqual(outcomes(events), ["uploaded", "uploaded"])
        XCTAssertEqual(pendingReportCount(), 0)
    }
}

final class PendingCrashStoreLocationTests: XCTestCase {
    /// iOS purges Caches under storage pressure — a report waiting out an outage must not live
    /// there.
    func testTheProductionQueueIsInApplicationSupportNotCaches() {
        let path = PendingCrashStore.productionDirectory().path
        XCTAssertTrue(path.contains("Application Support"), path)
        XCTAssertFalse(path.contains("Caches"), path)
        XCTAssertTrue(path.hasSuffix("ai.goatech.sdk/crashes/pending"), path)
    }

    /// Every client a test builds without injecting a directory must stay off the developer's
    /// real `~/Library/Application Support/ai.goatech.sdk/crashes/pending`.
    func testUnderXCTestTheDefaultQueueIsNotTheRealOne() {
        let path = PendingCrashStore.defaultDirectory().path
        XCTAssertNotEqual(path, PendingCrashStore.productionDirectory().path)
        XCTAssertFalse(path.contains("Application Support"), path)
    }

    /// A PID alone recycles: a later run drawing the same PID would upload what an earlier
    /// one left queued.
    func testTheXCTestQueueIsUniquePerRunAndStableWithinOne() {
        let queue = PendingCrashStore.defaultDirectory()
        XCTAssertEqual(PendingCrashStore.defaultDirectory(), queue, "one queue for the whole process")
        let folder = queue.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
        let pidOnly = "ai.goatech.sdk-xctest-\(ProcessInfo.processInfo.processIdentifier)"
        XCTAssertTrue(folder.hasPrefix(pidOnly + "-"), folder)
        XCTAssertNotNil(UUID(uuidString: String(folder.dropFirst(pidOnly.count + 1))), folder)
    }

    /// 🔴 Do not "fix" this by redirecting the live file under XCTest the way the queue is. The
    /// check is "XCTest is loaded", not "this is a test run"; in a process where it misfires, a
    /// moved live file is looked for somewhere new each launch and crash capture silently stops.
    /// Built with no directory and never started — `start()` would truncate the real file.
    func testTheLiveCrashFileIsNeverRedirectedEvenWithXCTestLoaded() {
        let reporter = CrashReporter(
            http: HTTPClient(
                config: SheepitConfig(apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))",
                                      apiUrl: "https://stub.invalid"),
                log: Logger(debug: false)
            ),
            context: ContextManager(storage: InMemoryStorage()),
            config: CrashConfig(enabled: true),
            storage: InMemoryStorage(),
            log: Logger(debug: false),
            pendingDirectory: FileManager.default.temporaryDirectory
                .appendingPathComponent("sheepit-live-pin-\(UUID().uuidString)", isDirectory: true)
        )
        XCTAssertEqual(
            reporter.crashFilePath,
            CrashReporter.productionLiveDirectory().appendingPathComponent("current.crash").path
        )
    }

    func testTheProductionLiveCrashFileIsWhere0xPutIt() {
        let path = CrashReporter.productionLiveDirectory().path
        XCTAssertTrue(path.contains("Caches"), path)
        XCTAssertTrue(path.hasSuffix("ai.goatech.sdk/crashes"), path)
    }

    func testOnlyA5xxSpendsAnAttempt() {
        XCTAssertTrue(CrashReporter.spendsAttempt(SDKError.serverError(503)))
        XCTAssertFalse(CrashReporter.spendsAttempt(SDKError.badRequest("x")), "400 drops; it never reaches this")
        for code in [401, 402, 403, 404] {
            XCTAssertFalse(CrashReporter.spendsAttempt(SDKError.httpError(code)), "\(code)")
        }
        XCTAssertFalse(CrashReporter.spendsAttempt(SDKError.rateLimited(retryAfter: 60)))
        XCTAssertFalse(CrashReporter.spendsAttempt(SDKError.networkError(URLError(.timedOut))))
        XCTAssertFalse(CrashReporter.spendsAttempt(CancellationError()))
    }
}

/// The store's own invariants, independent of `CrashReporter`.
final class PendingCrashStoreAdoptTests: XCTestCase {
    func testAFailedAdoptionEvictsNothing() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sheepit-adopt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = PendingCrashStore(directory: dir)
        let ms = Int64(Date().timeIntervalSince1970 * 1000)
        for i in 0..<SDKDefaults.crashPendingMaxReports {
            try Data("x".utf8).write(to: dir.appendingPathComponent("\(ms + Int64(i))_0_id\(i).crash"))
        }

        let missing = dir.appendingPathComponent("no-such-live-file.crash")
        let result = store.adopt(liveFile: missing, now: Date(), maxReports: SDKDefaults.crashPendingMaxReports)

        XCTAssertNil(result.entry)
        XCTAssertEqual(result.evicted, [], "nothing was added, so nothing may be dropped to make room")
        XCTAssertEqual(store.entries().count, SDKDefaults.crashPendingMaxReports)
    }
}

/// The disabled path, driven through `SheepitClient` — the only thing that builds a
/// `CrashReporter`, and it builds none when crash reporting is off. The queue must still age out.
final class DisabledCrashReportingReapTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sheepit-disabled-reap-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testAClientWithCrashReportingOffAgesOutTheQueueAndSendsNothing() async throws {
        let now = Date()
        let nowMs = Int64(now.timeIntervalSince1970 * 1000)
        let agedMs = nowMs - Int64((SDKDefaults.crashUploadMaxAge + 3600) * 1000)
        try Data("x".utf8).write(to: dir.appendingPathComponent("\(agedMs)_0_aged.crash"))
        try Data("x".utf8).write(to: dir.appendingPathComponent("\(nowMs)_0_young.crash"))

        let diagnostics = LockedBox<[DiagnosticEvent]>([])
        var config = SheepitConfig(
            apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))",
            apiUrl: "https://stub.invalid",
            crashes: CrashConfig(enabled: false)
        )
        config.onDiagnostic = { @Sendable event in diagnostics.mutate { $0.append(event) } }
        let client = SheepitClient.createForTesting(
            config: config,
            now: { now },
            urlProtocolClasses: [StubURLProtocol.self],
            crashPendingDirectory: dir
        )
        defer { client.destroy() }

        // Off the caller's thread (like the enabled path's `Task { await reporter.start() }`),
        // so wait for it — on the diagnostic, which is emitted AFTER the file is removed.
        func reapOutcomes() -> [String] {
            diagnostics.get().filter { $0.code == "transport.crash_upload" }
                .compactMap { $0.data?["outcome"]?.value as? String }
        }
        let deadline = Date().addingTimeInterval(5)
        while reapOutcomes().isEmpty, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        XCTAssertEqual(names, ["\(nowMs)_0_young.crash"], "aged report dropped, young one kept")
        XCTAssertEqual(
            StubURLProtocol.requestPaths.filter { $0.hasSuffix(SDKEndpoints.crashReport) }.count, 0,
            "a disabled reporter sends no crash report"
        )
        XCTAssertEqual(reapOutcomes(), ["dropped_retry_exhausted"])
    }
}
