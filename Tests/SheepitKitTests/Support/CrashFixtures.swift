import Foundation
import XCTest
import SheepitCrashHandler
@testable import SheepitKit

/// Builds crash report and supplement files byte-for-byte as the C handler lays them out, so a
/// test can drive `CrashReportReader` without raising a signal. Both structs are built on the
/// heap: the report is ~320 KB, and async tests run on a 512 KB cooperative-pool stack.
enum CrashFixtures {
    /// One image (`AppCore`) at 0x1_0000_0000 with 0x10000 bytes of __TEXT, and one system
    /// image (`libsystem_kernel.dylib`) at 0x1_8000_0000.
    static let appLoad: UInt = 0x1_0000_0000
    static let systemLoad: UInt = 0x1_8000_0000
    static let imageSize: UInt = 0x10000
    static let timestampMs: UInt64 = 1_790_000_000_123

    static func setCString<T>(_ field: inout T, _ value: String) {
        withUnsafeMutableBytes(of: &field) { raw in
            let bytes = Array(value.utf8.prefix(raw.count - 1))
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
    }

    /// A report with the frozen magic: SIGTRAP, `threads` threads (the crashed one at
    /// `crashedIndex`), and two images. `imageName` names the first image.
    static func writeReport(
        to url: URL,
        threads: Int = 1,
        crashedIndex: Int = 0,
        frozenMessage: String = "",
        imageName: String = "AppCore",
        timestampMs: UInt64 = CrashFixtures.timestampMs,
        batteryLevel: UInt8 = 0,
        imageCount: UInt32 = 2,
        userId: String? = nil
    ) throws {
        let size = MemoryLayout<sheepit_crash_report_t>.size
        let raw = try XCTUnwrap(calloc(1, size))
        defer { free(raw) }
        let r = raw.assumingMemoryBound(to: sheepit_crash_report_t.self)
        r.pointee.signal_number = SIGTRAP
        r.pointee.timestamp_ms = timestampMs
        r.pointee.context.battery_level = batteryLevel
        setCString(&r.pointee.context.user_id, userId ?? "")
        setCString(&r.pointee.exception_type, "SIGTRAP")
        setCString(&r.pointee.mechanism, "signal")
        setCString(&r.pointee.exception_message, frozenMessage)

        r.pointee.images.image_count = imageCount
        withUnsafeMutablePointer(to: &r.pointee.images.images) { tuple in
            let images = UnsafeMutableRawPointer(tuple).assumingMemoryBound(to: sheepit_binary_image_t.self)
            images[0].load_address = appLoad
            images[0].size = imageSize
            setCString(&images[0].name, imageName)
            setCString(&images[0].uuid, "11111111-2222-3333-4444-555555555555")
            images[1].load_address = systemLoad
            images[1].size = imageSize
            setCString(&images[1].name, "libsystem_kernel.dylib")
            setCString(&images[1].uuid, "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        }

        r.pointee.threads.thread_count = UInt32(threads)
        withUnsafeMutablePointer(to: &r.pointee.threads.threads) { tuple in
            let states = UnsafeMutableRawPointer(tuple).assumingMemoryBound(to: sheepit_thread_state_t.self)
            for i in 0..<threads {
                states[i].thread_id = UInt64(1000 + i)
                states[i].is_crashed_thread = i == crashedIndex
                states[i].frame_count = 2
                withUnsafeMutablePointer(to: &states[i].frames) { frames in
                    let f = UnsafeMutableRawPointer(frames).assumingMemoryBound(to: UInt.self)
                    f[0] = appLoad + 0x100
                    f[1] = systemLoad + 0x200
                }
            }
        }
        r.pointee.magic = UInt32(SHEEPIT_CRASH_REPORT_MAGIC)
        try Data(bytes: raw, count: size).write(to: url)
    }

    /// A supplement for the report stamped `timestampMs`, with the first image marked as the
    /// app's, trap registers, and `message`.
    static func writeSupplement(
        to url: URL,
        message: String = "",
        brkImmediate: UInt32? = nil,
        imageCount: UInt32 = 2,
        timestampMs: UInt64 = CrashFixtures.timestampMs,
        formatVersion: UInt32 = UInt32(SHEEPIT_SUPPLEMENT_FORMAT_VERSION),
        magic: UInt32 = UInt32(SHEEPIT_SUPPLEMENT_MAGIC)
    ) throws {
        let size = MemoryLayout<sheepit_crash_supplement_t>.size
        let raw = try XCTUnwrap(calloc(1, size))
        defer { free(raw) }
        let s = raw.assumingMemoryBound(to: sheepit_crash_supplement_t.self)
        s.pointee.format_version = formatVersion
        s.pointee.report_timestamp_ms = timestampMs
        s.pointee.flags = UInt32(SHEEPIT_SUPPLEMENT_HAS_REGISTERS)
        s.pointee.pc = UInt64(appLoad + 0x100)
        s.pointee.lr = UInt64(appLoad + 0x80)
        s.pointee.fp = 0x16F0_0000
        s.pointee.sp = 0x16EF_FF00
        s.pointee.frames_dropped = 3
        if let brkImmediate {
            s.pointee.flags |= UInt32(SHEEPIT_SUPPLEMENT_HAS_BRK)
            s.pointee.brk_immediate = brkImmediate
        }
        setCString(&s.pointee.exception_message, message)
        setCString(&s.pointee.os_build, "23A100")
        setCString(&s.pointee.arch, "arm64")
        setCString(&s.pointee.sdk_version, "0.10.1")
        s.pointee.image_count = imageCount
        withUnsafeMutablePointer(to: &s.pointee.is_app_image) { UnsafeMutableRawPointer($0).storeBytes(of: 1, as: UInt8.self) }
        withUnsafeMutablePointer(to: &s.pointee.cpu_type) { UnsafeMutableRawPointer($0).storeBytes(of: 0x0100_000C, as: Int32.self) }
        withUnsafeMutablePointer(to: &s.pointee.vmaddr_slide) { UnsafeMutableRawPointer($0).storeBytes(of: 0x4000, as: Int64.self) }
        s.pointee.magic = magic
        try Data(bytes: raw, count: size).write(to: url)
    }

    static func tempDirectory(_ label: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sheepit-\(label)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The payload encoded the way `HTTPClient.postRaw` sends it, as a JSON object.
    static func wireJSON(_ payload: CrashReportPayload) throws -> [String: Any] {
        let data = try JSONEncoder().encode(payload)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
