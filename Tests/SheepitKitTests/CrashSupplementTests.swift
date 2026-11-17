import XCTest
import SheepitCrashHandler
@testable import SheepitKit

/// The crash supplement sidecar (0.10.1): what it adds to a report, and that a report without
/// one — written by 0.8.0, or whose sidecar was lost — still reads exactly as before. The frozen
/// report struct cannot grow (`CrashFormatBackwardCompatTests`), so this file is the only place
/// new capture data can live; a reader that required it would drop every pending report on
/// upgrade.
final class CrashSupplementTests: XCTestCase {
    private var dir: URL!
    private var report: URL { dir.appendingPathComponent("r.crash") }
    private var sidecar: URL { dir.appendingPathComponent("r.supplement") }

    override func setUp() {
        super.setUp()
        dir = CrashFixtures.tempDirectory("crash-supplement")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        super.tearDown()
    }

    func testSupplementRoundTrip() throws {
        try CrashFixtures.writeReport(to: report, frozenMessage: "Fatal error: cut at 512")
        let full = "Fatal error: Unexpectedly found nil while unwrapping an Optional value\n"
        try CrashFixtures.writeSupplement(to: sidecar, message: full)

        let payload = try XCTUnwrap(CrashReportReader.read(from: report.path, supplementPath: sidecar.path))
        XCTAssertEqual(payload.exceptionMessage, full.trimmingCharacters(in: .whitespacesAndNewlines),
                       "the supplement's message wins over the frozen 512-byte field")
        XCTAssertEqual(payload.stackTrace.exception.message, payload.exceptionMessage)
        XCTAssertEqual(payload.exceptionType, "SIGTRAP", "exception_type stays the signal name — it groups crashes")
        XCTAssertEqual(payload.machExceptionType, "EXC_BREAKPOINT")
        XCTAssertEqual(payload.captureSdkVersion, "0.10.1")
        XCTAssertEqual(payload.osBuild, "23A100")
        XCTAssertEqual(payload.arch, "arm64")
        XCTAssertEqual(payload.framesDropped, 3)
        XCTAssertEqual(payload.crashedThreadRegisters?.pc, "0x0000000100000100")
        XCTAssertEqual(payload.crashedThreadRegisters?.lr, "0x0000000100000080")

        let images = try XCTUnwrap(payload.binaryImages)
        XCTAssertEqual(images.map(\.isAppImage), [true, false])
        XCTAssertEqual(images.first?.cpuType, 0x0100_000C)
        XCTAssertEqual(images.first?.vmaddrSlide, "0x4000")

        // `is_app_frame` comes from the image's path (via the supplement), not its name.
        let frames = payload.stackTrace.frames
        XCTAssertEqual(frames.map(\.isAppFrame), [true, false])
    }

    /// The pre-0.10.1 name heuristic misread an app framework called `libFoo`; the supplement
    /// overrides it.
    func testSupplementOverridesTheNameHeuristicForALibPrefixedAppFramework() throws {
        try CrashFixtures.writeReport(to: report, imageName: "libShopKit.dylib")
        try CrashFixtures.writeSupplement(to: sidecar)
        let withSidecar = try XCTUnwrap(CrashReportReader.read(from: report.path, supplementPath: sidecar.path))
        XCTAssertEqual(withSidecar.stackTrace.frames.first?.isAppFrame, true)
        let without = try XCTUnwrap(CrashReportReader.read(from: report.path))
        XCTAssertEqual(without.stackTrace.frames.first?.isAppFrame, false, "heuristic fallback, unchanged")
    }

    func testReportWithoutSidecarReadsAsBefore() throws {
        try CrashFixtures.writeReport(to: report)
        let payload = try XCTUnwrap(CrashReportReader.read(from: report.path, supplementPath: sidecar.path))
        XCTAssertNil(payload.exceptionMessage)
        XCTAssertNil(payload.captureSdkVersion, "unknown capturing version: never claim the uploader's")
        XCTAssertNil(payload.crashedThreadRegisters)
        XCTAssertNil(payload.binaryImages?.first?.isAppImage)
        XCTAssertEqual(payload.stackTrace.frames.map(\.isAppFrame), [true, false])
        let json = try CrashFixtures.wireJSON(payload)
        XCTAssertNil(json["sdk_version"])
        XCTAssertNil(json["crashed_thread_registers"])
    }

    /// A sidecar left by an earlier crash (a downgrade in between) must never attach to a newer
    /// report: `report_timestamp_ms` is the correlation key.
    func testStaleSidecarIsIgnored() throws {
        try CrashFixtures.writeReport(to: report)
        try CrashFixtures.writeSupplement(to: sidecar, message: "stale", timestampMs: CrashFixtures.timestampMs - 1)
        let payload = try XCTUnwrap(CrashReportReader.read(from: report.path, supplementPath: sidecar.path))
        XCTAssertNil(payload.exceptionMessage)
        XCTAssertNil(payload.captureSdkVersion)
    }

    func testSidecarOfAnotherFormatOrImageCountIsIgnored() throws {
        try CrashFixtures.writeReport(to: report)
        for write in [
            { try CrashFixtures.writeSupplement(to: self.sidecar, message: "m", formatVersion: 2) },
            { try CrashFixtures.writeSupplement(to: self.sidecar, message: "m", magic: 0) },
            { try CrashFixtures.writeSupplement(to: self.sidecar, message: "m", imageCount: 3) },
        ] as [() throws -> Void] {
            try write()
            let payload = try XCTUnwrap(CrashReportReader.read(from: report.path, supplementPath: sidecar.path))
            XCTAssertNil(payload.exceptionMessage)
        }
    }

    func testBrkTrapWithoutAMessageIsNamed() throws {
        try CrashFixtures.writeReport(to: report)
        try CrashFixtures.writeSupplement(to: sidecar, brkImmediate: 1)
        let payload = try XCTUnwrap(CrashReportReader.read(from: report.path, supplementPath: sidecar.path))
        XCTAssertEqual(payload.exceptionMessage, "Swift runtime failure (brk #1)")
    }

    // MARK: - Pending queue

    func testPendingStoreKeepsTheSidecarWithItsReportAcrossRetries() throws {
        let live = dir.appendingPathComponent("current.crash")
        let liveSidecar = dir.appendingPathComponent("current.supplement")
        try CrashFixtures.writeReport(to: live)
        try CrashFixtures.writeSupplement(to: liveSidecar, message: "kept")
        let store = PendingCrashStore(directory: dir.appendingPathComponent("pending", isDirectory: true))

        let entry = try XCTUnwrap(store.adopt(liveFile: live, liveSupplement: liveSidecar, now: Date(), maxReports: 5).entry)
        XCTAssertFalse(FileManager.default.fileExists(atPath: liveSidecar.path))
        let retried = store.recordAttempt(entry)
        XCTAssertEqual(store.entries(), [retried], "the sidecar is not listed as a report, nor deleted")
        let payload = try XCTUnwrap(CrashReportReader.read(
            from: retried.url.path, supplementPath: store.supplementURL(for: retried).path
        ))
        XCTAssertEqual(payload.exceptionMessage, "kept")

        store.remove(retried)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.supplementURL(for: retried).path))
    }

    func testOrphanedSidecarIsDeleted() throws {
        let pending = dir.appendingPathComponent("pending", isDirectory: true)
        try FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        let orphan = pending.appendingPathComponent("gone.supplement")
        try Data([1]).write(to: orphan)
        XCTAssertEqual(PendingCrashStore(directory: pending).entries(), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
    }
}
