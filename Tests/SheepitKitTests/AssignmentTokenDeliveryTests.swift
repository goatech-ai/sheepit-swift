import XCTest
import SheepitCrashHandler
@testable import SheepitKit

/// Actual ConfigSync → decision gate → queue → HTTP wire, including indefinitely cached bodies.
final class AssignmentTokenDeliveryTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SharedSDKStorage.clear()
        AttributionCaptureProtocol.reset()
        AttributionCaptureProtocol.registerDeviceId = "receipt-device"
        AttributionCaptureProtocol.configResolution = { _, _ in "resolved" }
        AttributionCaptureProtocol.honorIfNoneMatch = false
        TeardownFlushes.install()
    }

    override func tearDown() async throws {
        await TeardownFlushes.drain(context: name)
        SharedSDKStorage.clear()
        AttributionCaptureProtocol.reset()
        try await super.tearDown()
    }

    private func body(count: Int, token: Any?, flag: Bool = true, legacyETag: Bool = false) throws -> String {
        var response: [String: Any] = [
            "config_version": "receipt-v1", "flags": ["feature": flag],
            "experiments": Dictionary(uniqueKeysWithValues: (0..<count).map { index in
                ("experiment-\(index)", ["variant_key": "treatment", "payload": [:],
                    "experiment_id": "11111111-1111-4111-8111-111111111111",
                    "subject_kind": index % 2 == 0 ? "device" : "user",
                    "bucketing_version": 1, "assignment_revision": "1"] as [String: Any])
            }),
        ]
        if let token { response["assignment_token"] = token }
        if legacyETag { response["etag"] = "\"legacy-config\"" }
        return String(decoding: try JSONSerialization.data(withJSONObject: ["data": response]), as: UTF8.self)
    }

    private func makeClient(crashesEnabled: Bool = false) throws -> SheepitClient {
        SharedSDKStorage.markRegistered("receipt-device")
        SharedSDKStorage.slotStorage().set(try JSONEncoder().encode(ServerHeldUser.known(nil)), forKey: StorageKeys.serverHeldUser)
        return SheepitClient.createForTesting(config: SheepitConfig(
            apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64), apiUrl: "https://stub.invalid",
            flushInterval: 3600, flushSize: 1000, configRefreshInterval: 3600, retryAttempts: 1,
            crashes: CrashConfig(enabled: crashesEnabled)), now: { Date() },
            urlProtocolClasses: [AttributionCaptureProtocol.self], identifyRetryDelays: [])
    }

    @MainActor
    func testRealConfigCallbacksPublishCrashReceiptsOnlyAfterTheirFlagsApply() async throws {
        for resolution in ["resolved", "unresolved"] {
            SharedSDKStorage.clear()
            SharedSDKStorage.markRegistered("receipt-device")
            SharedSDKStorage.slotStorage().set(try JSONEncoder().encode(ServerHeldUser.known(nil)), forKey: StorageKeys.serverHeldUser)
            AttributionCaptureProtocol.configResolution = { _, _ in resolution }
            AttributionCaptureProtocol.serveConfig(try body(count: 500, token: "receipt-first", flag: false))
            let directory = CrashFixtures.tempDirectory("assignment-config-publication")
            let client = try await makeOwnedCrashClient(in: self, directory: directory)
            let reporter = try XCTUnwrap(client.crashReporterForTesting)
            await client.refreshConfigForTesting()
            let context = try XCTUnwrap(sheepit_get_crash_context())
            var raw = sheepit_crash_cohort_t()
            sheepit_crash_cohort_snapshot(&raw)
            var receipt = try XCTUnwrap(CrashIdentityCohort(raw))
            XCTAssertEqual(receipt.assignmentToken, resolution == "resolved" ? "receipt-first" : nil)
            XCTAssertEqual(receipt.identityChanged, resolution != "resolved")
            XCTAssertEqual(receipt.deviceId, client.context.deviceId)
            XCTAssertEqual(CrashText.string(context.pointee.active_flags_json), #"{"feature":false}"#)
            if resolution == "resolved" {
                for token in ["receipt-next" as Any?, NSNull(), nil] {
                    AttributionCaptureProtocol.serveConfig(try body(count: 500, token: token))
                    await client.refreshConfigForTesting()
                    sheepit_crash_cohort_snapshot(&raw)
                    receipt = try XCTUnwrap(CrashIdentityCohort(raw))
                    XCTAssertEqual(receipt.assignmentToken, token as? String)
                    XCTAssertFalse(receipt.identityChanged)
                    XCTAssertEqual(receipt.userId, client.context.userId)
                    XCTAssertEqual(CrashText.string(context.pointee.active_flags_json), #"{"feature":true}"#)
                }
            }
            client.destroy()
            await reporter.stop()
            await TeardownFlushes.drain(context: name)
        }
    }

    func testRawInvalidReceiptsReachTheRealApplyDiagnosticWithoutDroppingFlagsOrLeakingValues() async throws {
        SharedSDKStorage.markRegistered()
        AttributionCaptureProtocol.serveConfig(try body(count: 1, token: "initial-valid"))
        let diagnostics = LockedBox<[DiagnosticEvent]>([])
        let client = SheepitClient.createForTesting(config: SheepitConfig(
            apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64), apiUrl: "https://stub.invalid",
            flushInterval: 3600, flushSize: 1000, configRefreshInterval: 3600, retryAttempts: 1,
            onDiagnostic: { event in diagnostics.mutate { $0.append(event) } }), now: { Date() },
            urlProtocolClasses: [AttributionCaptureProtocol.self])
        defer { client.destroy() }
        await client.refreshConfigForTesting()
        let invalid: [Any] = ["", String(repeating: "private-invalid-", count: 10), 123, false, ["bad": true], [Any]()]
        for (index, raw) in invalid.enumerated() {
            let nextFlag = index % 2 == 0
            AttributionCaptureProtocol.serveConfig(try body(count: 1, token: raw, flag: nextFlag))
            await client.refreshConfigForTesting()
            XCTAssertEqual(client.flag("feature"), .bool(nextFlag), "bad receipt must not discard new flags")
            let data = try XCTUnwrap(UserDefaults(suiteName: SharedSDKStorage.suite)?.data(forKey: SharedSDKStorage.slot(StorageKeys.sdkConfig)))
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let saved = try XCTUnwrap(envelope["data"] as? [String: Any])
            XCTAssertTrue(saved["assignment_token"] is NSNull, "only validated receipt state is persisted")
            client.track("invalid-\(index)")
        }
        await client.flush()
        for index in 0..<6 { XCTAssertNil(try context("invalid-\(index)")["assignment_token"]) }
        let failures = diagnostics.get().filter { $0.code == "config.assignment_token_unavailable" }
        XCTAssertGreaterThanOrEqual(failures.count, 6)
        XCTAssertTrue(failures.allSatisfy { $0.data?["outcome"]?.value as? String == "invalid_assignment_token" })
        XCTAssertTrue(failures.allSatisfy { $0.data?.keys.sorted() == ["outcome"] && !$0.message.contains("private-invalid-") })
        let cached = try XCTUnwrap(UserDefaults(suiteName: SharedSDKStorage.suite)?.data(forKey: SharedSDKStorage.slot(StorageKeys.sdkConfig)))
        XCTAssertFalse(String(decoding: cached, as: UTF8.self).contains("private-invalid-"))
    }

    func testInvalidReceiptDiagnosticCanResetAfterTheWholeConfigCompletion() async throws {
        SharedSDKStorage.markRegistered()
        let holder = LockedBox<SheepitClient?>(nil)
        let reset = LockedBox(false)
        let observed = LockedBox<[String]>([])
        AttributionCaptureProtocol.serveConfig(try body(count: 1, token: "initial-valid"))
        let client = SheepitClient.createForTesting(config: SheepitConfig(
            apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64), apiUrl: "https://stub.invalid",
            flushInterval: 3600, flushSize: 1000, configRefreshInterval: 3600, retryAttempts: 1,
            onDiagnostic: { event in
                guard event.code == "config.assignment_token_unavailable", let client = holder.get(), !reset.get() else { return }
                reset.set(true)
                XCTAssertFalse(client.exposureDecisionGateForTesting.isHeldForTesting())
                _ = client.flag("feature")
                client.reset()
                client.track("after-reentrant-reset")
                observed.mutate { $0.append(event.code) }
            }), now: { Date() }, urlProtocolClasses: [AttributionCaptureProtocol.self])
        holder.set(client)
        defer { holder.set(nil); client.destroy() }
        await client.refreshConfigForTesting()
        AttributionCaptureProtocol.serveConfig(try body(count: 1, token: ["bad": true]))
        await client.refreshConfigForTesting()
        XCTAssertEqual(observed.get(), ["config.assignment_token_unavailable"])
        await client.flush()
        XCTAssertNil(try context("after-reentrant-reset")["assignment_token"])
        XCTAssertNil(client.context.userId)
    }

    func testIdentityDiagnosticUsesTheQueuedReceiptOutsideCoreLocksAndAllowsReentrantReads() async throws {
        SharedSDKStorage.markRegistered()
        let holder = LockedBox<SheepitClient?>(nil)
        let events = LockedBox<[DiagnosticEvent]>([])
        let client = SheepitClient.createForTesting(config: SheepitConfig(
            apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64), apiUrl: "https://stub.invalid",
            flushInterval: 3600, flushSize: 1000, configRefreshInterval: 3600, retryAttempts: 1,
            onDiagnostic: { event in
                guard event.code == "experiment.identity_changed", let client = holder.get() else { return }
                events.mutate { $0.append(event) }
                XCTAssertFalse(client.exposureDecisionGateForTesting.isHeldForTesting())
                _ = client.flag("diagnostic-reentrant", default: .bool(false))
                client.track("nested-diagnostic-event")
            }), now: { Date() }, urlProtocolClasses: [AttributionCaptureProtocol.self])
        holder.set(client)
        defer { holder.set(nil); client.destroy() }
        client.seedAssignmentsForTesting([:], appliedUnderUserId: "private-user", assignmentToken: "private-receipt")
        client.track("outer-diagnostic-event")
        client.track("later-same-config")
        XCTAssertEqual(events.get().count, 1, "the actual queue consumer shares the existing once-per-set latch")
        let diagnostic = try XCTUnwrap(events.get().first)
        XCTAssertEqual(diagnostic.data?["outcome"]?.value as? String, "identity_changed")
        let rendered = diagnostic.message + String(describing: diagnostic.data)
        XCTAssertFalse(rendered.contains("private-user") || rendered.contains("private-receipt"))
        await client.flush()
        for name in ["outer-diagnostic-event", "nested-diagnostic-event", "later-same-config"] {
            let value = try context(name)
            XCTAssertNil(value["assignment_token"])
            XCTAssertEqual(value["assignment_status"] as? String, "identity_changed")
        }
    }

    func testPublicSpanFreezesIdentityAndReceiptBeforeItsActorHop() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        SharedSDKStorage.markRegistered()
        let client = SheepitClient.createForTesting(config: SheepitConfig(
            apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64), apiUrl: "https://stub.invalid",
            flushInterval: 3600, flushSize: 1000, configRefreshInterval: 3600, retryAttempts: 1,
            performance: PerformanceConfig(enabled: true, startupTrackingEnabled: false, frameTrackingEnabled: false,
                networkTrackingEnabled: false, memoryTrackingEnabled: false, flushInterval: 3600, maxBatchSize: 1000)),
            now: { Date() }, urlProtocolClasses: [StubURLProtocol.self], identifyRetryDelays: [])
        defer { client.destroy() }
        let field = try XCTUnwrap(Mirror(reflecting: client).children.first(where: { $0.label == "performanceMonitor" })?.value)
        let monitor = try XCTUnwrap((field as? PerformanceMonitor)
            ?? (Mirror(reflecting: field).children.first?.value as? PerformanceMonitor))
        client.identify(userId: "span-a")
        client.applyConfigForTesting(flags: [:], assignments: [:], appliedUnder: .fetchedUnder("span-a"), assignmentToken: "receipt-a")
        _ = await monitor.startSpan("direct-monitor-positive")
        let entered = LockedBox(false), timedOut = LockedBox(false)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        await monitor.addMetric(PerformanceMetric(metricType: "span", metricName: "actor-barrier", valueMs: 1,
            statusCode: nil, isError: false, timestamp: "2026-11-12T18:00:00Z"))
        await monitor.setOnError { _, _ in
            if !entered.get() {
                entered.set(true)
                if release.wait(timeout: .now() + 3) == .timedOut { timedOut.set(true) }
            }
        }
        StubURLProtocol.stub = .status(500, body: "{}")
        let blockedFlush = Task { await monitor.flush() }
        let readyDeadline = Date().addingTimeInterval(3)
        while !entered.get() {
            guard Date() < readyDeadline else { return XCTFail("The existing actor callback never blocked") }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(client.context.userId, "span-a")
        client.startSpan("public-checkout")
        client.identify(userId: "span-b")
        client.applyConfigForTesting(flags: [:], assignments: [:], appliedUnder: .fetchedUnder("span-b"), assignmentToken: "receipt-b")
        XCTAssertEqual(client.context.userId, "span-b")
        StubURLProtocol.stub = .status(200, body: "{}")
        release.signal()
        await blockedFlush.value
        var duration = await monitor.endSpan("public-checkout")
        let endDeadline = Date().addingTimeInterval(3)
        while duration == nil {
            guard Date() < endDeadline else { return XCTFail("The public start never reached the actor") }
            await Task.yield()
            duration = await monitor.endSpan("public-checkout")
        }
        _ = await monitor.endSpan("direct-monitor-positive")
        await monitor.flush()
        XCTAssertFalse(timedOut.get())
        var metrics: [[String: Any]] = []
        while true {
            await monitor.flush()
            metrics = []
            for data in StubURLProtocol.requestBodies {
                if let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let batch = body["batch"] as? [[String: Any]] { metrics += batch }
            }
            if ["public-checkout", "direct-monitor-positive"].allSatisfy({ name in
                metrics.contains(where: { $0["metric_name"] as? String == name })
            }) { break }
            guard Date() < endDeadline else { return XCTFail("The existing captured-wire sink never received the completed spans") }
            await Task.yield()
        }
        for name in ["public-checkout", "direct-monitor-positive"] {
            let metric = try XCTUnwrap(metrics.last(where: { $0["metric_name"] as? String == name }))
            let context = try XCTUnwrap(metric["context"] as? [String: Any])
            XCTAssertEqual(context["user_id"] as? String, "span-a", name)
            XCTAssertEqual(context["assignment_token"] as? String, "receipt-a", name)
        }
    }

    @MainActor
    func testNulReceiptCannotDiscardTheSavedFullCrashIdentity() async throws {
        let user = String(repeating: "界", count: 256), device = String(repeating: "d", count: 256)
        let session = String(repeating: "文", count: 256)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: SharedSDKStorage.suite))
        SharedSDKStorage.markRegistered(device)
        defaults.set(try JSONSerialization.data(withJSONObject: ["userId": user]), forKey: SharedSDKStorage.slot(StorageKeys.identity))
        defaults.set(try JSONEncoder().encode(ServerHeldUser.known(user)), forKey: SharedSDKStorage.slot(StorageKeys.serverHeldUser))
        defaults.set(session, forKey: SharedSDKStorage.slot(StorageKeys.sessionId))
        defaults.set(String(Date().timeIntervalSince1970), forKey: SharedSDKStorage.slot(StorageKeys.sessionLastSeen))
        AttributionCaptureProtocol.serveConfig(try body(count: 0, token: "good-receipt"))
        let diagnostics = LockedBox<[DiagnosticEvent]>([])
        let directory = CrashFixtures.tempDirectory("nul-receipt-full-identity")
        let client = try await makeOwnedCrashClient(in: self, directory: directory,
            onDiagnostic: { event in diagnostics.mutate { $0.append(event) } })
        await client.refreshConfigForTesting()
        let cases: [(String, Any?, String?, Bool)] = [
            ("good", "good-receipt", "good-receipt", false),
            ("interior-nul", "good\0receipt", nil, true),
            ("leading-nul", "\0receipt", nil, true),
            ("trailing-nul", "receipt\0", nil, true),
            ("null", NSNull(), nil, false), ("missing", nil, nil, false),
            ("typed-number", 123, nil, true), ("typed-object", ["bad": true], nil, true),
            ("good-recovery", "recovered-receipt", "recovered-receipt", false),
        ]
        for (index, value) in cases.enumerated() {
            let (label, token, expected, invalid) = value
            let before = diagnostics.get().filter { $0.code == "config.assignment_token_unavailable" }.count
            AttributionCaptureProtocol.serveConfig(try body(count: 0, token: token, flag: index % 2 == 0))
            await client.refreshConfigForTesting()
            var raw = sheepit_crash_cohort_t()
            sheepit_crash_cohort_snapshot(&raw)
            let native = CrashIdentityCohort(raw)
            XCTAssertEqual(native?.userId, user, label)
            XCTAssertEqual(native?.deviceId, device, label)
            XCTAssertEqual(native?.sessionId, session, label)
            XCTAssertEqual(native?.assignmentToken, expected, label)
            XCTAssertEqual(client.context.userId, user, label)
            XCTAssertEqual(client.context.deviceId, device, label)
            XCTAssertEqual(client.context.sessionId, session, label)
            XCTAssertEqual(client.flag("feature"), .bool(index % 2 == 0), label)
            let report = directory.appendingPathComponent("saved-\(index).crash")
            let supplement = directory.appendingPathComponent("saved-\(index).supplement")
            try CrashFixtures.writeReport(to: report, userId: user)
            try CrashCohortFixtures.write(raw, to: supplement)
            let original = try Data(contentsOf: supplement)
            let payload = try XCTUnwrap(CrashReportReader.read(from: report.path, supplementPath: supplement.path))
            let wire = try CrashFixtures.wireJSON(payload)
            XCTAssertEqual(wire["user_id"] as? String, user, label)
            XCTAssertEqual(wire["device_id"] as? String, device, label)
            XCTAssertEqual(wire["session_id"] as? String, session, label)
            XCTAssertEqual(wire["assignment_token"] as? String, expected, label)
            XCTAssertEqual(payload.captureIdentityOutcome, "coherent", label)
            XCTAssertEqual(try Data(contentsOf: supplement), original, label)
            let data = try XCTUnwrap(defaults.data(forKey: SharedSDKStorage.slot(StorageKeys.sdkConfig)))
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let cached = try XCTUnwrap(envelope["data"] as? [String: Any])
            if invalid || token is NSNull {
                XCTAssertTrue(cached["assignment_token"] is NSNull, label)
            } else {
                XCTAssertEqual(cached["assignment_token"] as? String, expected, label)
            }
            let failures = diagnostics.get().filter { $0.code == "config.assignment_token_unavailable" }
            if invalid {
                XCTAssertGreaterThanOrEqual(failures.count - before, 1, label)
            } else {
                XCTAssertEqual(failures.count - before, 0, label)
            }
            XCTAssertTrue(failures.allSatisfy { $0.data?["outcome"]?.value as? String == "invalid_assignment_token" }, label)
            XCTAssertTrue(failures.allSatisfy { $0.data?.keys.sorted() == ["outcome"] }, label)
        }
    }

    private func context(_ event: String) throws -> [String: Any] {
        let sent = try XCTUnwrap(AttributionCaptureProtocol.event(named: event))
        return try XCTUnwrap(sent["context"] as? [String: Any])
    }

    private func assertReceipt(_ context: [String: Any], _ token: String?,
                               file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(context["assignment_token"] as? String, token, file: file, line: line)
        XCTAssertNil(context["experiments"], file: file, line: line)
        XCTAssertNil(context["experiment_assignments"], file: file, line: line)
    }

    func test500ExperimentsKeepOrdinaryPurchaseAndSelectedExposureContextConstant() async throws {
        AttributionCaptureProtocol.serveConfig(try body(count: 1, token: "receipt-shared"))
        let client = try makeClient()
        defer { client.destroy() }
        let deadline = Date().addingTimeInterval(5)
        while client.context.serverHeldUser.user != .known(nil), Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(client.context.serverHeldUser.user, .known(nil), "same confirmed identity for the size comparison")
        await client.refreshConfigForTesting()
        client.track("one")
        await client.flush()
        let one = try context("one")

        AttributionCaptureProtocol.serveConfig(try body(count: 500, token: "receipt-shared"))
        await client.refreshConfigForTesting()
        client.track("five_hundred")
        // Swift has no dedicated trusted-revenue helper: custom purchase events use track().
        client.track("purchase_completed", properties: ["amount": AnyCodable(25), "currency": AnyCodable("USD")])
        XCTAssertEqual(client.flag("feature"), .bool(true))
        XCTAssertEqual(client.experiment("experiment-499").variant, "treatment")
        await client.flush()
        let many = try context("five_hundred")
        for name in ["five_hundred", "purchase_completed", "$flag_exposure", "$experiment_exposure"] {
            assertReceipt(try context(name), "receipt-shared")
        }
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: one).count,
                       try JSONSerialization.data(withJSONObject: many).count)
        XCTAssertLessThan(try JSONSerialization.data(withJSONObject: many).count, 2048)
        let exposure = try XCTUnwrap(AttributionCaptureProtocol.event(named: "$experiment_exposure"))
        XCTAssertEqual((exposure["properties"] as? [String: Any])?["experiment_key"] as? String, "experiment-499")
    }

    /// Deliberately decodable by the actual pre-token SDK too: receipt capture, rather than
    /// only the separately prepared optional-ETag DTO, is what this guard measures.
    func testLegacyETagBodyCapturesReceiptWhileKeepingEvaluatedFlags() async throws {
        AttributionCaptureProtocol.serveConfig(try body(count: 500, token: "receipt-compatible", legacyETag: true))
        let client = try makeClient()
        defer { client.destroy() }
        await client.refreshConfigForTesting()
        XCTAssertEqual(client.flag("feature"), .bool(true), "both SDK versions can decode and apply this body")
        client.track("compatible_body")
        await client.flush()
        assertReceipt(try context("compatible_body"), "receipt-compatible")
    }

    /// Uses only the pre-token constructor/API, so this can run against the real main SDK tree.
    func testPerformanceContextIsCapturedBeforeFlushWithTheLegacyConstructor() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        let context = ContextManager(storage: InMemoryStorage())
        context.setUserId("captured-user")
        context.setDeviceId("captured-device")
        let http = HTTPClient(config: SheepitConfig(apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64),
            apiUrl: "https://stub.invalid", retryAttempts: 1), log: Logger(debug: false),
            urlProtocolClasses: [StubURLProtocol.self])
        let monitor = PerformanceMonitor(http: http, context: context,
            config: PerformanceConfig(maxBatchSize: 100), appVersionOverride: "1", log: Logger(debug: false))
        await monitor.addMetric(PerformanceMetric(metricType: "memory", metricName: "memory_usage", valueMs: 12,
            statusCode: nil, isError: false, timestamp: "2026-11-10T10:00:00.123Z"))
        context.setUserId("flush-user")
        context.setDeviceId("flush-device")
        StubURLProtocol.stub = .status(200, body: "{}")
        await monitor.flush()
        let data = try XCTUnwrap(StubURLProtocol.requestBodies.last)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let metric = try XCTUnwrap((payload["batch"] as? [[String: Any]])?.first)
        let captured = try XCTUnwrap(metric["context"] as? [String: Any])
        XCTAssertEqual(captured["user_id"] as? String, "captured-user")
        XCTAssertEqual(captured["device_id"] as? String, "captured-device")
    }

    func testNewConfigNeverReplacesAQueuedEventsCapturedReceipt() async throws {
        SharedSDKStorage.markRegistered("receipt-device")
        AttributionCaptureProtocol.serveConfig(try body(count: 500, token: "receipt-before"))
        let client = try makeClient()
        defer { client.destroy() }
        await client.refreshConfigForTesting()
        client.track("captured_before")
        AttributionCaptureProtocol.serveConfig(try body(count: 500, token: "receipt-after", flag: false))
        await client.refreshConfigForTesting()
        client.track("captured_after")
        await client.flush()
        assertReceipt(try context("captured_before"), "receipt-before")
        assertReceipt(try context("captured_after"), "receipt-after")
        XCTAssertEqual(client.flag("feature"), .bool(false))
    }

    func testNullAndMissingTokenReplaceOldReceiptWithTheNewFlags() async throws {
        AttributionCaptureProtocol.serveConfig(try body(count: 500, token: "receipt-old"))
        let client = try makeClient()
        defer { client.destroy() }
        for (index, token) in [NSNull() as Any?, nil].enumerated() {
            AttributionCaptureProtocol.serveConfig(try body(count: 500, token: "receipt-old"))
            await client.refreshConfigForTesting()
            AttributionCaptureProtocol.serveConfig(try body(count: 500, token: token, flag: false))
            await client.refreshConfigForTesting()
            client.track("missing_\(index)")
            await client.flush()
            assertReceipt(try context("missing_\(index)"), nil)
            XCTAssertEqual(client.flag("feature"), .bool(false))
        }
    }

    func testIndefiniteCachedConfigAppliesReceiptSynchronouslyWithoutBodyETag() async throws {
        let raw = try body(count: 500, token: "receipt-offline")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: SharedSDKStorage.suite))
        defaults.set(Data(raw.utf8), forKey: SharedSDKStorage.slot(StorageKeys.sdkConfig))
        defaults.set(try JSONEncoder().encode(ServerHeldUser.known(nil)), forKey: SharedSDKStorage.slot(StorageKeys.sdkConfigFetchedUnder))
        defaults.set(String(Date().addingTimeInterval(-366 * 86400).timeIntervalSince1970),
                     forKey: SharedSDKStorage.slot(StorageKeys.sdkConfigCachedAt))
        AttributionCaptureProtocol.failNextConfigRequests(10)
        let client = try makeClient()
        defer { client.destroy() }
        XCTAssertEqual(client.flag("feature"), .bool(true), "first synchronous read uses the cache")
        client.track("offline_first_line")
        await client.flush()
        assertReceipt(try context("offline_first_line"), "receipt-offline")
        XCTAssertNil(AttributionCaptureProtocol.configIfNoneMatch.first ?? nil, "launch never restores a validator")
        XCTAssertFalse(client.getRecentDiagnostics().contains { $0.message.contains("receipt-offline") })
    }

    func testOldCacheWithNoTokenKeepsFlagsWithoutInventingReceiptOrBinding() async throws {
        let storage = InMemoryStorage()
        storage.set(Data(try body(count: 500, token: nil).utf8), forKey: StorageKeys.sdkConfig)
        storage.set(String(Date().addingTimeInterval(-366 * 86400).timeIntervalSince1970),
                    forKey: StorageKeys.sdkConfigCachedAt)
        let decision = LaunchConfigCache.evaluate(storage: storage,
            limits: .default, now: Date(), deviceId: "current")
        guard case .apply(let config, _, _, let resolved) = decision else { return XCTFail("old cache lost flags") }
        XCTAssertEqual(config.flags["feature"]?.value as? Bool, true)
        XCTAssertNil(config.assignmentToken)
        XCTAssertNil(config.etag)
        XCTAssertFalse(resolved, "a missing resolved stamp does not invent a successful bind")
    }
}
