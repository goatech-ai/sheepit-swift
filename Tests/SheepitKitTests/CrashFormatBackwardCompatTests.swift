// Guards the FROZEN on-disk crash-report format. A crash file written by an
// older build — when the C module/symbols were LaunchPad-named (lp_*/LP_*) —
// must stay readable after a user updates to a Sheepit-named build. The rename
// (LPCrashHandler -> SheepitCrashHandler) kept the magic VALUES and struct
// layout byte-for-byte; these tests fail if a future change alters a magic
// value or reorders a struct field, BEFORE a shipped build silently drops
// users' pending crash reports. See SheepitCrashHandler.h "FROZEN" note.
import XCTest
import SheepitCrashHandler

final class CrashFormatBackwardCompatTests: XCTestCase {
    func testMagicValuesAreFrozen() {
        // Values are the ASCII of the original LaunchPad markers — do not change.
        XCTAssertEqual(Int(SHEEPIT_CRASH_REPORT_MAGIC), 0x4C50_4352,
                       "\"LPCR\" — changing this drops crash files written by older builds")
        XCTAssertEqual(Int(SHEEPIT_BREADCRUMB_MAGIC), 0x4C50_4252, "\"LPBR\"")
        XCTAssertEqual(Int(SHEEPIT_CRASH_CONTEXT_MAGIC), 0x4C50_4358, "\"LPCX\"")
    }

    func testReaderDetectsFileWrittenWithFrozenMagic() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sheepit-crash-backcompat-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }

        // Exactly what an older build stamped into the mmap'd report.
        var report = sheepit_crash_report_t()
        report.magic = UInt32(0x4C50_4352)
        let good = withUnsafeBytes(of: &report) { Data($0) }
        try good.write(to: url)
        XCTAssertTrue(sheepit_has_pending_crash_report(url.path),
                      "a crash file with the frozen magic must still be detected after the rename")

        // A file without the magic must NOT be treated as a pending report.
        report.magic = 0
        let bad = withUnsafeBytes(of: &report) { Data($0) }
        try bad.write(to: url)
        XCTAssertFalse(sheepit_has_pending_crash_report(url.path))
    }
}
