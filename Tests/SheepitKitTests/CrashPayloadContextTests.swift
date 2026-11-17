import XCTest
import SheepitCrashHandler
@testable import SheepitKit

/// What 0.10.1 adds to the crash payload and context: the `thread_info` cap, the capturing SDK
/// version, the flag and experiment state, breadcrumb capacity and `$screen` breadcrumbs.
final class CrashPayloadContextTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        super.setUp()
        dir = CrashFixtures.tempDirectory("crash-payload")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    // MARK: - thread_info cap

    /// `crashReportIngestSchema.thread_info` is `.max(50)` and a 400 is permanent to the SDK, so a
    /// report from an app with more than 50 threads was dropped forever. The crashed thread must
    /// survive the cap wherever it sat.
    func testWireThreadsAreCappedAndKeepTheCrashedThread() throws {
        let url = dir.appendingPathComponent("many.crash")
        try CrashFixtures.writeReport(to: url, threads: 80, crashedIndex: 70)
        let payload = try XCTUnwrap(CrashReportReader.read(from: url.path))
        XCTAssertEqual(payload.threadInfo?.count, 80, "everything captured is kept in memory")

        let threads = try XCTUnwrap(CrashFixtures.wireJSON(payload)["thread_info"] as? [[String: Any]])
        XCTAssertEqual(threads.count, CrashReportPayload.maxWireThreads)
        XCTAssertEqual(threads.filter { $0["is_crashed"] as? Bool == true }.count, 1)
        XCTAssertEqual(threads.last?["thread_id"] as? Int, 1070)
        XCTAssertEqual(threads.first?["thread_id"] as? Int, 1000, "capture order otherwise kept")
    }

    func testThreadsUnderTheCapAreUntouched() throws {
        let url = dir.appendingPathComponent("few.crash")
        try CrashFixtures.writeReport(to: url, threads: 3, crashedIndex: 2)
        let payload = try XCTUnwrap(CrashReportReader.read(from: url.path))
        let threads = try XCTUnwrap(CrashFixtures.wireJSON(payload)["thread_info"] as? [[String: Any]])
        XCTAssertEqual(threads.compactMap { $0["thread_id"] as? Int }, [1000, 1001, 1002])
    }

    // MARK: - sdk_version

    func testSdkVersionOnTheWireIsTheCapturingVersion() throws {
        let url = dir.appendingPathComponent("v.crash")
        let sidecar = dir.appendingPathComponent("v.supplement")
        try CrashFixtures.writeReport(to: url)
        try CrashFixtures.writeSupplement(to: sidecar)
        let payload = try XCTUnwrap(CrashReportReader.read(from: url.path, supplementPath: sidecar.path))
        XCTAssertEqual(try CrashFixtures.wireJSON(payload)["sdk_version"] as? String, "0.10.1")
    }

    // MARK: - Flag and experiment state

    func testBoundedJSONObjectIsValidDeterministicAndFits() throws {
        var values: [String: AnyCodable] = [:]
        for i in 0..<200 { values[String(format: "flag_%03d", i)] = AnyCodable(String(repeating: "v", count: 30)) }
        values["a_huge_one"] = AnyCodable(String(repeating: "x", count: 5000))

        let json = CrashReporter.boundedJSONObject(values, maxBytes: 4095)
        XCTAssertLessThanOrEqual(json.utf8.count, 4095)
        XCTAssertEqual(json, CrashReporter.boundedJSONObject(values, maxBytes: 4095), "deterministic")
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertNil(parsed["a_huge_one"], "an entry that cannot fit is skipped, not cut")
        XCTAssertNotNil(parsed["flag_000"], "entries are taken in key order")
        XCTAssertNil(parsed["flag_199"])
        XCTAssertEqual(CrashReporter.boundedJSONObject([:], maxBytes: 4095), "{}")
    }

    /// `setFlagState` / `setExperimentState` had no callers before 0.10.1, so every crash shipped
    /// `active_flags: null`. Installs the process-global handler into a temp file (never the
    /// SDK's real path) and uninstalls before returning, as `CrashContextDeviceProfileTests` does.
    func testFlagAndExperimentChangesReachTheCrashContext() async throws {
        let reporter = makeReporter()
        await reporter.start()
        addTeardownBlock { await reporter.stop() }
        let url = URL(fileURLWithPath: reporter.crashFilePath)

        let flags = FlagManager()
        flags.setValuesObserver { reporter.setFlagState($0) }
        flags.setEvaluatedFlags(["checkout_v2": AnyCodable(true), "limit": AnyCodable(3)])
        let experiments = ExperimentManager(storage: InMemoryStorage())
        experiments.setVariantsObserver { reporter.setExperimentState($0) }
        let arm = try JSONDecoder().decode(
            SDKExperimentAssignment.self, from: Data(#"{"variant_key":"treatment","payload":{}}"#.utf8)
        )
        experiments.setAssignments(["pricing": arm], appliedUnderUserId: nil)

        stampReportMagic()
        var payload = try XCTUnwrap(CrashReportReader.read(from: url.path))
        XCTAssertEqual(payload.activeFlags?["checkout_v2"]?.value as? Bool, true)
        XCTAssertEqual(payload.activeFlags?["limit"]?.value as? Int, 3)
        XCTAssertNil(payload.activeExperiments, "legacy experiment maps are not part of the receipt wire")

        flags.clearEvaluated()
        experiments.clearForLogout()
        payload = try XCTUnwrap(CrashReportReader.read(from: url.path))
        XCTAssertNil(payload.activeFlags, "a logout clears what the crash context says is active")
        XCTAssertNil(payload.activeExperiments)
    }

    /// `destroy()` must detach the flag observer before the reporter's `stop()` unmaps the crash
    /// context; otherwise a config apply still in flight writes 4 KB into an unmapped page and
    /// crashes the host app at shutdown. Construct-only: no handler is installed.
    func testDestroyDetachesTheCrashStateObservers() {
        let client = SheepitClient.constructOnlyForTesting(config: SheepitConfig(
            apiKey: "lp_pub_xxx_\(String(repeating: "a", count: 64))",
            apiUrl: "https://stub.invalid",
            crashes: CrashConfig(enabled: true)
        ))
        XCTAssertNil(client.inertReason, "precondition: a live-shaped client")
        XCTAssertTrue(client.flagManager.hasValuesObserverForTesting, "precondition: wired at init")
        client.destroy()
        XCTAssertFalse(client.flagManager.hasValuesObserverForTesting)
    }

    /// The memory-warning block and the sampling task write from other threads; `stop()` must
    /// shut them out before the context is unmapped, or a late sample stores into an unmapped page.
    func testStopShutsOutLateContextWrites() async throws {
        let reporter = makeReporter()
        await reporter.start()
        let initialContext = try XCTUnwrap(sheepit_get_crash_context())
        reporter.writeFreeMemory(77)
        reporter.setScreen("Before")
        XCTAssertEqual(initialContext.pointee.free_memory_mb, 77)
        await reporter.stop()
        let next = makeReporter(directory: dir.appendingPathComponent("next"))
        await next.start()
        addTeardownBlock { await next.stop() }
        next.writeFreeMemory(77)
        next.setScreen("Before")
        let ctx = try XCTUnwrap(sheepit_get_crash_context())
        reporter.writeFreeMemory(55)
        reporter.setScreen("After")
        reporter.setFlagState(["late": AnyCodable(true)])
        XCTAssertEqual(ctx.pointee.free_memory_mb, 77, "a write after stop() must not land")
        XCTAssertEqual(CrashText.string(ctx.pointee.screen_name), "Before",
                       "setScreen is public and runs on any thread: it is gated too")
        XCTAssertEqual(CrashText.string(ctx.pointee.active_flags_json), "")
    }

    // MARK: - Byte budget

    /// `crash-ingest.ts` refuses a body over 524_288 bytes with a 413, which is permanent to the
    /// SDK: 50 threads of deep stacks lost the report. Trimmed to fit, crashed thread intact.
    func testPayloadIsTrimmedToTheIngestBodyLimit() throws {
        let url = dir.appendingPathComponent("big.crash")
        try CrashFixtures.writeReport(to: url)
        var payload = try XCTUnwrap(CrashReportReader.read(from: url.path))
        let frames = (0..<128).map {
            CrashStackFrame(index: $0, function: nil, imageName: "SomeRatherLongFrameworkName.framework",
                            rawAddress: "0x00000001000000ff", symbolAddress: nil,
                            imageAddress: "0x0000000100000000", isAppFrame: false)
        }
        payload.threadInfo = (0..<50).map {
            CrashThreadInfo(threadId: UInt64($0), name: "worker-\($0)", isCrashed: $0 == 37, frames: frames)
        }
        XCTAssertGreaterThan(try JSONEncoder().encode(payload).count, CrashReportPayload.maxWireBytes,
                             "precondition: the untrimmed body is over budget")

        let fitted = payload.fittingBudget()
        XCTAssertLessThanOrEqual(try JSONEncoder().encode(fitted).count, CrashReportPayload.maxWireBytes)
        let crashed = try XCTUnwrap(fitted.threadInfo?.first { $0.isCrashed })
        XCTAssertEqual(crashed.threadId, 37)
        XCTAssertEqual(crashed.frames.count, 128, "the crashed thread is never trimmed")
        XCTAssertEqual(fitted.stackTrace.frames.count, payload.stackTrace.frames.count)
        XCTAssertEqual(fitted.exceptionType, payload.exceptionType)
        XCTAssertEqual(fitted.threadInfo?.count, 50, "frames go before whole threads")
    }

    func testCorruptBatteryLevelIsClampedNotSentOutOfRange() throws {
        let url = dir.appendingPathComponent("battery.crash")
        try CrashFixtures.writeReport(to: url, batteryLevel: 250)
        XCTAssertEqual(CrashReportReader.read(from: url.path)?.batteryLevel, 100)
    }

    // MARK: - Breadcrumbs

    func testBreadcrumbCapacityKeepsTheNewest() throws {
        let url = dir.appendingPathComponent("crumbs.crash")
        XCTAssertEqual(sheepit_crash_handler_install(url.path), 0, "precondition: handler must install")
        defer { sheepit_crash_handler_uninstall() }
        for i in 0..<10 { sheepit_add_breadcrumb("track", "e\(i)") }
        stampReportMagic()

        XCTAssertEqual(CrashReportReader.read(from: url.path, breadcrumbLimit: 3)?.breadcrumbs?.map(\.message),
                       ["e7", "e8", "e9"])
        XCTAssertNil(CrashReportReader.read(from: url.path, breadcrumbLimit: 0)?.breadcrumbs)
        XCTAssertEqual(CrashReportReader.read(from: url.path, breadcrumbLimit: 500)?.breadcrumbs?.count, 10,
                       "a capacity above the ring's 32 is clamped, not an error")
    }

    func testScreenBreadcrumbNamesTheScreen() {
        XCTAssertEqual(SheepitClient.trackBreadcrumbMessage("$screen", ["screen": "Checkout"]), "$screen: Checkout")
        XCTAssertEqual(SheepitClient.trackBreadcrumbMessage("$screen", nil), "$screen")
        XCTAssertEqual(SheepitClient.trackBreadcrumbMessage("purchase", ["screen": "Checkout"]), "purchase")
    }

    // MARK: - Helpers

    private func makeReporter(directory: URL? = nil) -> CrashReporter {
        CrashReporter(
            http: HTTPClient(
                config: SheepitConfig(apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))", apiUrl: "https://stub.invalid"),
                log: Logger(debug: false)
            ),
            context: ContextManager(storage: InMemoryStorage()),
            config: CrashConfig(enabled: true),
            appVersionOverride: nil,
            storage: InMemoryStorage(),
            log: Logger(debug: false),
            appState: AppForegroundState(launchedInBackground: false, tracksAppState: true),
            crashDirectory: directory ?? dir
        )
    }

    /// Production stamps the report magic only inside the signal handler; see
    /// `CrashContextDeviceProfileTests` for why a test writes it into the mapping directly.
    private func stampReportMagic() {
        guard let ctx = sheepit_get_crash_context() else { return XCTFail("handler not installed") }
        let contextOffset = MemoryLayout<sheepit_crash_report_t>.offset(of: \.context)!
        let magicOffset = MemoryLayout<sheepit_crash_report_t>.offset(of: \.magic)!
        UnsafeMutableRawPointer(ctx)
            .advanced(by: magicOffset - contextOffset)
            .assumingMemoryBound(to: UInt32.self)
            .pointee = UInt32(SHEEPIT_CRASH_REPORT_MAGIC)
    }
}
