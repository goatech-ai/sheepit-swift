import Foundation
import SheepitCrashHandler

/// Reads the mmap'd C crash report from a previous session and converts it
/// to a Swift `CrashReportPayload` for upload to the server.
enum CrashReportReader {

    /// Read a pending crash report from disk, with the supplement at `supplementPath` when one
    /// was written for it. Returns `nil` if no valid report exists.
    /// - Parameter breadcrumbLimit: the newest this many breadcrumbs are kept
    ///   (`CrashConfig.breadcrumbCapacity`, clamped to the C ring's `SHEEPIT_MAX_BREADCRUMBS`).
    static func read(
        from path: String,
        supplementPath: String? = nil,
        breadcrumbLimit: Int = Int(SHEEPIT_MAX_BREADCRUMBS)
    ) -> CrashReportPayload? {
        guard let reportPtr = sheepit_read_pending_crash_report(path) else { return nil }
        defer { free(reportPtr) }
        guard reportPtr.pointee.magic == SHEEPIT_CRASH_REPORT_MAGIC else { return nil }

        let imageCount = Int(clamping: reportPtr.pointee.images.image_count)
        let supplement = supplementPath.flatMap {
            CrashSupplement.load(path: $0, reportTimestampMs: reportPtr.pointee.timestamp_ms, reportImageCount: imageCount)
        }

        let ctx = reportPtr.pointee.context
        let identityCapture = supplement?.identityCapture ?? supplementPath.map {
            CrashIdentityCapture.read(path: $0, timestamp: reportPtr.pointee.timestamp_ms, imageCount: imageCount)
        } ?? .legacy
        let cohort = identityCapture.cohort
        let usesCohort = identityCapture.outcome != "legacy"
        let timestamp = ISO8601DateFormatter().string(
            from: Date(timeIntervalSince1970: Double(reportPtr.pointee.timestamp_ms) / 1000)
        )
        let mechanism = CrashText.nonEmpty(CrashText.string(reportPtr.pointee.mechanism))
        let exceptionType = CrashText.string(reportPtr.pointee.exception_type)
        let message = exceptionMessage(reportPtr, supplement: supplement, mechanism: mechanism)

        // Convert threads
        let threadInfo = convertThreads(reportPtr, supplement: supplement)

        // Build the crashed thread's stack as the top-level stack_trace
        let crashedThread = threadInfo.first { $0.isCrashed } ?? threadInfo.first
        let stackTrace = CrashStackTrace(
            frames: crashedThread?.frames ?? [],
            exception: CrashException(type: exceptionType, message: message, mechanism: mechanism)
        )

        let breadcrumbs = convertBreadcrumbs(reportPtr, limit: breadcrumbLimit)
        let binaryImages = convertBinaryImages(reportPtr, supplement: supplement)
        let signal = reportPtr.pointee.signal_number

        var payload = CrashReportPayload(
            // The device uploading is the device that crashed: the report is read on its next launch.
            platform: DeviceProfile.platform,
            appVersion: CrashText.string(ctx.app_version),
            buildNumber: CrashText.nonEmpty(CrashText.string(ctx.build_number)),
            osVersion: CrashText.nonEmpty(CrashText.string(ctx.os_version)),
            deviceModel: CrashText.nonEmpty(CrashText.string(ctx.device_model)),
            exceptionType: exceptionType,
            exceptionMessage: message,
            stackTrace: stackTrace,
            threadInfo: threadInfo.isEmpty ? nil : threadInfo,
            isForeground: ctx.is_foreground,
            freeMemoryMb: ctx.free_memory_mb > 0 ? Int(ctx.free_memory_mb) : nil,
            freeDiskMb: ctx.free_disk_mb > 0 ? Int(ctx.free_disk_mb) : nil,
            // Clamped: the schema is 0...100 and a 400 is permanent, so a corrupt byte from disk
            // must not cost the report.
            batteryLevel: ctx.battery_level > 0 ? Int(min(ctx.battery_level, 100)) : nil,
            screenName: CrashText.nonEmpty(CrashText.string(ctx.screen_name)),
            breadcrumbs: breadcrumbs.isEmpty ? nil : breadcrumbs,
            activeFlags: parseJSON(CrashText.string(ctx.active_flags_json)),
            activeExperiments: nil,
            customData: nil,
            userId: usesCohort ? cohort?.userId : CrashText.nonEmpty(CrashText.string(ctx.user_id)),
            sessionId: usesCohort ? cohort?.sessionId : CrashText.nonEmpty(CrashText.string(ctx.session_id)),
            deviceId: usesCohort ? cohort?.deviceId : CrashText.nonEmpty(CrashText.string(ctx.device_id)),
            networkType: nil,
            binaryImages: binaryImages.isEmpty ? nil : binaryImages,
            timestamp: timestamp
        )
        payload.captureIdentityOutcome = identityCapture.outcome
        // A cohort file written by an older build can carry both; a changed identity makes no claim.
        payload.assignmentToken = cohort?.identityChanged == true ? nil : cohort?.assignmentToken
        payload.assignmentStatus = cohort?.identityChanged == true ? "identity_changed" : nil
        payload.machExceptionType = signal != 0 ? CrashSupplement.machExceptionType(signal: signal) : nil
        if let supplement {
            payload.captureSdkVersion = supplement.sdkVersion
            payload.osBuild = supplement.osBuild
            payload.arch = supplement.arch
            payload.crashedThreadRegisters = supplement.registers
            payload.framesDropped = supplement.registers == nil ? nil : supplement.framesDropped
            payload.imagesTruncated = supplement.imagesTruncated ? true : nil
        }
        return payload
    }

    /// The supplement's message (up to 1023 bytes), else the frozen 512-byte field, else — for a
    /// `brk` trap that left no text — a title naming the trap. nil when there is none of these.
    private static func exceptionMessage(
        _ reportPtr: UnsafeMutablePointer<sheepit_crash_report_t>,
        supplement: CrashSupplement?,
        mechanism: String?
    ) -> String? {
        if let message = supplement?.message { return message }
        let frozen = CrashText.string(reportPtr.pointee.exception_message)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !frozen.isEmpty { return frozen }
        if mechanism == "signal", let brk = supplement?.brkImmediate {
            return CrashSupplement.trapMessage(brkImmediate: brk)
        }
        return nil
    }

    /// Serialize the C `sheepit_binary_image_list_t` into the wire-format array.
    private static func convertBinaryImages(
        _ reportPtr: UnsafeMutablePointer<sheepit_crash_report_t>,
        supplement: CrashSupplement?
    ) -> [CrashBinaryImage] {
        // Clamp to the C array capacity — a corrupt/truncated crash file from disk
        // could carry an inflated count and walk us off the fixed-size array.
        let count = Int(min(reportPtr.pointee.images.image_count, UInt32(SHEEPIT_MAX_IMAGES)))
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
                let uuid = CrashText.string(img.uuid)
                // Skip images with no UUID — symbolication can't use them.
                guard !uuid.isEmpty else { continue }
                var image = CrashBinaryImage(
                    uuid: uuid,
                    name: CrashText.string(img.name),
                    loadAddress: String(format: "0x%016llx", UInt64(img.load_address)),
                    size: UInt64(img.size)
                )
                // Indexed by the REPORT's position, before the UUID filter above.
                if let detail = supplement?.images[i] {
                    image.cpuType = detail.cpuType
                    image.cpuSubtype = detail.cpuSubtype
                    image.vmaddrSlide = CrashSupplement.signedHex(detail.vmaddrSlide)
                    image.isAppImage = detail.isApp
                }
                result.append(image)
            }
            return result
        }
    }

    // MARK: - Thread Conversion

    private static func convertThreads(
        _ reportPtr: UnsafeMutablePointer<sheepit_crash_report_t>,
        supplement: CrashSupplement?
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
                let frames = convertFrames(thread: threadsPtr + i, reportPtr: reportPtr, supplement: supplement)
                result.append(CrashThreadInfo(
                    threadId: t.thread_id,
                    name: CrashText.nonEmpty(CrashText.string(t.name)),
                    isCrashed: t.is_crashed_thread,
                    frames: frames
                ))
            }
            return result
        }
    }

    private static func convertFrames(
        thread: UnsafeMutablePointer<sheepit_thread_state_t>,
        reportPtr: UnsafeMutablePointer<sheepit_crash_report_t>,
        supplement: CrashSupplement?
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
                let image = findImage(for: addr, in: reportPtr, supplement: supplement)

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
        _ reportPtr: UnsafeMutablePointer<sheepit_crash_report_t>,
        limit: Int
    ) -> [CrashBreadcrumbPayload] {
        let ring = reportPtr.pointee.breadcrumbs
        guard ring.magic == UInt32(SHEEPIT_BREADCRUMB_MAGIC) else { return [] }

        // The ring always holds the last SHEEPIT_MAX_BREADCRUMBS; a smaller capacity keeps the newest.
        let count = min(Int(ring.count), Int(SHEEPIT_MAX_BREADCRUMBS), max(0, limit))
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
                    category: CrashText.string(entry.category),
                    message: CrashText.string(entry.message)
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
        in reportPtr: UnsafeMutablePointer<sheepit_crash_report_t>,
        supplement: CrashSupplement?
    ) -> ImageMatch? {
        // Clamp to the C array capacity (see convertBinaryImages).
        let imageCount = Int(min(reportPtr.pointee.images.image_count, UInt32(SHEEPIT_MAX_IMAGES)))
        guard imageCount > 0 else { return nil }

        // See convertBinaryImages: bind the C array in place; the typed pointer
        // is valid only inside the closure.
        return withUnsafeMutablePointer(to: &reportPtr.pointee.images.images) { imagesTuplePtr in
            let images = UnsafeMutableRawPointer(imagesTuplePtr)
                .assumingMemoryBound(to: sheepit_binary_image_t.self)

            for i in 0..<imageCount {
                let img = images[i]
                let start = UInt(img.load_address)
                if address >= start && address - start < UInt(img.size) {
                    let name = CrashText.string(img.name)
                    // The supplement knows from the image's full path whether it ships in the
                    // app bundle. Without one (a report captured before 0.10.1), the name
                    // heuristic, which misreads `libFoo.dylib` and any name containing "System".
                    let isApp = supplement?.images[i].isApp ?? (
                        !name.hasPrefix("lib") && !name.contains("swift")
                            && !name.contains("System") && !name.contains("Foundation")
                            && !name.contains("UIKit") && !name.contains("CoreFoundation")
                    )
                    return ImageMatch(name: name, loadAddress: UInt(img.load_address), isApp: isApp)
                }
            }
            return nil
        }
    }

    // MARK: - Helpers

    private static func parseJSON(_ json: String) -> [String: AnyCodable]? {
        guard !json.isEmpty, json != "{}",
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return dict.mapValues { AnyCodable($0) }
    }
}
