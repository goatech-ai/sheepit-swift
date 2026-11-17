import XCTest
import SheepitCrashHandler

/// The decidable parts of the 0.10.1 signal handler (`SheepitCrashCapture.h`), driven with
/// synthetic stacks and image tables. CI cannot raise a real signal on a device, so this is what
/// stands between a regression and a crash report that is lost or wrong in the field.
final class CrashStackWalkTests: XCTestCase {
    private var images: UnsafeMutablePointer<sheepit_binary_image_list_t>!

    override func setUp() {
        super.setUp()
        images = UnsafeMutablePointer<sheepit_binary_image_list_t>.allocate(capacity: 1)
        memset(images, 0, MemoryLayout<sheepit_binary_image_list_t>.size)
        images.pointee.image_count = 1
        withUnsafeMutablePointer(to: &images.pointee.images) {
            let list = UnsafeMutableRawPointer($0).assumingMemoryBound(to: sheepit_binary_image_t.self)
            list[0].load_address = 0x1_0000_0000
            list[0].size = 0x10000
        }
    }

    override func tearDown() {
        images.deallocate()
        super.tearDown()
    }

    // MARK: - Pointer auth

    /// U-3: nobody could say which bits a signature occupies on every device. The mask is derived
    /// from the highest loaded image instead, so it can never strip a real address bit.
    func testCodeMaskCoversEveryAddressBelowTheHighestImageEnd() {
        XCTAssertEqual(sheepit_code_mask_for_end(0x2_0000_0000), 0x1_FFFF_FFFF)
        XCTAssertEqual(sheepit_code_mask_for_end(0x1_8001_0000), 0x1_FFFF_FFFF)
        XCTAssertEqual(sheepit_code_mask_for_end(0), UInt.max, "no images: strip nothing")
    }

    func testStripPacRemovesSignatureBitsAndKeepsTheAddress() {
        let mask = sheepit_code_mask_for_end(0x2_0000_0000)
        let signed: UInt = 0x002A_8001_0000_1234  // signature bits above bit 33
        XCTAssertEqual(sheepit_strip_pac(signed, mask), 0x1_0000_1234)
        XCTAssertEqual(sheepit_strip_pac(0x1_0000_1234, mask), 0x1_0000_1234, "an unsigned address is unchanged")
    }

    func testImageIndexIsHalfOpen() {
        XCTAssertEqual(sheepit_image_index_for_addr(0x1_0000_0000, images), 0)
        XCTAssertEqual(sheepit_image_index_for_addr(0x1_0000_FFFF, images), 0)
        XCTAssertEqual(sheepit_image_index_for_addr(0x1_0001_0000, images), -1)
        XCTAssertEqual(sheepit_image_index_for_addr(0, images), -1)
    }

    func testFramePointerPlausibility() {
        let sp: UInt = 0x16F0_0000
        XCTAssertTrue(sheepit_fp_plausible(sp + 0x40, 0, sp))
        XCTAssertFalse(sheepit_fp_plausible(0, 0, sp), "null")
        XCTAssertFalse(sheepit_fp_plausible(sp + 0x41, 0, sp), "misaligned")
        XCTAssertFalse(sheepit_fp_plausible(sp - 0x10, 0, sp), "below the stack pointer")
        XCTAssertFalse(sheepit_fp_plausible(sp + 0x40, sp + 0x40, sp), "not strictly increasing")
        XCTAssertFalse(sheepit_fp_plausible(sp + UInt(SHEEPIT_MAX_STACK_SPAN) + 0x10, 0, sp), "too far from sp")
    }

    // MARK: - The walk

    /// A two-page mapping: frame records in the first page, the second unmapped. A chain that
    /// runs into the hole must END — before 0.10.1 the raw dereference faulted inside the signal
    /// handler, losing the report and skipping the chained handler.
    func testWalkKeepsImageFramesDropsOthersAndStopsAtAnUnmappedRecord() throws {
        let page = Int(getpagesize())
        let base = try XCTUnwrap(mmap(nil, page * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0))
        XCTAssertNotEqual(base, MAP_FAILED)
        defer { munmap(base, page) }
        XCTAssertEqual(munmap(base + page, page), 0, "precondition: the second page is a hole")

        let sp = UInt(bitPattern: base)
        let words = base.assumingMemoryBound(to: UInt.self)
        let fp1 = sp + 0x20
        let fp2 = sp + 0x40
        let hole = sp + UInt(page) + 0x10  // plausible-looking, but unmapped
        // record at fp1: caller fp2, a return address inside the image (signed)
        words[0x20 / 8] = fp2
        words[0x20 / 8 + 1] = 0x0055_0001_0000_0300
        // record at fp2: caller in the hole, a return address in no image
        words[0x40 / 8] = hole
        words[0x40 / 8 + 1] = 0x0000_0001_8000_0000

        var seed = sheepit_register_seed_t(pc: 0x1_0000_0100, lr: 0x1_0000_0200, fp: fp1, sp: sp, has_lr: true)
        var out = [UInt](repeating: 0, count: 16)
        var dropped: UInt32 = 0
        let mask = sheepit_code_mask_for_end(0x2_0000_0000)
        let n = sheepit_walk_stack(&seed, images, mask, false, &out, 16, &dropped)

        XCTAssertEqual(Array(out.prefix(Int(n))), [0x1_0000_0100, 0x1_0000_0200, 0x1_0000_0300])
        XCTAssertEqual(dropped, 1, "the return address in no image is dropped, not reported")
    }

    func testWalkSkipsTheFirstRecordWhenItRepeatsTheLinkRegister() {
        let record = UnsafeMutableRawPointer.allocate(byteCount: 16, alignment: 16)
        defer { record.deallocate() }
        let words = record.assumingMemoryBound(to: UInt.self)
        words[0] = 0
        words[1] = 0x1_0000_0200  // fp[1] == lr: the function saved LR already
        let fp = UInt(bitPattern: record)
        var seed = sheepit_register_seed_t(pc: 0x1_0000_0100, lr: 0x1_0000_0200, fp: fp, sp: fp, has_lr: true)
        var out = [UInt](repeating: 0, count: 8)
        let n = sheepit_walk_stack(&seed, images, UInt.max, false, &out, 8, nil)
        XCTAssertEqual(Array(out.prefix(Int(n))), [0x1_0000_0100, 0x1_0000_0200])
    }

    func testTruncatedImageTableKeepsUnmatchedFrames() {
        var seed = sheepit_register_seed_t(pc: 0x7_0000_0000, lr: 0, fp: 0, sp: 0, has_lr: false)
        var out = [UInt](repeating: 0, count: 4)
        var dropped: UInt32 = 9
        XCTAssertEqual(sheepit_walk_stack(&seed, images, UInt.max, true, &out, 4, &dropped), 1)
        XCTAssertEqual(dropped, 0)
        XCTAssertEqual(sheepit_walk_stack(&seed, images, UInt.max, false, &out, 4, &dropped), 0)
        XCTAssertEqual(dropped, 1)
    }

    // MARK: - Safe reads

    func testSafeReadRefusesUnmappedMemoryInsteadOfFaulting() {
        var byte: UInt8 = 0
        XCTAssertFalse(sheepit_safe_read(0x10, &byte, 1))
        XCTAssertFalse(sheepit_safe_read(0, &byte, 1))
        var buf = [CChar](repeating: 1, count: 8)
        XCTAssertEqual(sheepit_safe_read_cstring(0x10, &buf, 8), 0)
        XCTAssertEqual(buf[0], 0, "always terminated")
    }

    func testSafeCStringIsBoundedAndCutsOnACharacterBoundary() {
        let text = "ab\u{00E9}"  // 61 62 C3 A9
        text.withCString { src in
            var out = [CChar](repeating: 0, count: 4)  // room for 3 bytes: would split é
            let n = sheepit_safe_read_cstring(UInt(bitPattern: src), &out, 4)
            XCTAssertEqual(n, 2)
            XCTAssertEqual(String(cString: out), "ab")
        }
    }

    // MARK: - Trap and bundle helpers

    func testBrkImmediateDecoding() {
        var imm: UInt32 = 0
        XCTAssertTrue(sheepit_decode_brk_immediate(0xD420_0020, &imm))
        XCTAssertEqual(imm, 1, "brk #1 — the Swift runtime's trap")
        XCTAssertTrue(sheepit_decode_brk_immediate(0xD43E_0000, &imm))
        XCTAssertEqual(imm, 0xF000)
        XCTAssertFalse(sheepit_decode_brk_immediate(0xD503_201F, &imm), "nop")
    }

    func testAppBundlePrefix() {
        func prefix(_ path: String) -> String {
            var out = [CChar](repeating: 0, count: 1024)
            _ = sheepit_app_bundle_prefix(path, &out, 1024)
            return String(cString: out)
        }
        XCTAssertEqual(prefix("/private/var/containers/Bundle/Application/X/Shop.app/Shop"),
                       "/private/var/containers/Bundle/Application/X/Shop.app/")
        XCTAssertEqual(prefix("/Applications/Shop.app/Contents/MacOS/Shop"), "/Applications/Shop.app/",
                       "macOS: the bundle root, so Contents/Frameworks counts as the app's")
        XCTAssertEqual(prefix("/usr/local/bin/tool"), "/usr/local/bin/")
    }
}
