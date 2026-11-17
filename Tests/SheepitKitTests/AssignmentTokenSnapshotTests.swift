import XCTest
@testable import SheepitKit

/// Identity gates and performance interval/transport snapshots; no flush-time receipt repair.
final class AssignmentTokenSnapshotTests: XCTestCase {
    func testCrashObserverRefreshDoesNotNotifyPublicChangesOrSpendExposures() async {
        let flags = FlagManager()
        let changes = flags.changes()
        let deliveries = LockedBox(0), exposures = LockedBox(0)
        flags.setValuesObserver { _ in deliveries.mutate { $0 += 1 } }
        flags.setEvaluatedFlags(["feature": AnyCodable(true)])
        for _ in 0..<3 {
            _ = flags.evaluate(flagKey: "feature", defaultValue: .bool(false)) { _, _, _ in
                exposures.mutate { $0 += 1 }
            }
            flags.refreshValuesObserver()
        }
        flags.finishAllChanges()
        var notifications = 0
        for await _ in changes { notifications += 1 }
        XCTAssertEqual(notifications, 1, "only the original config apply notifies public subscribers")
        XCTAssertEqual(exposures.get(), 1, "refresh does not clear or spend exposure dedup")
        XCTAssertEqual(deliveries.get(), 4, "three private re-deliveries plus original apply")
    }

    func testPersistedReceiptsUseTheSameBoundsAndStatusPolicyAsNewCaptures() throws {
        for (token, status) in [(String(repeating: "a", count: 97), "unexpected"),
                                ("receipt-control", "identity_changed"), ("receipt-control", "unexpected")] {
            let raw = try JSONSerialization.data(withJSONObject: ["token": token, "status": status])
            let decoded = try JSONDecoder().decode(AssignmentReceipt.self, from: raw)
            XCTAssertEqual(decoded, status == "identity_changed" ? AssignmentReceipt(token: token, identityChanged: true) : AssignmentReceipt())
        }
        XCTAssertEqual(try JSONDecoder().decode(AssignmentReceipt.self, from: Data("{}".utf8)), AssignmentReceipt())
        XCTAssertEqual(try JSONDecoder().decode(AssignmentReceipt.self, from: Data(#"{"token":null,"status":null}"#.utf8)), AssignmentReceipt())
    }

    func testUnusableAliasesAreDiscardedWholeWithoutLosingExplicitSwitchStatus() {
        for token in ["", String(repeating: "a", count: 97), String(repeating: "é", count: 49)] {
            let receipt = AssignmentReceipt(token: token, identityChanged: true)
            XCTAssertNil(receipt.token)
            XCTAssertEqual(receipt.status, "identity_changed")
        }
        XCTAssertEqual(AssignmentReceipt(token: String(repeating: "a", count: 96)).token?.utf8.count, 96)
    }

    func testIdentityChangeDiscardsReceiptTokenInMemoryAndPersistence() throws {
        let marked = AssignmentReceipt(token: "old-receipt", identityChanged: true)
        XCTAssertNil(marked.token)
        XCTAssertEqual(marked.status, "identity_changed")
        let raw = Data(#"{"token":"old-receipt","status":"identity_changed"}"#.utf8)
        XCTAssertNil(try JSONDecoder().decode(AssignmentReceipt.self, from: raw).token)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(marked), as: UTF8.self).contains("old-receipt"))
        XCTAssertEqual(AssignmentReceipt(token: "current-receipt").token, "current-receipt")
    }

    func testHealthyFramesDoNotSampleIdentityOrReceipt() {
        let reads = LockedBox(0)
        let tracker = FrameTracker(slowFrameThresholdMs: 16, frozenFrameThresholdMs: 700,
            captureContext: { reads.mutate { $0 += 1 }; return nil }, onMetric: { _ in })
        XCTAssertEqual(reads.get(), 1, "the cumulative summary captures once at creation")
        for _ in 0..<120 { tracker.recordFrame(durationMs: 5) }
        XCTAssertEqual(reads.get(), 1, "healthy display callbacks take no context locks")
        tracker.recordFrame(durationMs: 20)
        XCTAssertEqual(reads.get(), 2, "only the emitted slow-frame metric samples")
    }

    @MainActor
    func testWatchdogAndFrameSamplingProgressWhileTheDecisionGateIsHeld() throws {
        let client = SheepitClient.constructOnlyForTesting(config: SheepitConfig(
            apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64), apiUrl: "https://stub.invalid",
            performance: PerformanceConfig(enabled: true, startupTrackingEnabled: false,
                frameTrackingEnabled: false, memoryTrackingEnabled: false)))
        defer { client.destroy() }
        let field = try XCTUnwrap(Mirror(reflecting: client).children.first { $0.label == "performanceMonitor" }?.value)
        let monitor = try XCTUnwrap((field as? PerformanceMonitor)
            ?? (Mirror(reflecting: field).children.first?.value as? PerformanceMonitor))
        let gate = client.exposureDecisionGateForTesting
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { gate.withLock { entered.signal(); _ = release.wait(timeout: .now() + 3) } }
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        defer { release.signal() }
        let sampled = LockedBox<[PerformanceMetric]>([])
        let frameFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let tracker = FrameTracker(slowFrameThresholdMs: 16, frozenFrameThresholdMs: 700,
                captureContext: { monitor.contextSnapshot() }, onMetric: { metric in sampled.mutate { $0.append(metric) } })
            tracker.recordFrame(durationMs: 20)
            frameFinished.signal()
        }
        XCTAssertEqual(frameFinished.wait(timeout: .now() + 1), .success, "frame sampling must finish before the gate is released")
        let detected = DispatchSemaphore(value: 0)
        let watchdog = ANRWatchdog(thresholdMs: 100, captureContext: { monitor.contextSnapshot() }, onMetric: { metric in
            sampled.mutate { $0.append(metric) }
            if metric.metricName == "anr_detected" { detected.signal() }
        })
        watchdog.start()
        defer { watchdog.stop() }
        // Holding main here makes the real watchdog's main-thread ping time out.
        XCTAssertEqual(detected.wait(timeout: .now() + 1), .success, "the watchdog must report while the decision gate is held")
        XCTAssertTrue(gate.isHeldForTesting())
        XCTAssertFalse(sampled.get().isEmpty)
        for metric in sampled.get() {
            XCTAssertNotNil(metric.context)
            XCTAssertNil(metric.context?.assignmentToken)
            XCTAssertNil(metric.context?.userId)
            XCTAssertNil(metric.context?.assignmentStatus)
        }
    }

    @MainActor
    func testActualClientSamplingDoesNotPinTheGateBehindAContextWriter() async throws {
        SharedSDKStorage.clear()
        AttributionCaptureProtocol.reset()
        TeardownFlushes.install()
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let writerFinished = DispatchSemaphore(value: 0), sampled = DispatchSemaphore(value: 0)
        let client = SheepitClient.createForTesting(config: SheepitConfig(
            apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64), apiUrl: "https://stub.invalid",
            flushInterval: 3600, configRefreshInterval: 3600, retryAttempts: 1,
            performance: PerformanceConfig(enabled: true, startupTrackingEnabled: false, frameTrackingEnabled: false,
                memoryTrackingEnabled: false, anrThresholdMs: 100, flushInterval: 3600)), now: {
                    if Thread.current.name == "blocked-performance-context" {
                        entered.signal()
                        _ = release.wait(timeout: .now() + 3)
                    }
                    return Date()
                }, urlProtocolClasses: [AttributionCaptureProtocol.self])
        let field = try XCTUnwrap(Mirror(reflecting: client).children.first { $0.label == "performanceMonitor" }?.value)
        let monitor = try XCTUnwrap((field as? PerformanceMonitor)
            ?? (Mirror(reflecting: field).children.first?.value as? PerformanceMonitor))
        // Quiesce unrelated registration/tracker writers; keep the actual client's capture closure.
        client.destroy()
        await TeardownFlushes.drain(context: name)
        defer { release.signal(); SharedSDKStorage.clear(); AttributionCaptureProtocol.reset() }
        let writer = Thread { client.context.touchSession(); writerFinished.signal() }
        writer.name = "blocked-performance-context"
        writer.start()
        XCTAssertEqual(entered.wait(timeout: .now() + 1), .success)
        let value = LockedBox<PerfBatchContext?>(nil)
        let writerReleased = LockedBox(false), sawReleaseFirst = LockedBox(true)
        DispatchQueue.global().async {
            value.set(monitor.contextSnapshot())
            sawReleaseFirst.set(writerReleased.get())
            sampled.signal()
        }
        XCTAssertEqual(sampled.wait(timeout: .now() + 1), .success,
            "the production client capture must not wait for ContextManager's lock")
        XCTAssertFalse(sawReleaseFirst.get(), "capture must finish while the writer still holds the context lock")
        let gateFree = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { client.exposureDecisionGateForTesting.withLock {}; gateFree.signal() }
        XCTAssertEqual(gateFree.wait(timeout: .now() + 1), .success, "a context writer must not pin the decision gate")
        XCTAssertNotNil(value.get())
        XCTAssertNil(value.get()?.userId)
        XCTAssertNil(value.get()?.sessionId)
        XCTAssertNil(value.get()?.deviceId)
        XCTAssertNil(value.get()?.assignmentToken)
        writerReleased.set(true)
        release.signal()
        XCTAssertEqual(writerFinished.wait(timeout: .now() + 1), .success)
    }

    func testSamplingReleasesTheDecisionGateWhileContextStorageIsBlocked() throws {
        let storage = ReadHookStorage()
        let context = ContextManager(storage: storage)
        let storageEntered = DispatchSemaphore(value: 0), releaseStorage = DispatchSemaphore(value: 0)
        let writerFinished = DispatchSemaphore(value: 0), sampled = DispatchSemaphore(value: 0)
        storage.onFirstStringWrite(to: StorageKeys.sessionId) {
            storageEntered.signal()
            _ = releaseStorage.wait(timeout: .now() + 3)
        }
        DispatchQueue.global().async { context.touchSession(); writerFinished.signal() }
        XCTAssertEqual(storageEntered.wait(timeout: .now() + 1), .success)
        defer { releaseStorage.signal(); _ = writerFinished.wait(timeout: .now() + 1) }
        let gate = ExposureDecisionGate()
        let bus = DiagnosticBus(bufferSize: 10)
        let monitor = PerformanceMonitor(http: stubHTTP(), context: context, config: PerformanceConfig(),
            appVersionOverride: nil, log: Logger(debug: false), captureContext: {
                PerfBatchContext.sample(gate: gate, context: context,
                    experiments: ExperimentManager(storage: InMemoryStorage(), diagnostics: bus),
                    appVersion: nil, diagnostics: bus, contention: SamplingContentionCounter())
            })
        let value = LockedBox<PerfBatchContext?>(nil)
        DispatchQueue.global().async { value.set(monitor.contextSnapshot()); sampled.signal() }
        XCTAssertEqual(sampled.wait(timeout: .now() + 1), .success, "the production closure must not wait for context storage")
        let gateFree = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { gate.withLock {}; gateFree.signal() }
        XCTAssertEqual(gateFree.wait(timeout: .now() + 1), .success, "a context writer must not pin the decision gate through sampling")
        XCTAssertNotNil(value.get())
        XCTAssertNil(value.get()?.userId)
        XCTAssertNil(value.get()?.sessionId)
        XCTAssertNil(value.get()?.deviceId)
        XCTAssertNil(value.get()?.assignmentToken)
    }

    func testPerformanceCapturesDoNotOccupyTheMonitorActor() async {
        for operation in ["start", "metric", "span"] {
            let entered = expectation(description: "context capture entered for \(operation)")
            let progressed = expectation(description: "actor progresses for \(operation)")
            let release = DispatchSemaphore(value: 0)
            let first = LockedBox(true)
            let captured = context(token: "receipt")
            let http = HTTPClient(config: SheepitConfig(apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64),
                apiUrl: "https://stub.invalid"), log: Logger(debug: false), urlProtocolClasses: [StubURLProtocol.self])
            let monitor = PerformanceMonitor(http: http, context: ContextManager(storage: InMemoryStorage()),
                config: PerformanceConfig(enabled: true, startupTrackingEnabled: true, frameTrackingEnabled: false,
                    memoryTrackingEnabled: false, flushInterval: 3600, maxBatchSize: 1000),
                appVersionOverride: nil, log: Logger(debug: false), captureContext: {
                    if first.get() { first.set(false); entered.fulfill(); _ = release.wait(timeout: .now() + 3) }
                    return captured
                })
            let task = Task.detached {
                switch operation {
                case "start": await monitor.start()
                case "metric": await monitor.addMetric(PerformanceMetric(metricType: "memory", metricName: "sample",
                    valueMs: 1, statusCode: nil, isError: false, timestamp: "2026-11-16T12:00:00Z"))
                default: _ = await monitor.startSpan("sample")
                }
            }
            await fulfillment(of: [entered], timeout: 1)
            let reader = Task.detached { _ = await monitor.performanceSummary(); progressed.fulfill() }
            await fulfillment(of: [progressed], timeout: 1)
            release.signal()
            await task.value
            await reader.value
            await monitor.stop()
        }
    }

    func testResetClearsTheAnonymousReceiptBeforeItsOutsideGateCallback() throws {
        SharedSDKStorage.clear()
        defer { SharedSDKStorage.clear() }
        let holder = LockedBox<SheepitClient?>(nil)
        let observed = LockedBox<AssignmentReceipt?>(nil)
        let client = SheepitClient.constructOnlyForTesting(config: SheepitConfig(
            apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64), apiUrl: "https://stub.invalid",
            onDiagnostic: { event in
                guard event.code == "identity.device_kept_on_reset", let client = holder.get() else { return }
                let field = Mirror(reflecting: client).children.first { $0.label == "experimentManager" }?.value
                if let manager = field as? ExperimentManager { observed.set(manager.receipt(eventUserId: nil).receipt) }
            }))
        holder.set(client)
        defer { holder.set(nil); client.destroy() }
        client.seedAssignmentsForTesting([:], assignmentToken: "before-reset")
        client.reset()
        let receipt = try XCTUnwrap(observed.get(), "the callback between reset's two sections must run")
        XCTAssertNil(receipt.token)
    }

    private func assignments(_ count: Int = 500) throws -> [String: SDKExperimentAssignment] {
        let value = try JSONDecoder().decode(SDKExperimentAssignment.self,
            from: Data(#"{"variant_key":"treatment","payload":{}}"#.utf8))
        return Dictionary(uniqueKeysWithValues: (0..<count).map { ("experiment-\($0)", value) })
    }

    func testCapturedSetKeepsItsReceiptAcrossApplySwitchCacheAndLogout() throws {
        let manager = ExperimentManager(storage: InMemoryStorage())
        let members = try assignments()
        manager.setAssignments(members, appliedUnder: .fetchedUnder("a"), assignmentToken: "receipt-a")
        let old = manager.capture()
        manager.setAssignments(members, appliedUnder: .fetchedUnder("a"), assignmentToken: "receipt-refresh")
        XCTAssertEqual(manager.receipt(old, eventUserId: "a").receipt, AssignmentReceipt(token: "receipt-a"))
        _ = manager.beginIdentitySwitch(to: "b")
        XCTAssertEqual(manager.receipt(old, eventUserId: "b").receipt.status, "identity_changed")
        manager.setAssignments(members, appliedUnder: .fetchedUnder("b"), origin: .cache, assignmentToken: "receipt-b")
        XCTAssertEqual(manager.receipt(eventUserId: "b").receipt.status, "identity_changed",
                       "a cached body cannot invent a successful identify bind")
        manager.setAssignments(members, appliedUnder: .fetchedUnder("b"), assignmentToken: "receipt-b")
        XCTAssertNil(manager.receipt(eventUserId: "b").receipt.status)
        manager.clearForLogout()
        XCTAssertNil(manager.receipt(eventUserId: nil).receipt.token)
        XCTAssertEqual(manager.receipt(old, eventUserId: nil).receipt,
                       AssignmentReceipt(token: "receipt-a", identityChanged: true))
    }

    func testReceiptAvailabilityReleasesExperimentAndFlagExposureDedup() throws {
        let manager = ExperimentManager(storage: InMemoryStorage())
        let members = try assignments()
        manager.setAssignments(members, appliedUnder: .fetchedUnder(nil))
        let captures = LockedBox<[ExperimentAssignmentSet]>([])
        _ = manager.resolve(experimentKey: "experiment-499") { _, _, _, set in captures.mutate { $0.append(set) } }
        let set = try XCTUnwrap(captures.get().first)
        XCTAssertNil(manager.receipt(set, eventUserId: nil, experimentKey: "experiment-499", variant: "treatment").receipt.token)
        _ = manager.receipt(set, eventUserId: nil, flagKey: "feature")
        let drained = manager.setAssignments(members, appliedUnder: .fetchedUnder(nil), assignmentToken: "receipt-ready")
        XCTAssertEqual(drained, ["feature"])
        _ = manager.resolve(experimentKey: "experiment-499") { _, _, _, set in captures.mutate { $0.append(set) } }
        XCTAssertEqual(captures.get().count, 2, "missing receipt did not permanently spend the exposure")
        XCTAssertEqual(manager.receipt(captures.get()[1], eventUserId: nil).receipt.token, "receipt-ready")
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

    private func stubHTTP() -> HTTPClient {
        HTTPClient(config: SheepitConfig(apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64),
            apiUrl: "https://stub.invalid", retryAttempts: 1), log: Logger(debug: false),
            urlProtocolClasses: [StubURLProtocol.self])
    }

}
