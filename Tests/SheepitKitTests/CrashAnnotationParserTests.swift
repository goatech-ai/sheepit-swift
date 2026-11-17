import XCTest
import SheepitCrashHandler

/// `sheepit_parse_crash_annotations` against a synthetic `crashreporter_annotations_t`.
///
/// Exists because a Swift runtime failure traps with SIGTRAP and, before 0.10.1, reached the
/// server with an empty message — every one titled "SIGTRAP". The text lives in a
/// `__crash_info` section the struct below imitates (8 × uint64: version, message,
/// signature_string, backtrace, message2, thread, dialog_mode, abort_cause). Which image holds
/// it on a real device is only provable on one (plan U-2); this pins the parsing.
final class CrashAnnotationParserTests: XCTestCase {
    private struct Annotations {
        var version: UInt64
        var message: UInt64 = 0
        var signature: UInt64 = 0
        var backtrace: UInt64 = 0
        var message2: UInt64 = 0
        var thread: UInt64 = 0
        var dialogMode: UInt64 = 0
        var abortCause: UInt64 = 0
    }

    private func parse(_ annotations: Annotations, cap: Int = 1024) -> String {
        var a = annotations
        return withUnsafeBytes(of: &a) { raw in
            var out = [CChar](repeating: 0x7F, count: cap)
            let n = sheepit_parse_crash_annotations(
                UInt(bitPattern: raw.baseAddress), UInt64(raw.count), &out, cap
            )
            XCTAssertEqual(out[n], 0, "always terminated at the returned length")
            return String(cString: out)
        }
    }

    private func address(_ s: UnsafePointer<CChar>) -> UInt64 {
        UInt64(UInt(bitPattern: s))
    }

    func testReadsTheSwiftFatalErrorMessage() {
        let text = "Fatal error: Unexpectedly found nil while unwrapping an Optional value"
        text.withCString { msg in
            XCTAssertEqual(parse(Annotations(version: 5, message: address(msg))), text)
        }
    }

    func testAppendsMessage2AfterANewline() {
        "first".withCString { m1 in
            "second".withCString { m2 in
                XCTAssertEqual(parse(Annotations(version: 5, message: address(m1), message2: address(m2))),
                               "first\nsecond")
                XCTAssertEqual(parse(Annotations(version: 4, message2: address(m2))), "second")
            }
        }
    }

    func testAcceptsOnlyTheKnownVersions() {
        "x".withCString { msg in
            XCTAssertEqual(parse(Annotations(version: 7, message: address(msg))), "x")
            XCTAssertEqual(parse(Annotations(version: 3, message: address(msg))), "", "older layout")
            XCTAssertEqual(parse(Annotations(version: 6, message: address(msg))), "", "never seen")
        }
    }

    func testAnUnreadableMessagePointerYieldsNothingInsteadOfFaulting() {
        XCTAssertEqual(parse(Annotations(version: 5, message: 0x10)), "")
    }

    func testBoundedToTheBuffer() {
        let long = String(repeating: "a", count: 3000)
        long.withCString { msg in
            XCTAssertEqual(parse(Annotations(version: 5, message: address(msg)), cap: 1024).utf8.count, 1023)
        }
    }

    /// A message longer than the buffer keeps its prefix rather than vanishing.
    func testALongTerminatedMessageKeepsItsPrefix() {
        String(repeating: "b", count: 10_000).withCString { msg in
            XCTAssertEqual(parse(Annotations(version: 5, message: address(msg))).utf8.count, 1023)
        }
    }

    func testRejectsASectionTooSmallForTheHeader() {
        var out = [CChar](repeating: 0, count: 16)
        var a = Annotations(version: 5)
        let n = withUnsafeBytes(of: &a) { raw in
            sheepit_parse_crash_annotations(UInt(bitPattern: raw.baseAddress), 16, &out, 16)
        }
        XCTAssertEqual(n, 0)
    }

    /// A message pointer that is stale (into reused heap, say) is rejected unless a NUL follows
    /// within SHEEPIT_ANNOTATION_MAX_SCAN readable bytes: a run of non-NUL bytes up to an
    /// unmapped page is not uploaded as a crash reason.
    func testAStringWithNoTerminatorBeforeUnreadableMemoryIsRejected() throws {
        let page = Int(getpagesize())
        let base = try XCTUnwrap(mmap(nil, page * 2, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0))
        defer { munmap(base, page) }
        XCTAssertEqual(munmap(base + page, page), 0, "precondition: the second page is a hole")
        memset(base, 0x41, page)  // 'A' to the end of the mapping, no NUL
        let start = UInt64(UInt(bitPattern: base) + UInt(page) - 100)
        XCTAssertEqual(parse(Annotations(version: 5, message: start)), "")
    }

    // MARK: - Which images

    /// Another SDK's CRSetCrashLogMessage text, or any library's, must never be uploaded. The
    /// header decides, not the name: a name and a path are chosen by whoever ships the dylib, but
    /// only Apple's own libraries are in the dyld shared cache (MH_DYLIB_IN_CACHE).
    func testOnlyTheExecutableAndCachedRuntimesAreRead() {
        let dylib = UInt32(MH_DYLIB)
        let cached = UInt32(bitPattern: Int32(bitPattern: 0x8000_0000))  // MH_DYLIB_IN_CACHE
        let plain = UInt32(MH_TWOLEVEL)

        XCTAssertTrue(sheepit_annotation_image_allowed("/private/var/containers/Bundle/Application/X/Shop.app/Shop",
                                                       UInt32(MH_EXECUTE), plain), "the main executable")
        XCTAssertTrue(sheepit_annotation_image_allowed("/usr/lib/swift/libswiftCore.dylib", dylib, plain | cached))
        for runtime in ["libsystem_c.dylib", "libsystem_malloc.dylib", "libc++abi.dylib", "libobjc.A.dylib",
                        "libdispatch.dylib", "libswift_Concurrency.dylib"] {
            XCTAssertTrue(sheepit_annotation_image_allowed("/usr/lib/" + runtime, dylib, cached), runtime)
        }

        XCTAssertFalse(sheepit_annotation_image_allowed("/private/var/containers/Bundle/Application/X/Shop.app/Frameworks/libswiftCore.dylib",
                                                        dylib, plain), "a bundled copy is not in the cache")
        XCTAssertFalse(sheepit_annotation_image_allowed("/usr/lib/system/libsystem_evil.dylib", dylib, plain))
        XCTAssertFalse(sheepit_annotation_image_allowed("/tmp/libsystem_x.dylib", dylib, plain))
        XCTAssertFalse(sheepit_annotation_image_allowed("/System/Library/Frameworks/Foundation.framework/Foundation",
                                                        dylib, cached), "cached, but not a runtime we read")
        XCTAssertFalse(sheepit_annotation_image_allowed(nil, dylib, cached))

        XCTAssertTrue(sheepit_annotation_image_is_swift_runtime("/usr/lib/swift/libswiftCore.dylib", cached))
        XCTAssertFalse(sheepit_annotation_image_is_swift_runtime("/App.app/Frameworks/libswiftCore.dylib", plain),
                       "a bundled copy never wins over the app's own message")
    }

    /// A long message with no NUL in the scan window keeps its prefix when the window is readable.
    /// A stale `message` pointer into a reused buffer has no NUL nearby; uploading its prefix
    /// would send process memory as the crash message. The NUL-within-window rule is the guard.
    func testAnUnterminatedWindowIsRejectedNotTruncated() {
        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: 20_000)
        defer { buffer.deallocate() }
        buffer.initialize(repeating: 0x63, count: 20_000)  // 'c', no NUL
        let text = parse(Annotations(version: 5, message: UInt64(UInt(bitPattern: buffer))))
        XCTAssertEqual(text, "")
    }

    func testASectionMustLieInsideItsSegment() {
        XCTAssertTrue(sheepit_section_within_segment(0x1000, 0x40, 0x1000, 0x1000))
        XCTAssertTrue(sheepit_section_within_segment(0x1FC0, 0x40, 0x1000, 0x1000), "ends exactly at the end")
        XCTAssertFalse(sheepit_section_within_segment(0x1FC1, 0x40, 0x1000, 0x1000), "one byte past")
        XCTAssertFalse(sheepit_section_within_segment(0x0FFF, 0x40, 0x1000, 0x1000), "starts before")
        XCTAssertFalse(sheepit_section_within_segment(0x1000, UInt64.max, 0x1000, 0x1000), "size overflow")
        XCTAssertFalse(sheepit_section_within_segment(0x1000, 0, 0x1000, 0x1000), "empty")
    }

    func testTheSwiftRuntimesMessageWinsOverAnEarlierOne() {
        "abort reason".withCString { first in
            "Fatal error: swift".withCString { swift in
                var a = Annotations(version: 5, message: address(first))
                var b = Annotations(version: 5, message: address(swift))
                withUnsafeBytes(of: &a) { ra in
                    withUnsafeBytes(of: &b) { rb in
                        let sources = [
                            sheepit_annotation_source_t(section_addr: UInt(bitPattern: ra.baseAddress),
                                                        section_size: UInt64(ra.count), is_swift_runtime: false),
                            sheepit_annotation_source_t(section_addr: UInt(bitPattern: rb.baseAddress),
                                                        section_size: UInt64(rb.count), is_swift_runtime: true),
                        ]
                        var out = [CChar](repeating: 0, count: 1024)
                        _ = sheepit_read_crash_annotation_message(sources, 2, &out, 1024)
                        XCTAssertEqual(String(cString: out), "Fatal error: swift")
                        _ = sheepit_read_crash_annotation_message(sources, 1, &out, 1024)
                        XCTAssertEqual(String(cString: out), "abort reason", "the fallback when no Swift message")
                    }
                }
            }
        }
    }
}
