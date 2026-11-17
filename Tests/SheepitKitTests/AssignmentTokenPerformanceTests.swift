import XCTest
@testable import SheepitKit

/// Performance windows, spans, ANR and sampling follow the identity they were measured under (split from
/// `AssignmentTokenSnapshotTests`, structural only).
final class AssignmentTokenPerformanceTests: XCTestCase {
    private func assignments(_ count: Int = 500) throws -> [String: SDKExperimentAssignment] {
        let value = try JSONDecoder().decode(SDKExperimentAssignment.self,
            from: Data(#"{"variant_key":"treatment","payload":{}}"#.utf8))
        return Dictionary(uniqueKeysWithValues: (0..<count).map { ("experiment-\($0)", value) })
    }

    private func context(token: String, user: String? = nil, device: String? = nil,
                         version: String = "1", build: String = "10") -> PerfBatchContext {
        let manager = ContextManager(storage: InMemoryStorage())
        if let user { manager.setUserId(user) }
        manager.setDeviceId(device ?? "test-device")
        let captured = PerfBatchContext.capture(manager.eventContext(), appVersion: version, receipt: AssignmentReceipt(token: token))
        var result = PerfBatchContext(platform: captured.platform, appVersion: captured.appVersion, buildNumber: build,
            osVersion: captured.osVersion, deviceModel: captured.deviceModel, userId: captured.userId,
            sessionId: captured.sessionId, deviceId: captured.deviceId, country: captured.country,
            networkType: nil, activeFlags: nil)
        result.assignmentToken = captured.assignmentToken
        return result
    }

    func testAliasRefreshKeepsTheWindowButAUserSwitchRestartsItWithTheNewUsersReceipt() {
        let current = LockedBox(context(token: "receipt-a", user: "a"))
        let epoch = IdentityEpoch()
        let captured = LockedBox<[PerformanceMetric]>([])
        let tracker = FrameTracker(slowFrameThresholdMs: 16, frozenFrameThresholdMs: 700,
            captureContext: { current.get() }, epoch: epoch, onMetric: { metric in captured.mutate { $0.append(metric) } })
        tracker.recordFrame(durationMs: 5)
        current.set(context(token: "receipt-randomized-a", user: "a"))
        tracker.recordFrame(durationMs: 20)
        tracker.reportSummary()
        // identify(b): what `identify()` does inside its gate section.
        current.set(context(token: "receipt-b", user: "b"))
        epoch.advanceWindow()
        tracker.recordFrame(durationMs: 800)
        tracker.recordFrame(durationMs: 10)
        tracker.reportSummary()
        let actual = captured.get()
        XCTAssertEqual(actual.map(\.metricName), ["slow_frame", "frame_summary", "frozen_frame", "frame_summary"])
        XCTAssertEqual(actual.first?.context?.assignmentToken, "receipt-randomized-a", "an emitted frame uses its measurement-completion context")
        let summaries = actual.filter { $0.metricName == "frame_summary" }
        XCTAssertEqual(summaries.map(\.valueMs), [2, 2], "an alias keeps the window; the switch restarted it")
        XCTAssertEqual(summaries[0].context?.userId, "a")
        XCTAssertEqual(summaries[0].context?.assignmentToken, "receipt-a", "the window's start context, across an alias refresh")
        XCTAssertEqual(summaries[1].context?.userId, "b")
        XCTAssertEqual(summaries[1].context?.assignmentToken, "receipt-b")
        let frozen = actual.first { $0.metricName == "frozen_frame" }
        XCTAssertEqual(frozen?.context?.userId, "b", "the frozen frame spanning the identity change carries the completion-time user")
        XCTAssertEqual(frozen?.context?.assignmentToken, "receipt-b")
        XCTAssertEqual(tracker.totalFrameCount, 2)
        XCTAssertEqual(tracker.frozenFrameCount, 1)
    }

    /// The window is rolled eagerly by the epoch, but a report must also catch an identity that moved
    /// without it: A's receipt never rides frames counted for B.
    func testFrameSummaryNeverShipsAPreviousUsersReceiptEvenBeforeTheWindowRolls() {
        let current = LockedBox(context(token: "receipt-a", user: "a"))
        let metrics = LockedBox<[PerformanceMetric]>([])
        let tracker = FrameTracker(slowFrameThresholdMs: 16, frozenFrameThresholdMs: 700,
            captureContext: { current.get() }, onMetric: { metric in metrics.mutate { $0.append(metric) } })
        tracker.recordFrame(durationMs: 5)
        current.set(context(token: "receipt-b", user: "b"))
        tracker.recordFrame(durationMs: 5)
        tracker.reportSummary()
        let mixed = metrics.get().last
        XCTAssertEqual(mixed?.metricName, "frame_summary")
        XCTAssertNil(mixed?.context?.assignmentToken, "a receipt issued for a is not a claim about b's frames")
        XCTAssertNil(mixed?.context?.assignmentStatus)
        XCTAssertNil(mixed?.context?.userId, "the counts are the old window's: no user, device or receipt")
        XCTAssertNil(mixed?.context?.deviceId)
        XCTAssertEqual(tracker.totalFrameCount, 0, "the mixed window is closed")
        tracker.recordFrame(durationMs: 5)
        tracker.reportSummary()
        XCTAssertEqual(metrics.get().last?.context?.assignmentToken, "receipt-b")
    }

    func testResetDoesNotShipAnEmptyFrameSummaryUnderTheNewIdentity() {
        let current = LockedBox(context(token: "receipt-a", user: "a"))
        let epoch = IdentityEpoch()
        let metrics = LockedBox<[PerformanceMetric]>([])
        let tracker = FrameTracker(slowFrameThresholdMs: 16, frozenFrameThresholdMs: 700,
            captureContext: { current.get() }, epoch: epoch, onMetric: { metric in metrics.mutate { $0.append(metric) } })
        tracker.recordFrame(durationMs: 5)
        epoch.advance()
        current.set(context(token: "receipt-b", user: "b"))
        tracker.reportSummary()
        XCTAssertTrue(metrics.get().isEmpty, "a window restarted by a reset with no frames reports nothing")
    }

    func testStartupAndWarmStartUseTheirIntervalStartReceipt() {
        let current = LockedBox(context(token: "cold-start"))
        let metrics = LockedBox<[PerformanceMetric]>([])
        let startup = StartupTracker(captureContext: { current.get() }, onMetric: { metric in metrics.mutate { $0.append(metric) } })
        current.set(context(token: "after-cold-start"))
        startup.markFirstFrame()
        XCTAssertEqual(metrics.get().first?.context?.assignmentToken, "cold-start")
        startup.markWarmStart()
        current.set(context(token: "after-warm-start"))
        startup.markFirstFrame()
        XCTAssertEqual(metrics.get().last?.context?.assignmentToken, "after-cold-start")
    }

    private func monitor(current: LockedBox<PerfBatchContext>) -> PerformanceMonitor {
        let http = HTTPClient(config: SheepitConfig(apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64),
            apiUrl: "https://stub.invalid", retryAttempts: 1), log: Logger(debug: false),
            urlProtocolClasses: [StubURLProtocol.self])
        return PerformanceMonitor(http: http, context: ContextManager(storage: InMemoryStorage()),
            config: PerformanceConfig(enabled: true, startupTrackingEnabled: false, frameTrackingEnabled: false,
                memoryTrackingEnabled: false, maxBatchSize: 100), appVersionOverride: nil, log: Logger(debug: false),
            captureContext: { current.get() })
    }

    func testMetricReceiptAndFullIdentitySurviveFlushAndRetry() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        let current = LockedBox(context(token: "receipt-a", user: "a", device: "before-c5", version: "1", build: "10"))
        let monitor = monitor(current: current)
        let timestamp = "2026-11-10T10:00:00.123Z"
        await monitor.addMetric(PerformanceMetric(metricType: "memory", metricName: "memory_usage", valueMs: 12,
            statusCode: nil, isError: false, timestamp: timestamp))
        current.set(context(token: "receipt-b", user: "b", device: "after-c5", version: "2", build: "20"))
        await monitor.addMetric(PerformanceMetric(metricType: "memory", metricName: "memory_usage", valueMs: 13,
            statusCode: nil, isError: false, timestamp: timestamp))
        StubURLProtocol.stub = .status(500, body: "{}")
        await monitor.flush()
        current.set(context(token: "receipt-latest", user: "latest"))
        StubURLProtocol.stub = .status(200, body: "{}")
        await monitor.flush()
        XCTAssertEqual(StubURLProtocol.requestBodies.count, 2)
        for data in StubURLProtocol.requestBodies {
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let metrics = try XCTUnwrap(body["batch"] as? [[String: Any]])
            let contexts = metrics.compactMap { $0["context"] as? [String: Any] }
            XCTAssertEqual(contexts.compactMap { $0["assignment_token"] as? String }, ["receipt-a", "receipt-b"])
            XCTAssertEqual(contexts.compactMap { $0["user_id"] as? String }, ["a", "b"])
            XCTAssertEqual(metrics.compactMap { $0["timestamp"] as? String }, [timestamp, timestamp])
            XCTAssertEqual(contexts.compactMap { $0["device_id"] as? String }, ["before-c5", "after-c5"])
            XCTAssertEqual(contexts.compactMap { $0["app_version"] as? String }, ["1", "2"])
            XCTAssertEqual(contexts.compactMap { $0["build_number"] as? String }, ["10", "20"])
            XCTAssertTrue(contexts.allSatisfy { $0["device_id"] != nil && $0["app_version"] != nil })
            XCTAssertTrue(contexts.allSatisfy { $0["active_experiments"] == nil })
            let envelope = try XCTUnwrap(body["context"] as? [String: Any])
            XCTAssertNil(envelope["user_id"], "the batch envelope names nobody; each metric carries its own")
            XCTAssertNil(envelope["assignment_token"])
            XCTAssertNil(envelope["device_id"])
        }
    }

    func testSpanReceiptIsCapturedBeforeDeliveryAndConfigChange() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        let current = LockedBox(context(token: "span-start"))
        let monitor = monitor(current: current)
        _ = await monitor.startSpan("checkout")
        current.set(context(token: "span-end"))
        _ = await monitor.endSpan("checkout")
        StubURLProtocol.stub = .status(200, body: "{}")
        await monitor.flush()
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(StubURLProtocol.requestBodies.last)) as? [String: Any])
        let metric = try XCTUnwrap((body["batch"] as? [[String: Any]])?.first)
        XCTAssertEqual((metric["context"] as? [String: Any])?["assignment_token"] as? String, "span-start")
    }

    private func stubHTTP() -> HTTPClient {
        HTTPClient(config: SheepitConfig(apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64),
            apiUrl: "https://stub.invalid", retryAttempts: 1), log: Logger(debug: false),
            urlProtocolClasses: [StubURLProtocol.self])
    }

    /// Flushes until `name` has shipped: reset() starts its own flush, and a flush that finds one running returns.
    private func flushUntilShipped(_ monitor: PerformanceMonitor, _ name: String,
                                   type: String = "span") async -> [String: [String: Any]] {
        let deadline = Date().addingTimeInterval(3)
        while true {
            await monitor.flush()
            let spans = shippedSpans(StubURLProtocol.requestBodies, type: type)
            if spans[name] != nil || Date() > deadline { return spans }
            await Task.yield()
        }
    }

    private func shippedSpans(_ bodies: [Data], type: String = "span") -> [String: [String: Any]] {
        var out: [String: [String: Any]] = [:]
        for data in bodies {
            guard let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let batch = body["batch"] as? [[String: Any]] else { continue }
            for metric in batch where metric["metric_type"] as? String == type {
                out[metric["metric_name"] as? String ?? ""] = metric["context"] as? [String: Any]
            }
        }
        return out
    }

    func testSpanOpenAcrossAnIdentityChangeShipsNeitherTheOldIdentityNorItsReceipt() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        let current = LockedBox(context(token: "receipt-a", user: "a", device: "device-a"))
        let monitor = monitor(current: current)
        _ = await monitor.startSpan("open-across")
        _ = await monitor.startSpan("control")
        _ = await monitor.endSpan("control")
        monitor.identityDidChange()
        current.set(context(token: "receipt-b", user: "b", device: "device-b"))
        _ = await monitor.endSpan("open-across")
        _ = await monitor.startSpan("after")
        _ = await monitor.endSpan("after")
        StubURLProtocol.stub = .status(200, body: "{}")
        await monitor.flush()
        let spans = shippedSpans(StubURLProtocol.requestBodies)
        XCTAssertEqual(spans["control"]?["user_id"] as? String, "a", "a span inside one identity keeps it")
        XCTAssertEqual(spans["control"]?["assignment_token"] as? String, "receipt-a")
        let stale = try XCTUnwrap(spans["open-across"])
        for key in ["user_id", "session_id", "device_id", "assignment_token", "assignment_status"] {
            XCTAssertNil(stale[key], "\(key) of the previous identity must not ride a span ended after the change")
        }
        XCTAssertEqual(spans["after"]?["user_id"] as? String, "b")
    }

    @MainActor
    func testClientResetInvalidatesAnOpenSpanBeforeItReturns() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        SharedSDKStorage.clear()
        defer { SharedSDKStorage.clear() }
        let client = SheepitClient.createForTesting(config: SheepitConfig(
            apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64), apiUrl: "https://stub.invalid",
            flushInterval: 3600, configRefreshInterval: 3600, retryAttempts: 1,
            performance: PerformanceConfig(enabled: true, startupTrackingEnabled: false, frameTrackingEnabled: false,
                memoryTrackingEnabled: false, flushInterval: 3600)), now: { Date() },
            urlProtocolClasses: [StubURLProtocol.self])
        defer { client.destroy() }
        let field = try XCTUnwrap(Mirror(reflecting: client).children.first { $0.label == "performanceMonitor" }?.value)
        let monitor = try XCTUnwrap((field as? PerformanceMonitor)
            ?? (Mirror(reflecting: field).children.first?.value as? PerformanceMonitor))
        client.context.setUserId("user-a")
        _ = await monitor.startSpan("open-across", snapshot: monitor.spanSnapshot())
        _ = await monitor.startSpan("control", snapshot: monitor.spanSnapshot())
        _ = await monitor.endSpan("control")
        client.reset()
        client.context.setUserId("user-b")
        _ = await monitor.endSpan("open-across")
        StubURLProtocol.stub = .status(200, body: "{}")
        let spans = await flushUntilShipped(monitor, "open-across")
        XCTAssertEqual(spans["control"]?["user_id"] as? String, "user-a")
        let stale = try XCTUnwrap(spans["open-across"])
        XCTAssertNil(stale["user_id"])
        XCTAssertNil(stale["session_id"])
        XCTAssertNil(stale["assignment_token"])
    }

    func testFrameWindowDoesNotSurviveALogout() {
        let current = LockedBox(context(token: "receipt-a", user: "a"))
        let epoch = IdentityEpoch()
        let metrics = LockedBox<[PerformanceMetric]>([])
        let tracker = FrameTracker(slowFrameThresholdMs: 16, frozenFrameThresholdMs: 700,
            captureContext: { current.get() }, epoch: epoch, onMetric: { metric in metrics.mutate { $0.append(metric) } })
        tracker.recordFrame(durationMs: 20); tracker.recordFrame(durationMs: 800)
        epoch.advance()
        current.set(context(token: "receipt-b", user: "b"))
        XCTAssertEqual(tracker.totalFrameCount, 0, "the previous user's frames are not counted for the next")
        XCTAssertEqual(tracker.slowFrameCount, 0)
        XCTAssertEqual(tracker.frozenFrameCount, 0)
        tracker.recordFrame(durationMs: 5)
        metrics.set([])
        tracker.reportSummary()
        let summary = metrics.get().last
        XCTAssertEqual(summary?.valueMs, 1)
        XCTAssertEqual(summary?.isError, false)
        XCTAssertEqual(summary?.context?.userId, "b")
        XCTAssertEqual(summary?.context?.assignmentToken, "receipt-b")
    }

    func testWarmStartPendingAcrossALogoutIsDropped() {
        let current = LockedBox(context(token: "receipt-a", user: "a"))
        let epoch = IdentityEpoch()
        let metrics = LockedBox<[PerformanceMetric]>([])
        let startup = StartupTracker(captureContext: { current.get() }, epoch: epoch,
            onMetric: { metric in metrics.mutate { $0.append(metric) } })
        startup.markFirstFrame()
        startup.markWarmStart()
        epoch.advance()
        current.set(context(token: "receipt-b", user: "b"))
        startup.markFirstFrame()
        XCTAssertEqual(metrics.get().map(\.metricName), ["cold_start"], "no warm_start carrying the previous identity")
        XCTAssertNil(startup.warmStartMs)
    }

    func testWarmStartAcrossAUserSwitchWithoutAnEpochStillShipsNoReceipt() {
        let current = LockedBox(context(token: "receipt-a", user: "a"))
        let metrics = LockedBox<[PerformanceMetric]>([])
        let startup = StartupTracker(captureContext: { current.get() }, onMetric: { metric in metrics.mutate { $0.append(metric) } })
        startup.markFirstFrame()
        startup.markWarmStart()
        current.set(context(token: "receipt-b", user: "b"))
        startup.markFirstFrame()
        let warm = metrics.get().last
        XCTAssertEqual(warm?.metricName, "warm_start")
        XCTAssertNil(warm?.context?.assignmentToken)
        XCTAssertEqual(warm?.context?.userId, "b")
    }

    func testColdStartContextIsRecapturedWhenTheIdentityMovesBeforeTheFirstFrame() {
        let current = LockedBox(context(token: "receipt-a", user: "a"))
        let epoch = IdentityEpoch()
        let metrics = LockedBox<[PerformanceMetric]>([])
        let startup = StartupTracker(captureContext: { current.get() }, epoch: epoch,
            onMetric: { metric in metrics.mutate { $0.append(metric) } })
        epoch.advance()
        current.set(context(token: "receipt-b", user: "b"))
        startup.markFirstFrame()
        XCTAssertEqual(metrics.get().first?.metricName, "cold_start")
        XCTAssertEqual(metrics.get().first?.context?.userId, "b")
        XCTAssertEqual(metrics.get().first?.context?.assignmentToken, "receipt-b")
        XCTAssertNotNil(startup.coldStartMs)
    }

    func testAnrRecoveryAfterAResetShipsNeitherTheLoggedOutIdentityNorItsReceipt() {
        let current = LockedBox(context(token: "receipt-a", user: "a"))
        let epoch = IdentityEpoch()
        let metrics = LockedBox<[PerformanceMetric]>([])
        let watchdog = ANRWatchdog(thresholdMs: 100, captureContext: { current.get() }, epoch: epoch,
            unattributedContext: { PerfBatchContext.unattributed(appVersion: nil) },
            onMetric: { metric in metrics.mutate { $0.append(metric) } })
        watchdog.handle(.detected(thresholdMs: 100), pingContext: current.get(), sampleEpoch: epoch.current)
        epoch.advance()
        watchdog.handle(.recovered(durationMs: 900), pingContext: nil, sampleEpoch: epoch.current)
        XCTAssertEqual(metrics.get().first?.context?.userId, "a", "detection happened inside a's identity")
        let recovered = metrics.get().last
        XCTAssertEqual(recovered?.metricName, "anr_recovered")
        XCTAssertNil(recovered?.context?.userId)
        XCTAssertNil(recovered?.context?.deviceId)
        XCTAssertNil(recovered?.context?.assignmentToken)
        // Control: without a reset in between, recovery keeps the freeze's context.
        watchdog.handle(.detected(thresholdMs: 100), pingContext: current.get(), sampleEpoch: epoch.current)
        watchdog.handle(.recovered(durationMs: 50), pingContext: nil, sampleEpoch: epoch.current)
        XCTAssertEqual(metrics.get().last?.context?.assignmentToken, "receipt-a")
    }

    /// The real loop's order: sample, then the ping wait (a logout can land in it), then `handle`.
    func testAnrDetectedAndRecoveredAfterAResetDuringThePingWaitShipNeitherIdentityNorToken() {
        let current = LockedBox(context(token: "receipt-a", user: "a"))
        let epoch = IdentityEpoch()
        let metrics = LockedBox<[PerformanceMetric]>([])
        let watchdog = ANRWatchdog(thresholdMs: 100, captureContext: { current.get() }, epoch: epoch,
            unattributedContext: { PerfBatchContext.unattributed(appVersion: nil) },
            onMetric: { metric in metrics.mutate { $0.append(metric) } })
        let sampleEpoch = epoch.current
        let sampled = current.get()
        epoch.advance()   // reset() lands while the watchdog waits on main
        watchdog.handle(.detected(thresholdMs: 100), pingContext: sampled, sampleEpoch: sampleEpoch)
        watchdog.handle(.recovered(durationMs: 900), pingContext: nil, sampleEpoch: epoch.current)
        XCTAssertEqual(metrics.get().map(\.metricName), ["anr_detected", "anr_recovered"])
        for metric in metrics.get() {
            XCTAssertNil(metric.context?.userId, metric.metricName)
            XCTAssertNil(metric.context?.deviceId, metric.metricName)
            XCTAssertNil(metric.context?.assignmentToken, metric.metricName)
        }
    }

    func testAnUnknownLiveIdentityIsNeverTheSameAndShipsNoReceipt() {
        var unknown = context(token: "receipt-a", user: "a")
        unknown.deviceId = nil
        XCTAssertFalse(context(token: "receipt-a", user: "a").sameIdentity(as: unknown))
        let current = LockedBox(context(token: "receipt-a", user: "a"))
        let metrics = LockedBox<[PerformanceMetric]>([])
        let startup = StartupTracker(captureContext: { current.get() }, onMetric: { metric in metrics.mutate { $0.append(metric) } })
        startup.markFirstFrame()
        startup.markWarmStart()
        current.set(unknown)
        startup.markFirstFrame()
        let warm = metrics.get().last
        XCTAssertEqual(warm?.metricName, "warm_start")
        XCTAssertNil(warm?.context?.assignmentToken)
        XCTAssertNil(warm?.context?.userId, "the live identity is unknown: nothing is attributed to anyone")
        current.set(context(token: "receipt-a", user: "a"))
        let held = FrameTracker(slowFrameThresholdMs: 16, frozenFrameThresholdMs: 700,
            captureContext: { current.get() }, onMetric: { metric in metrics.mutate { $0.append(metric) } })
        held.recordFrame(durationMs: 5)
        current.set(unknown)
        held.reportSummary()
        XCTAssertNil(metrics.get().last?.context?.assignmentToken)
        XCTAssertNil(metrics.get().last?.context?.userId)
    }

    @MainActor
    func testADeviceIdChangeEndsOpenSpansLikeAReset() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        SharedSDKStorage.clear()
        defer { SharedSDKStorage.clear() }
        let client = SheepitClient.createForTesting(config: SheepitConfig(
            apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64), apiUrl: "https://stub.invalid",
            flushInterval: 3600, configRefreshInterval: 3600, retryAttempts: 1,
            performance: PerformanceConfig(enabled: true, startupTrackingEnabled: false, frameTrackingEnabled: false,
                memoryTrackingEnabled: false, flushInterval: 3600)), now: { Date() },
            urlProtocolClasses: [StubURLProtocol.self])
        defer { client.destroy() }
        let field = try XCTUnwrap(Mirror(reflecting: client).children.first { $0.label == "performanceMonitor" }?.value)
        let monitor = try XCTUnwrap((field as? PerformanceMonitor)
            ?? (Mirror(reflecting: field).children.first?.value as? PerformanceMonitor))
        client.context.setUserId("user-a")
        _ = await monitor.startSpan("open-across", snapshot: monitor.spanSnapshot())
        client.deviceIdDidChange()
        _ = await monitor.endSpan("open-across")
        StubURLProtocol.stub = .status(200, body: "{}")
        let shipped = await flushUntilShipped(monitor, "open-across")
        let stale = try XCTUnwrap(shipped["open-across"])
        XCTAssertNil(stale["user_id"])
        XCTAssertNil(stale["device_id"])
    }

    /// Through the real `identify()` (a -> b, no reset): the cumulative windows must not carry a's identity or receipt.
    @MainActor
    func testIdentifyingAnotherUserRestartsTheFrameWindowAndDropsAPendingWarmStart() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        SharedSDKStorage.clear()
        defer { SharedSDKStorage.clear() }
        let client = SheepitClient.createForTesting(config: SheepitConfig(
            apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64), apiUrl: "https://stub.invalid",
            flushInterval: 3600, configRefreshInterval: 3600, retryAttempts: 1,
            performance: PerformanceConfig(enabled: true, startupTrackingEnabled: true, frameTrackingEnabled: true,
                memoryTrackingEnabled: false, anrThresholdMs: 600_000, flushInterval: 3600)), now: { Date() },
            urlProtocolClasses: [StubURLProtocol.self])
        defer { client.destroy() }
        let field = try XCTUnwrap(Mirror(reflecting: client).children.first { $0.label == "performanceMonitor" }?.value)
        let monitor = try XCTUnwrap((field as? PerformanceMonitor)
            ?? (Mirror(reflecting: field).children.first?.value as? PerformanceMonitor))
        client.context.setUserId("user-a")
        client.seedAssignmentsForTesting([:], appliedUnderUserId: "user-a", assignmentToken: "receipt-a")
        await monitor.start()
        defer { Task { await monitor.stop() } }
        let trackers = await monitor.trackersForTesting()
        let frames = try XCTUnwrap(trackers.frame), startup = try XCTUnwrap(trackers.startup)
        for _ in 0..<3 { frames.recordFrame(durationMs: 5) }
        startup.markWarmStart()
        client.identify(userId: "user-b")
        XCTAssertEqual(client.context.userId, "user-b")
        frames.recordFrame(durationMs: 5)
        startup.markFirstFrame()
        StubURLProtocol.stub = .status(200, body: "{}")
        let summaries = await flushUntilShipped(monitor, "frame_summary", type: "frames")
        let summary = try XCTUnwrap(summaries["frame_summary"])
        XCTAssertNotEqual(summary["user_id"] as? String, "user-a")
        XCTAssertNil(summary["assignment_token"], "a's receipt is not a claim about b's frames")
        let values = StubURLProtocol.requestBodies.compactMap {
            (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any]
        }.flatMap { ($0["batch"] as? [[String: Any]]) ?? [] }
        let frameValues = values.filter { $0["metric_name"] as? String == "frame_summary" }.compactMap { $0["value_ms"] as? Double }
        XCTAssertEqual(frameValues.first, 1, "only the frame counted after the switch; a's three were not carried over")
        XCTAssertNil(values.first { $0["metric_name"] as? String == "warm_start" }, "the warm start begun under a is dropped, not re-attributed")
        XCTAssertNotNil(values.first { $0["metric_name"] as? String == "cold_start" })
    }

    func testContendedGateStillShipsIdentityButNeverAReceiptAndCountsTheDrop() throws {
        let bus = DiagnosticBus(bufferSize: 10)
        let context = ContextManager(storage: InMemoryStorage())
        context.setUserId("user-a")
        let experiments = ExperimentManager(storage: InMemoryStorage(), diagnostics: bus)
        experiments.setAssignments(try assignments(), appliedUnder: .fetchedUnder("user-a"), assignmentToken: "receipt-held")
        let gate = ExposureDecisionGate()
        // Control: uncontended, the same inputs DO carry the receipt, so the nil below is the fallback's doing.
        let free = PerfBatchContext.sample(gate: gate, context: context, experiments: experiments,
            appVersion: nil, diagnostics: bus, contention: SamplingContentionCounter())
        XCTAssertEqual(free.assignmentToken, "receipt-held")
        XCTAssertEqual(experiments.tryReceipt(eventUserId: "user-a")?.token, "receipt-held")
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { gate.withLock { entered.signal(); _ = release.wait(timeout: .now() + 3) } }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        defer { release.signal() }
        let sampled = PerfBatchContext.sample(gate: gate, context: context, experiments: experiments,
            appVersion: nil, diagnostics: bus, contention: SamplingContentionCounter())
        XCTAssertEqual(sampled.userId, "user-a")
        XCTAssertNil(sampled.assignmentToken, "a contended gate claims no assignment")
        XCTAssertNil(sampled.assignmentStatus)
        // Emitted off the sampling path, so poll for it.
        let deadline = Date().addingTimeInterval(2)
        var events: [DiagnosticEvent] = []
        while events.isEmpty, Date() < deadline {
            events = bus.getRecentDiagnostics().filter { $0.code == "performance.context_sampling_contended" }
            if events.isEmpty { Thread.sleep(forTimeInterval: 0.01) }
        }
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events.first?.data?["count"]?.value as? Int, 1)
    }
}
