import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Tracks memory usage using Mach task_info and detects memory warnings.
final class MemoryTracker: @unchecked Sendable {
    private let onMetric: @Sendable (PerformanceMetric) -> Void
    private var timer: Timer?

    private(set) var peakMemoryBytes: UInt64 = 0
    private(set) var currentMemoryBytes: UInt64 = 0

    init(onMetric: @escaping @Sendable (PerformanceMetric) -> Void) {
        self.onMetric = onMetric
    }

    /// Start periodic memory tracking.
    func start(interval: TimeInterval = 10.0) {
        sample()

        #if canImport(UIKit)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleMemoryWarning),
            name: UIApplication.didReceiveMemoryWarningNotification,
            object: nil
        )
        #endif

        let t = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.sample()
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// Stop memory tracking.
    func stop() {
        timer?.invalidate()
        timer = nil
        #if canImport(UIKit)
        NotificationCenter.default.removeObserver(self)
        #endif
    }

    /// Take a single memory sample.
    func sample() {
        let bytes = residentMemoryBytes()
        currentMemoryBytes = bytes
        if bytes > peakMemoryBytes {
            peakMemoryBytes = bytes
        }
    }

    /// Report current memory as a metric.
    func reportMetric() {
        sample()
        let mb = Double(currentMemoryBytes) / (1024 * 1024)
        onMetric(PerformanceMetric(
            metricType: "memory",
            metricName: "memory_usage",
            valueMs: mb,
            statusCode: nil,
            isError: false,
            timestamp: ISO8601DateFormatter().string(from: Date())
        ))
    }

    /// Peak memory in megabytes.
    var peakMemoryMb: Double {
        Double(peakMemoryBytes) / (1024 * 1024)
    }

    // MARK: - Private

    private func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let result = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rawPtr in
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rawPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return info.resident_size
    }

    #if canImport(UIKit)
    @objc private func handleMemoryWarning() {
        sample()
        let mb = Double(currentMemoryBytes) / (1024 * 1024)
        onMetric(PerformanceMetric(
            metricType: "memory",
            metricName: "memory_warning",
            valueMs: mb,
            statusCode: nil,
            isError: true,
            timestamp: ISO8601DateFormatter().string(from: Date())
        ))
    }
    #endif
}
