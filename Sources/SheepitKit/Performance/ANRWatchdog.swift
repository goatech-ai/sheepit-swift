import Foundation

/// What the watchdog state machine wants to emit at each tick. Pure
/// data — no Foundation/Dispatch dependency — so the tick logic is
/// unit-testable without simulating real timers or freezing the main
/// thread.
enum ANRWatchdogTick: Equatable {
    case none
    case detected(thresholdMs: Double)
    case recovered(durationMs: Double)
}

/// Pure state machine for ANR detection. Inputs: did the last main-thread
/// ping respond, and what time is it. Output: the metric (if any) to emit
/// + the next state. Audit R-004 — split out so we can prove the state
/// transitions correctness without bringing the deadlock-prone bits
/// (DispatchQueue.main.sync) anywhere near the test surface.
struct ANRWatchdogState: Equatable {
    /// nil when the main thread is responsive; otherwise the wall-clock
    /// time of the first ping that failed for the current contiguous
    /// freeze. Reset to nil on the first responsive ping that follows.
    var freezeStartedAt: Date?

    static func transition(
        previous: ANRWatchdogState,
        responded: Bool,
        now: Date,
        thresholdMs: Double
    ) -> (next: ANRWatchdogState, tick: ANRWatchdogTick) {
        if !responded {
            if previous.freezeStartedAt == nil {
                // First detection of this contiguous freeze → emit
                // anr_detected exactly once for the freeze. We do NOT
                // capture a backtrace here: the only way to capture
                // main's stack from a background thread is mach
                // thread-state plumbing, which is queued as follow-up.
                // Crucially we never schedule a block onto main —
                // that's the very thing that's hung (R-004 deadlock).
                return (
                    ANRWatchdogState(freezeStartedAt: now),
                    .detected(thresholdMs: thresholdMs)
                )
            }
            // Already mid-freeze: stay in the same state, no new event.
            return (previous, .none)
        }
        // Main responded.
        if let start = previous.freezeStartedAt {
            // Recovery from a tracked freeze → emit duration.
            let durationMs = now.timeIntervalSince(start) * 1000.0
            return (ANRWatchdogState(freezeStartedAt: nil), .recovered(durationMs: durationMs))
        }
        // Healthy steady state.
        return (previous, .none)
    }
}

/// Detects Application Not Responding (ANR) events by pinging the main thread
/// from a background thread and measuring response time.
final class ANRWatchdog: @unchecked Sendable {
    private let onMetric: @Sendable (PerformanceMetric) -> Void
    /// Internal, not private, so a test can prove out-of-range input was clamped WITHOUT
    /// running `watchdogLoop()` for real — see `minThresholdMs`'s doc for why that would be
    /// unsafe. Not part of the public surface.
    internal let thresholdMs: Double
    private var watchdogThread: Thread?
    private var isRunning = false
    private var state = ANRWatchdogState(freezeStartedAt: nil)

    private(set) var anrCount = 0

    /// Floor for `thresholdMs`, clamped HERE — the actual consumer — mirroring the
    /// `EventQueue.init` pattern (`max(1, maxSize)`) rather than trusting a clamp on
    /// `PerformanceConfig.anrThresholdMs`'s initializer, which would be bypassable the exact
    /// way `flushInterval`/`configRefreshInterval`/`maxQueueSize` were: `anrThresholdMs` is a
    /// mutable public `var`, so `var cfg = ...; cfg.performance.anrThresholdMs = 0` reaches
    /// this initializer already unclamped (2026-09 security follow-up round 3, finding MF-1,
    /// pattern repeated here as round 4, finding MF3-3 — the MF-1 sweep covered every
    /// `Task.sleep` site but missed this `Thread.sleep` one). `watchdogLoop()` divides this by
    /// 1000 to get `checkInterval`, which drives BOTH the `Thread.sleep` at the bottom of the
    /// loop AND the `DispatchSemaphore.wait` timeout inside `pingMainThread`. At `<= 0`,
    /// `Thread.sleep(forTimeInterval:)` returns immediately and the loop spins, enqueuing an
    /// unbounded `DispatchQueue.main.async` per iteration with no backpressure — measured RSS
    /// 21.5 -> 70.8 MB in 0.5s, SIGKILL (exit 137) at ~0.7s. `.nan` was already benign (Swift's
    /// `max` returns the non-NaN operand when one side is NaN, so `max(minThresholdMs, .nan)`
    /// evaluates to `minThresholdMs`), so this floor incidentally also covers it. Unlike
    /// `TimeInterval.sanitizedForSleep()` (seconds, floor `1.0`), this constant is
    /// MILLISECONDS — the unit `PerformanceConfig.anrThresholdMs` is documented in — so the
    /// two floors are not interchangeable.
    private static let minThresholdMs: Double = 100
    /// Ceiling for `thresholdMs`, same rationale and same bypass as the floor above. Generous
    /// (10 minutes) for any real ANR-detection cadence, but bounded so a host that mutates
    /// `anrThresholdMs` to an astronomical value doesn't leave the watchdog checking main-
    /// thread responsiveness once an hour.
    private static let maxThresholdMs: Double = 600_000

    init(thresholdMs: Double, onMetric: @escaping @Sendable (PerformanceMetric) -> Void) {
        self.thresholdMs = min(Self.maxThresholdMs, max(Self.minThresholdMs, thresholdMs))
        self.onMetric = onMetric
    }

    /// Start the ANR watchdog on a background thread.
    func start() {
        guard !isRunning else { return }
        isRunning = true

        let thread = Thread { [weak self] in
            self?.watchdogLoop()
        }
        thread.name = "ai.goatech.sdk.anr-watchdog"
        thread.qualityOfService = .utility
        thread.start()
        watchdogThread = thread
    }

    /// Stop the ANR watchdog.
    func stop() {
        isRunning = false
        watchdogThread?.cancel()
        watchdogThread = nil
    }

    // MARK: - Private

    private func watchdogLoop() {
        let checkInterval = thresholdMs / 1000.0

        while isRunning && !Thread.current.isCancelled {
            let responded = pingMainThread(timeout: checkInterval)

            // Audit R-004: never call DispatchQueue.main.sync from this
            // thread. The previous implementation captured a backtrace
            // via main.sync after detecting a hang — but main.sync on a
            // hung main queue blocks the watchdog indefinitely (the very
            // condition we just detected), and the captured local was
            // then discarded. The state machine below emits the
            // detection event immediately + emits a recovery event with
            // the measured freeze duration when main eventually
            // responds. No main-thread sync, no deadlock, no lost data.
            let (next, tick) = ANRWatchdogState.transition(
                previous: state,
                responded: responded,
                now: Date(),
                thresholdMs: thresholdMs
            )
            state = next

            switch tick {
            case .none:
                break
            case .detected(let thresholdMs):
                anrCount += 1
                onMetric(PerformanceMetric(
                    metricType: "anr",
                    metricName: "anr_detected",
                    valueMs: thresholdMs,
                    statusCode: nil,
                    isError: true,
                    timestamp: ISO8601DateFormatter().string(from: Date())
                ))
            case .recovered(let durationMs):
                onMetric(PerformanceMetric(
                    metricType: "anr",
                    metricName: "anr_recovered",
                    valueMs: durationMs,
                    statusCode: nil,
                    isError: false,
                    timestamp: ISO8601DateFormatter().string(from: Date())
                ))
            }

            Thread.sleep(forTimeInterval: checkInterval)
        }
    }

    private func pingMainThread(timeout: TimeInterval) -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            semaphore.signal()
        }
        let result = semaphore.wait(timeout: .now() + timeout)
        return result == .success
    }
}
