import Foundation
import SheepitCrashHandler

/// Reads the mmap'd C crash report from a previous session and converts it
/// to a Swift `CrashReportPayload` for upload to the server.
enum CrashReportReader {

    /// Read a pending crash report from disk.
    /// Returns `nil` if no valid report exists.
    static func read(from path: String) -> CrashReportPayload? {
        guard let reportPtr = sheepit_read_pending_crash_report(path) else { return nil }
        defer { reportPtr.deallocate() }

        let r = reportPtr.pointee
        guard r.magic == SHEEPIT_CRASH_REPORT_MAGIC else { return nil }

        let ctx = r.context
        let iso = ISO8601DateFormatter()
        let timestamp = iso.string(from: Date(timeIntervalSince1970: Double(r.timestamp_ms) / 1000))

        // Convert threads
        let threadInfo = convertThreads(reportPtr)

        // Build the crashed thread's stack as the top-level stack_trace
        let crashedThread = threadInfo.first { $0.isCrashed } ?? threadInfo.first
        let stackFrames = crashedThread?.frames ?? []

        let stackTrace = CrashStackTrace(
            frames: stackFrames,
            exception: CrashException(
                type: tupleString(r.exception_type),
                message: emptyToNil(tupleString(r.exception_message)),
                mechanism: emptyToNil(tupleString(r.mechanism))
            )
        )

        let breadcrumbs = convertBreadcrumbs(reportPtr)
        let activeFlags = parseJSON(tupleString(ctx.active_flags_json))
        let activeExperiments = parseJSON(tupleString(ctx.active_experiments_json))
        let binaryImages = convertBinaryImages(reportPtr)

        return CrashReportPayload(
            platform: "ios",
            appVersion: tupleString(ctx.app_version),
            buildNumber: emptyToNil(tupleString(ctx.build_number)),
            osVersion: emptyToNil(tupleString(ctx.os_version)),
            deviceModel: emptyToNil(tupleString(ctx.device_model)),
            exceptionType: tupleString(r.exception_type),
            exceptionMessage: emptyToNil(tupleString(r.exception_message)),
            stackTrace: stackTrace,
            threadInfo: threadInfo.isEmpty ? nil : threadInfo,
            isForeground: ctx.is_foreground,
            freeMemoryMb: ctx.free_memory_mb > 0 ? Int(ctx.free_memory_mb) : nil,
            freeDiskMb: ctx.free_disk_mb > 0 ? Int(ctx.free_disk_mb) : nil,
            batteryLevel: ctx.battery_level > 0 ? Int(ctx.battery_level) : nil,
            screenName: emptyToNil(tupleString(ctx.screen_name)),
            breadcrumbs: breadcrumbs.isEmpty ? nil : breadcrumbs,
            activeFlags: activeFlags,
            activeExperiments: activeExperiments,
            customData: nil,
            userId: emptyToNil(tupleString(ctx.user_id)),
            sessionId: emptyToNil(tupleString(ctx.session_id)),
            deviceId: emptyToNil(tupleString(ctx.device_id)),
            networkType: nil,
            binaryImages: binaryImages.isEmpty ? nil : binaryImages,
            timestamp: timestamp
        )
    }

    /// Serialize the C `sheepit_binary_image_list_t` into the wire-format array.
    /// Dropped earlier revisions of this reader discarded the UUID field —
    /// phase 1 of crash symbolication restores it.
    private static func convertBinaryImages(
        _ reportPtr: UnsafeMutablePointer<sheepit_crash_report_t>
    ) -> [CrashBinaryImage] {
        // Clamp to the C array capacity — a corrupt/truncated crash file from disk
        // could carry an inflated count and walk us off the fixed-size array.
        let count = min(Int(reportPtr.pointee.images.image_count), Int(SHEEPIT_MAX_IMAGES))
        guard count > 0 else { return [] }

        // Bind the C fixed-size array in place: the typed element pointer is only
        // valid for the closure body, so all indexing happens inside. Forming it
        // via `UnsafeMutableRawPointer(&reportPtr.pointee...)` and using it after
        // the call returned was dangling-pointer UB (the inout-derived pointer is
        // guaranteed only for the init call).
        return withUnsafeMutablePointer(to: &reportPtr.pointee.images.images) { imagesTuplePtr in
            let images = UnsafeMutableRawPointer(imagesTuplePtr)
                .assumingMemoryBound(to: sheepit_binary_image_t.self)

            var result: [CrashBinaryImage] = []
            for i in 0..<count {
                let img = images[i]
                let uuid = tupleString(img.uuid)
                // Skip images with no UUID — symbolication can't use them.
                guard !uuid.isEmpty else { continue }
                result.append(CrashBinaryImage(
                    uuid: uuid,
                    name: tupleString(img.name),
                    loadAddress: String(format: "0x%016llx", UInt64(img.load_address)),
                    size: UInt64(img.size)
                ))
            }
            return result
        }
    }

    // MARK: - Thread Conversion

    private static func convertThreads(
        _ reportPtr: UnsafeMutablePointer<sheepit_crash_report_t>
    ) -> [CrashThreadInfo] {
        // Clamp to the C array capacity (see convertBinaryImages).
        let count = min(Int(reportPtr.pointee.threads.thread_count), Int(SHEEPIT_MAX_THREADS))
        guard count > 0 else { return [] }

        // See convertBinaryImages: bind the C array in place; the typed pointer
        // is valid only inside the closure.
        return withUnsafeMutablePointer(to: &reportPtr.pointee.threads.threads) { threadsTuplePtr in
            let threadsPtr = UnsafeMutableRawPointer(threadsTuplePtr)
                .assumingMemoryBound(to: sheepit_thread_state_t.self)

            var result: [CrashThreadInfo] = []
            for i in 0..<count {
                let t = threadsPtr[i]
                let frames = convertFrames(thread: threadsPtr + i, reportPtr: reportPtr)
                result.append(CrashThreadInfo(
                    threadId: t.thread_id,
                    name: emptyToNil(tupleString(t.name)),
                    isCrashed: t.is_crashed_thread,
                    frames: frames
                ))
            }
            return result
        }
    }

    private static func convertFrames(
        thread: UnsafeMutablePointer<sheepit_thread_state_t>,
        reportPtr: UnsafeMutablePointer<sheepit_crash_report_t>
    ) -> [CrashStackFrame] {
        // Clamp to the C array capacity (see convertBinaryImages).
        let frameCount = min(Int(thread.pointee.frame_count), Int(SHEEPIT_MAX_FRAMES))
        guard frameCount > 0 else { return [] }

        // See convertBinaryImages: bind the C array in place; the typed pointer
        // is valid only inside the closure.
        return withUnsafeMutablePointer(to: &thread.pointee.frames) { framesTuplePtr in
            let addrs = UnsafeMutableRawPointer(framesTuplePtr)
                .assumingMemoryBound(to: UInt.self)

            var result: [CrashStackFrame] = []
            for i in 0..<frameCount {
                let addr = addrs[i]
                let image = findImage(for: addr, in: reportPtr)

                result.append(CrashStackFrame(
                    index: i,
                    function: nil,
                    imageName: image?.name,
                    rawAddress: String(format: "0x%016llx", UInt64(addr)),
                    symbolAddress: nil,
                    imageAddress: image.map { String(format: "0x%016llx", UInt64($0.loadAddress)) },
                    isAppFrame: image?.isApp ?? false
                ))
            }
            return result
        }
    }

    // MARK: - Breadcrumb Conversion

    private static func convertBreadcrumbs(
        _ reportPtr: UnsafeMutablePointer<sheepit_crash_report_t>
    ) -> [CrashBreadcrumbPayload] {
        let ring = reportPtr.pointee.breadcrumbs
        guard ring.magic == UInt32(SHEEPIT_BREADCRUMB_MAGIC) else { return [] }

        let count = min(Int(ring.count), Int(SHEEPIT_MAX_BREADCRUMBS))
        guard count > 0 else { return [] }

        let writeIdx = Int(ring.write_index)
        let iso = ISO8601DateFormatter()

        // See convertBinaryImages: bind the C array in place; the typed pointer
        // is valid only inside the closure.
        return withUnsafeMutablePointer(to: &reportPtr.pointee.breadcrumbs.entries) { entriesTuplePtr in
            let entries = UnsafeMutableRawPointer(entriesTuplePtr)
                .assumingMemoryBound(to: sheepit_breadcrumb_t.self)

            var result: [CrashBreadcrumbPayload] = []
            for i in 0..<count {
                let idx = (writeIdx - count + i + Int(SHEEPIT_MAX_BREADCRUMBS)) % Int(SHEEPIT_MAX_BREADCRUMBS)
                let entry = entries[idx]

                result.append(CrashBreadcrumbPayload(
                    timestamp: iso.string(from: Date(timeIntervalSince1970: Double(entry.timestamp_ms) / 1000)),
                    category: tupleString(entry.category),
                    message: tupleString(entry.message)
                ))
            }
            return result
        }
    }

    // MARK: - Image Lookup

    private struct ImageMatch {
        let name: String
        let loadAddress: UInt
        let isApp: Bool
    }

    private static func findImage(
        for address: UInt,
        in reportPtr: UnsafeMutablePointer<sheepit_crash_report_t>
    ) -> ImageMatch? {
        // Clamp to the C array capacity (see convertBinaryImages).
        let imageCount = min(Int(reportPtr.pointee.images.image_count), Int(SHEEPIT_MAX_IMAGES))
        guard imageCount > 0 else { return nil }

        // See convertBinaryImages: bind the C array in place; the typed pointer
        // is valid only inside the closure.
        return withUnsafeMutablePointer(to: &reportPtr.pointee.images.images) { imagesTuplePtr in
            let images = UnsafeMutableRawPointer(imagesTuplePtr)
                .assumingMemoryBound(to: sheepit_binary_image_t.self)

            for i in 0..<imageCount {
                let img = images[i]
                let start = UInt(img.load_address)
                let end = start + UInt(img.size)
                if address >= start && address < end {
                    let name = tupleString(img.name)
                    let isApp = !name.hasPrefix("lib") && !name.contains("swift")
                        && !name.contains("System") && !name.contains("Foundation")
                        && !name.contains("UIKit") && !name.contains("CoreFoundation")
                    return ImageMatch(name: name, loadAddress: UInt(img.load_address), isApp: isApp)
                }
            }
            return nil
        }
    }

    // MARK: - Helpers

    /// Convert a C fixed-size char array (exposed as a tuple) to a Swift String.
    private static func tupleString<T>(_ tuple: T) -> String {
        withUnsafePointer(to: tuple) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout<T>.size) { cstr in
                String(cString: cstr)
            }
        }
    }

    private static func emptyToNil(_ s: String) -> String? {
        s.isEmpty ? nil : s
    }

    private static func parseJSON(_ json: String) -> [String: AnyCodable]? {
        guard !json.isEmpty, json != "{}",
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return dict.mapValues { AnyCodable($0) }
    }
}
