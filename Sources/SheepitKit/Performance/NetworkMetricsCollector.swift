import Foundation

/// Captures URLSession task metrics and reports network performance data.
final class NetworkMetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let onMetric: @Sendable (PerformanceMetric) -> Void

    init(onMetric: @escaping @Sendable (PerformanceMetric) -> Void) {
        self.onMetric = onMetric
        super.init()
    }

    // MARK: - URLSessionTaskDelegate

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        guard let interval = metrics.transactionMetrics.last else { return }
        let durationMs = metrics.taskInterval.duration * 1000

        let statusCode = (task.response as? HTTPURLResponse)?.statusCode
        let isError = statusCode.map { $0 >= 400 } ?? false
        let url = task.originalRequest?.url?.absoluteString ?? "unknown"

        onMetric(PerformanceMetric(
            metricType: "network",
            metricName: url,
            valueMs: durationMs,
            statusCode: statusCode,
            isError: isError,
            timestamp: ISO8601DateFormatter().string(from: Date())
        ))

        // Report DNS lookup time if available
        if interval.fetchStartDate != nil,
           let domainEnd = interval.domainLookupEndDate,
           let domainStart = interval.domainLookupStartDate {
            let dnsMs = domainEnd.timeIntervalSince(domainStart) * 1000
            if dnsMs > 0 {
                onMetric(PerformanceMetric(
                    metricType: "network",
                    metricName: "dns_lookup",
                    valueMs: dnsMs,
                    statusCode: nil,
                    isError: false,
                    timestamp: ISO8601DateFormatter().string(from: Date())
                ))
            }
        }

        // Report TLS handshake time if available
        if let secureStart = interval.secureConnectionStartDate,
           let secureEnd = interval.secureConnectionEndDate {
            let tlsMs = secureEnd.timeIntervalSince(secureStart) * 1000
            if tlsMs > 0 {
                onMetric(PerformanceMetric(
                    metricType: "network",
                    metricName: "tls_handshake",
                    valueMs: tlsMs,
                    statusCode: nil,
                    isError: false,
                    timestamp: ISO8601DateFormatter().string(from: Date())
                ))
            }
        }
    }
}
