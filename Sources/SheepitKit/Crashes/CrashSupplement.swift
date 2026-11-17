import Foundation
import SheepitCrashHandler

/// The crash supplement (sidecar) file a 0.10.1+ handler writes next to the frozen crash report:
/// trap-site registers, the crash-annotation message, per-image detail. Format and why it is a
/// separate file: `SheepitCrashSupplement.h`.
///
/// `load` returns nil — and the report is read exactly as before 0.10.1 — when the file is
/// missing, of another format, written for a different report (`report_timestamp_ms`), or
/// describes a different number of images than the report holds.
struct CrashSupplement: Sendable {
    struct Image: Sendable, Equatable {
        let isApp: Bool
        let cpuType: Int32
        let cpuSubtype: UInt32
        let vmaddrSlide: Int64
    }

    /// The annotation message, or an NSException's full reason; nil when empty.
    let message: String?
    let registers: CrashRegisters?
    /// The immediate of the trapping `brk` (arm64), when the crash was one.
    let brkImmediate: UInt32?
    let framesDropped: Int
    let osBuild: String?
    let arch: String?
    let sdkVersion: String?
    let imagesTruncated: Bool
    let identityCapture: CrashIdentityCapture
    var identityCohort: CrashIdentityCohort? { identityCapture.cohort }
    /// Parallel to the report's image table.
    let images: [Image]

    static func load(path: String, reportTimestampMs: UInt64, reportImageCount: Int) -> CrashSupplement? {
        guard let ptr = sheepit_read_crash_supplement(path, reportTimestampMs) else { return nil }
        defer { free(ptr) }
        guard Int(ptr.pointee.image_count) == reportImageCount else { return nil }

        let flags = ptr.pointee.flags
        let registers: CrashRegisters? = flags & UInt32(SHEEPIT_SUPPLEMENT_HAS_REGISTERS) == 0 ? nil : CrashRegisters(
            pc: hex(ptr.pointee.pc),
            lr: ptr.pointee.lr == 0 ? nil : hex(ptr.pointee.lr),
            fp: hex(ptr.pointee.fp),
            sp: hex(ptr.pointee.sp)
        )
        let message = CrashText.string(ptr.pointee.exception_message)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return CrashSupplement(
            message: message.isEmpty ? nil : message,
            registers: registers,
            brkImmediate: flags & UInt32(SHEEPIT_SUPPLEMENT_HAS_BRK) == 0 ? nil : ptr.pointee.brk_immediate,
            framesDropped: Int(ptr.pointee.frames_dropped),
            osBuild: CrashText.nonEmpty(CrashText.string(ptr.pointee.os_build)),
            arch: CrashText.nonEmpty(CrashText.string(ptr.pointee.arch)),
            sdkVersion: CrashText.nonEmpty(CrashText.string(ptr.pointee.sdk_version)),
            imagesTruncated: flags & UInt32(SHEEPIT_SUPPLEMENT_IMAGES_TRUNCATED) != 0,
            identityCapture: .read(path: path, timestamp: reportTimestampMs, imageCount: reportImageCount),
            images: images(ptr, count: reportImageCount)
        )
    }

    private static func images(_ ptr: UnsafeMutablePointer<sheepit_crash_supplement_t>, count: Int) -> [Image] {
        // Bind each C array in place; the typed pointer is valid only inside its closure.
        let isApp = withUnsafePointer(to: &ptr.pointee.is_app_image) {
            Array(UnsafeBufferPointer(start: UnsafeRawPointer($0).assumingMemoryBound(to: UInt8.self), count: count))
        }
        let cpuType = withUnsafePointer(to: &ptr.pointee.cpu_type) {
            Array(UnsafeBufferPointer(start: UnsafeRawPointer($0).assumingMemoryBound(to: Int32.self), count: count))
        }
        let cpuSubtype = withUnsafePointer(to: &ptr.pointee.cpu_subtype) {
            Array(UnsafeBufferPointer(start: UnsafeRawPointer($0).assumingMemoryBound(to: Int32.self), count: count))
        }
        let slide = withUnsafePointer(to: &ptr.pointee.vmaddr_slide) {
            Array(UnsafeBufferPointer(start: UnsafeRawPointer($0).assumingMemoryBound(to: Int64.self), count: count))
        }
        return (0..<count).map {
            Image(isApp: isApp[$0] != 0, cpuType: cpuType[$0], cpuSubtype: UInt32(bitPattern: cpuSubtype[$0]),
                  vmaddrSlide: slide[$0])
        }
    }

    /// A title for a `brk` trap that left no annotation message. Swift's runtime checks
    /// (force-unwrap of nil, array bounds, overflow) in an optimized build trap with `brk #1`
    /// and no text; so does C's `__builtin_trap()`.
    static func trapMessage(brkImmediate: UInt32) -> String {
        brkImmediate == 1
            ? "Swift runtime failure (brk #1)"
            : "Breakpoint trap (brk #0x\(String(brkImmediate, radix: 16)))"
    }

    /// The Mach exception a signal stands for on Darwin.
    static func machExceptionType(signal: Int32) -> String? {
        switch signal {
        case SIGSEGV, SIGBUS: return "EXC_BAD_ACCESS"
        case SIGILL: return "EXC_BAD_INSTRUCTION"
        case SIGFPE: return "EXC_ARITHMETIC"
        case SIGTRAP: return "EXC_BREAKPOINT"
        case SIGABRT: return "EXC_CRASH"
        default: return nil
        }
    }

    static func hex(_ value: UInt64) -> String {
        String(format: "0x%016llx", value)
    }

    static func signedHex(_ value: Int64) -> String {
        value < 0 ? "-0x" + String(value.magnitude, radix: 16) : "0x" + String(value, radix: 16)
    }
}

/// Strings out of the C crash structs.
enum CrashText {
    /// A C fixed-size char array (imported as a tuple) as a String, ending at the first NUL or the
    /// end of the array — a file from disk may carry no terminator. Invalid UTF-8 is repaired.
    static func string<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    static func nonEmpty(_ s: String) -> String? {
        s.isEmpty ? nil : s
    }
}
