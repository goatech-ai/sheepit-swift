import XCTest
import SheepitCrashHandler
@testable import SheepitKit

/// Coverage for D-2: `CrashReporter.updateContext()` left `app_version`/`build_number`/
/// `os_version`/`device_model` at their zeroed C defaults. The C struct reserved those
/// fields since it was written, and `CrashReportReader` already read all four back
/// (`CrashReportReader.swift:44-47`) — so a crash always shipped `app_version: ""` and the
/// other three `nil`, with nothing anywhere signaling the gap.
///
/// 🔴 The ONLY test in this suite that drives the process-global C crash-handler singleton
/// (`sheepit_crash_handler_install`/`_uninstall`) — every other file deliberately avoids it
/// (see `SessionStartEmissionTests`'s doc: a LIVE client with crashes enabled crashed the
/// suite ~20-30% of runs). This test never raises a signal, installs into a throwaway temp
/// file (not the SDK's real `current.crash` path), and uninstalls in `defer` before
/// returning — the window where handlers are live never overlaps an actual fault and never
/// leaks into another test's process state.
final class CrashContextDeviceProfileTests: XCTestCase {
    func testUpdateContextFillsTheDeviceProfileFieldsCrashReportReaderAlreadyExpects() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sheepit-crash-device-profile-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertEqual(sheepit_crash_handler_install(url.path), 0, "precondition: handler must install")
        defer { sheepit_crash_handler_uninstall() }

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
            storage: InMemoryStorage(),
            log: Logger(debug: false)
        )
        reporter.updateContext()

        // updateContext() only stamps the CONTEXT sub-struct's own magic — a real crash
        // report additionally needs the top-level REPORT magic, which production sets only
        // from inside the actual signal handler. Write it directly into the mmap'd region
        // (same pages as the file: CrashReportReader reads via a plain `read()`, which sees
        // a MAP_SHARED write immediately, no msync needed) so this test can drive a genuine
        // round trip without raising a real signal.
        let ctx = try XCTUnwrap(sheepit_get_crash_context(), "the handler must be installed by now")
        let contextOffset = MemoryLayout<sheepit_crash_report_t>.offset(of: \.context)!
        let magicOffset = MemoryLayout<sheepit_crash_report_t>.offset(of: \.magic)!
        UnsafeMutableRawPointer(ctx)
            .advanced(by: magicOffset - contextOffset)
            .assumingMemoryBound(to: UInt32.self)
            .pointee = UInt32(SHEEPIT_CRASH_REPORT_MAGIC)

        let payload = try XCTUnwrap(
            CrashReportReader.read(from: url.path),
            "a report with both magic values set must be read back"
        )

        // Compared against DeviceProfile's own live values rather than hardcoded
        // non-empty/non-nil expectations — `Bundle.main` inside an XCTest host may or may
        // not carry a CFBundleShortVersionString, so the only environment-independent
        // assertion is "whatever DeviceProfile computed is what came back."
        XCTAssertEqual(payload.appVersion, DeviceProfile.appVersion() ?? "")
        XCTAssertEqual(payload.buildNumber, DeviceProfile.buildNumber())
        XCTAssertEqual(payload.osVersion, DeviceProfile.osVersion())
        XCTAssertEqual(payload.deviceModel, DeviceProfile.deviceModel())

        // osVersion/deviceModel are guaranteed non-empty regardless of host environment —
        // the non-UIKit fallback is ProcessInfo's version string / the literal "Mac", never
        // "". Pin that down explicitly so this test still means something in an environment
        // where CFBundleShortVersionString happens to be absent.
        XCTAssertFalse(payload.osVersion?.isEmpty ?? true)
        XCTAssertFalse(payload.deviceModel?.isEmpty ?? true)
    }
}
