import XCTest
import SheepitCrashHandler
@testable import SheepitKit

/// `is_foreground` in the crash context. The C struct reserved it and `CrashReportReader` read it
/// back, but nothing wrote it, so every crash shipped `is_foreground: false`.
///
/// The reporter is started for real (handlers installed into a throwaway directory, no signal
/// raised, stopped in teardown), and transitions are driven through `AppLifecycleObserver`, the
/// type the UIKit notifications call, so the path under test is the production one.
final class CrashContextForegroundTests: XCTestCase {
    private var dir: URL!

    override func setUp() {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sheepit-crash-foreground-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func testAForegroundLaunchReportsForeground() async throws {
        let (reporter, _) = await startReporter(launchedInBackground: false)
        XCTAssertEqual(try readIsForeground(reporter), true)
    }

    func testABackgroundLaunchReportsBackground() async throws {
        let (reporter, _) = await startReporter(launchedInBackground: true)
        XCTAssertEqual(try readIsForeground(reporter), false)
    }

    /// 🔴 The stale-`true` case: the context was written in the foreground, then the app went to
    /// the background with no other context refresh. The crash must say background.
    func testEveryTransitionReachesTheContextWithoutAnotherRefresh() async throws {
        let (reporter, observer) = await startReporter(launchedInBackground: false)
        XCTAssertEqual(try readIsForeground(reporter), true)

        observer.appDidEnterBackground()
        XCTAssertEqual(try readIsForeground(reporter), false, "a crash after backgrounding must not ship the stale true")

        await observer.appWillEnterForeground()
        XCTAssertEqual(try readIsForeground(reporter), true)

        observer.appDidEnterBackground()
        XCTAssertEqual(try readIsForeground(reporter), false)

        // The second foreground signal, for a transition `willEnterForeground` never announced.
        await observer.appDidBecomeActive()
        XCTAssertEqual(try readIsForeground(reporter), true)
    }

    /// A background launch's first foreground, then back: the order 0.6-C's sessions follow.
    func testABackgroundLaunchFollowsItsFirstForegroundAndBack() async throws {
        let (reporter, observer) = await startReporter(launchedInBackground: true)
        XCTAssertEqual(try readIsForeground(reporter), false)

        await observer.appDidBecomeActive()
        XCTAssertEqual(try readIsForeground(reporter), true)

        observer.appDidEnterBackground()
        XCTAssertEqual(try readIsForeground(reporter), false)
    }

    /// A later full refresh (identity, session, device id) writes the CURRENT state, not the one
    /// at launch. The mirror is detached first so the context still holds the launch's `true`
    /// when the refresh runs: only `updateContext()` can turn it `false` here.
    func testARefreshWritesTheCurrentStateNotTheLaunchState() async throws {
        let (reporter, observer) = await startReporter(launchedInBackground: false)
        XCTAssertEqual(try readIsForeground(reporter), true)
        observer.appState.setOnChange(nil)
        observer.appDidEnterBackground()
        XCTAssertEqual(try readIsForeground(reporter), true, "precondition: the transition was not mirrored")
        reporter.updateContext()
        XCTAssertEqual(try readIsForeground(reporter), false)
    }

    /// A reporter whose install failed (another one holds the process-global mapping) does not
    /// mirror its state into that mapping.
    func testAReporterThatCouldNotInstallDoesNotWriteAnotherOnesContext() async throws {
        let (owner, _) = await startReporter(launchedInBackground: true)
        let (_, intruder) = await startReporter(launchedInBackground: true, directory: "second")
        await intruder.appWillEnterForeground()
        XCTAssertEqual(try readIsForeground(owner), false)
    }

    /// `stop()` detaches the mirror, so a stopped reporter's state never writes into a context
    /// it does not own: here, one a later client installed. (Detaching first also keeps a
    /// transition from storing into the page `stop()` unmaps; that race is not reproducible here.)
    func testAStoppedReporterNoLongerWritesTheContext() async throws {
        let (reporter, observer) = await startReporter(launchedInBackground: true)
        await reporter.stop()
        XCTAssertNil(sheepit_get_crash_context())

        let next = dir.appendingPathComponent("next.crash")
        XCTAssertEqual(sheepit_crash_handler_install(next.path), 0, "precondition: handler must install")
        defer { sheepit_crash_handler_uninstall() }

        await observer.appWillEnterForeground()
        XCTAssertEqual(try XCTUnwrap(sheepit_get_crash_context()).pointee.is_foreground, false)
    }

    // MARK: - Helpers

    private func startReporter(
        launchedInBackground: Bool,
        directory: String? = nil
    ) async -> (CrashReporter, AppLifecycleObserver) {
        let appState = AppForegroundState(launchedInBackground: launchedInBackground, tracksAppState: true)
        let reporter = CrashReporter(
            http: HTTPClient(
                config: SheepitConfig(
                    apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))",
                    apiUrl: "https://stub.invalid"
                ),
                log: Logger(debug: false)
            ),
            context: ContextManager(storage: InMemoryStorage()),
            config: CrashConfig(enabled: true),
            appVersionOverride: nil,
            storage: InMemoryStorage(),
            log: Logger(debug: false),
            appState: appState,
            crashDirectory: directory.map { dir.appendingPathComponent($0, isDirectory: true) } ?? dir
        )
        await reporter.start()
        addTeardownBlock { await reporter.stop() }
        let observer = AppLifecycleObserver(
            log: Logger(debug: false),
            diagnostics: nil,
            appState: appState,
            onBackground: {}
        )
        return (reporter, observer)
    }

    /// Stamp the report magic the signal handler would, then read the file back the way the next
    /// launch does. See `CrashContextDeviceProfileTests` for why the stamp is needed.
    private func readIsForeground(_ reporter: CrashReporter) throws -> Bool? {
        let ctx = try XCTUnwrap(sheepit_get_crash_context(), "start() must have installed the handler")
        let contextOffset = MemoryLayout<sheepit_crash_report_t>.offset(of: \.context)!
        let magicOffset = MemoryLayout<sheepit_crash_report_t>.offset(of: \.magic)!
        UnsafeMutableRawPointer(ctx)
            .advanced(by: magicOffset - contextOffset)
            .assumingMemoryBound(to: UInt32.self)
            .pointee = UInt32(SHEEPIT_CRASH_REPORT_MAGIC)
        return CrashReportReader.read(from: reporter.crashFilePath)?.isForeground
    }
}
