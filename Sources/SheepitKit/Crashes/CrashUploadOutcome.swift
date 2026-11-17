import Foundation

/// The `outcome` of a `transport.crash_upload` diagnostic — one value per branch a queued
/// crash report can take.
enum CrashUploadOutcome: String, CaseIterable {
    case uploaded
    /// The upload failed for a retryable reason; the report stays queued for the next launch.
    case retainedForRetry = "retained_for_retry"
    /// The server rejected the report in a way a retry cannot change (400/413/422).
    case droppedNonRetryable = "dropped_non_retryable"
    /// Out of counted attempts or older than `SDKDefaults.crashUploadMaxAge`.
    case droppedRetryExhausted = "dropped_retry_exhausted"
    /// Evicted, oldest first, to keep the queue at `SDKDefaults.crashPendingMaxReports`.
    case droppedQueueFull = "dropped_queue_full"
    /// The queued file is not a readable crash report.
    case droppedUnreadable = "dropped_unreadable"
    /// The previous session's report could not be moved out of the live file before the
    /// handler reused it.
    case droppedUnretainable = "dropped_unretainable"

    var severity: DiagnosticSeverity {
        switch self {
        case .uploaded: return .info
        case .retainedForRetry: return .warn
        case .droppedNonRetryable, .droppedRetryExhausted, .droppedQueueFull, .droppedUnreadable,
             .droppedUnretainable:
            return .error
        }
    }

    var message: String {
        switch self {
        case .uploaded: return "Crash report uploaded"
        case .retainedForRetry: return "Crash report upload failed; kept for the next launch"
        case .droppedNonRetryable: return "Crash report rejected by the server; dropped"
        case .droppedRetryExhausted: return "Crash report dropped after exhausting its retries"
        case .droppedQueueFull: return "Crash retry queue full; oldest report dropped"
        case .droppedUnreadable: return "Queued crash report is unreadable; dropped"
        case .droppedUnretainable: return "Crash report could not be kept for upload; dropped"
        }
    }
}
