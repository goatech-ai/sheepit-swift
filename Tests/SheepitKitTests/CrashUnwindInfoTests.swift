import XCTest
import SheepitCrashHandler

/// `sheepit_unwind_lookup` / `sheepit_lr_is_live` against synthetic `__TEXT,__unwind_info`
/// sections (layout: <mach-o/compact_unwind.h>). They decide whether the link register is
/// recorded as frame 1: wrong, and every report either shows the crashing function twice or
/// loses the caller of a frameless leaf such as `objc_msgSend`.
final class CrashUnwindInfoTests: XCTestCase {
    private let frame: UInt32 = 0x0400_0000      // UNWIND_ARM64_MODE_FRAME
    private let frameless: UInt32 = 0x0200_0000  // UNWIND_ARM64_MODE_FRAMELESS

    private struct Bytes {
        var data: [UInt8] = []
        mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    }

    /// Header, one common encoding (FRAME), a two-entry first-level index (functions 0x1000…,
    /// sentinel 0x3000) and one second-level page at offset 56.
    private func header(into b: inout Bytes) {
        b.u32(1); b.u32(28); b.u32(1); b.u32(0); b.u32(0); b.u32(32); b.u32(2)  // 28 bytes
        b.u32(frame)                                                             // common[0] at 28
        b.u32(0x1000); b.u32(56); b.u32(0)                                       // index[0] at 32
        b.u32(0x3000); b.u32(0); b.u32(0)                                        // sentinel
    }

    private func regularSection() -> [UInt8] {
        var b = Bytes()
        header(into: &b)
        b.u32(2); b.u16(8); b.u16(2)                     // REGULAR page: entries at page+8
        b.u32(0x1000); b.u32(frame)
        b.u32(0x2000); b.u32(frameless)
        return b.data
    }

    private func compressedSection() -> [UInt8] {
        var b = Bytes()
        header(into: &b)
        b.u32(3); b.u16(12); b.u16(2); b.u16(20); b.u16(1)  // COMPRESSED: entries at +12, encodings at +20
        b.u32(0x000 | (0 << 24))                              // base+0x000, common[0] = FRAME
        b.u32(0x1000 | (1 << 24))                             // base+0x1000, local[0] = FRAMELESS
        b.u32(frameless)
        return b.data
    }

    private func lookup(_ section: [UInt8], _ pc: UInt32) -> (encoding: UInt32, start: UInt32)? {
        section.withUnsafeBufferPointer { buf in
            var encoding: UInt32 = 0
            var start: UInt32 = 0
            let found = sheepit_unwind_lookup(UInt(bitPattern: buf.baseAddress), UInt64(buf.count), pc, &encoding, &start)
            return found ? (encoding, start) : nil
        }
    }

    func testRegularPageFindsTheContainingFunction() {
        let s = regularSection()
        XCTAssertEqual(lookup(s, 0x1000)?.encoding, frame)
        XCTAssertEqual(lookup(s, 0x1FFF)?.start, 0x1000)
        XCTAssertEqual(lookup(s, 0x2008)?.encoding, frameless)
        XCTAssertNil(lookup(s, 0x0FFF), "before the first function")
        XCTAssertNil(lookup(s, 0x3000), "at the sentinel")
    }

    func testCompressedPageResolvesCommonAndPageLocalEncodings() {
        let s = compressedSection()
        XCTAssertEqual(lookup(s, 0x1010)?.encoding, frame, "common encoding")
        XCTAssertEqual(lookup(s, 0x2010)?.encoding, frameless, "page-local encoding")
        XCTAssertEqual(lookup(s, 0x2010)?.start, 0x2000)
    }

    func testTruncatedOrForeignSectionsAreRejectedNotRead() {
        let s = regularSection()
        XCTAssertNil(lookup(Array(s.prefix(60)), 0x1010), "page cut short")
        var wrongVersion = s
        wrongVersion[0] = 2
        XCTAssertNil(lookup(wrongVersion, 0x1010))
        XCTAssertNil(lookup([], 0x1010))
    }

    func testLinkRegisterLivenessByEncoding() {
        XCTAssertTrue(sheepit_lr_is_live(frameless, 0x1100, 0x1000), "a frameless leaf never saves LR")
        XCTAssertTrue(sheepit_lr_is_live(frame, 0x1008, 0x1000), "still in the prologue")
        XCTAssertFalse(sheepit_lr_is_live(frame, 0x1100, 0x1000), "past the prologue: LR is stale")
        XCTAssertFalse(sheepit_lr_is_live(0x0500_0000, 0x1100, 0x1000), "arm64e FRAME_PAUTH_LR")
        XCTAssertTrue(sheepit_lr_is_live(0x0300_0000, 0x1100, 0x1000), "DWARF-only: no evidence")
        XCTAssertTrue(sheepit_lr_is_live(0, 0x1100, 0x1000), "no unwind info")
    }
}
