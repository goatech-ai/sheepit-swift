import XCTest
@testable import SheepitKit

/// A7b — an exposure carries the assignment set its DECISION was made under. Before, `flag()` and
/// `experiment()` read the value under one lock and `track()` snapshotted the assignments later, so
/// a config applied in between sent `$experiment_exposure` reporting one arm with the next config's
/// arm in `context.experiments`. `exposureDecisionHookForTesting` opens exactly that window.
///
/// Isolation mirrors `ExperimentAttributionClientTests`: `SheepitClient` hardcodes its
/// `UserDefaults` suite, so every key these cases depend on is cleared around each one.
final class ExposureDecisionSnapshotTests: XCTestCase {
    private static let suite = "ai.goatech.sdk"

    private static func clearStorage() {
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        for key in [StorageKeys.sdkConfig, StorageKeys.sdkConfigCachedAt,
                    StorageKeys.sdkConfigFetchedUnder, StorageKeys.serverHeldUser, StorageKeys.identity] {
            SharedSDKStorage.remove(key, from: defaults)
        }
    }

    override func setUp() {
        super.setUp()
        Self.clearStorage()
        AttributionCaptureProtocol.reset()
    }

    override func tearDown() {
        Self.clearStorage()
        AttributionCaptureProtocol.reset()
        super.tearDown()
    }

    private func makeClient() -> SheepitClient {
        SheepitClient.createForTesting(
            config: SheepitConfig(
                apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64),
                apiUrl: "https://stub.invalid",
                flushInterval: 3600,
                flushSize: 1000,
                configRefreshInterval: 3600,
                retryAttempts: 1,
                // 🔴 Real signal handlers in the test process kill whichever test runs next.
                crashes: CrashConfig(enabled: false)
            ),
            now: { Date() },
            urlProtocolClasses: [AttributionCaptureProtocol.self],
            identifyRetryDelays: []
        )
    }

    private func assignment(_ variant: String) throws -> SDKExperimentAssignment {
        let json = #"{"variant_key":"\#(variant)","payload":{},"experiment_id":"11111111-1111-4111-8111-111111111111","#
            + #""subject_kind":"user","bucketing_version":1,"assignment_revision":"7"}"#
        return try JSONDecoder().decode(SDKExperimentAssignment.self, from: Data(json.utf8))
    }

    /// An identified client whose config carries `flagKey`, with `pricing_test` seeded as
    /// `treatment` under the same user, so every entry it sends is resolved, not marked.
    private func identifiedClient(user: String, flagKey: String) async throws -> SheepitClient {
        AttributionCaptureProtocol.serveConfig(
            #"{"data":{"config_version":"8","etag":"\"v8\"","flags":{"\#(flagKey)":true},"experiments":{}}}"#)
        AttributionCaptureProtocol.honorIfNoneMatch = false
        let client = makeClient()
        // The start-up work registers the device first; an identify before that is deferred.
        let deadline = Date().addingTimeInterval(5)
        while AttributionCaptureProtocol.configRequestCount < 1, Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        client.identify(userId: user)
        await client.awaitIdentityPostForTesting()
        XCTAssertEqual(client.status().flagCount, 1, "precondition: the refetched config is applied")
        client.seedAssignmentsForTesting(["pricing_test": try assignment("treatment")], appliedUnderUserId: user, assignmentToken: "receipt-treatment")
        return client
    }

    /// Moves `pricing_test` to `control` inside the decision → track window.
    private func moveArmInsideTheWindow(_ client: SheepitClient, user: String) throws {
        let control = try assignment("control")
        client.exposureDecisionHookForTesting.value = { _ in
            client.seedAssignmentsForTesting(["pricing_test": control], appliedUnderUserId: user, assignmentToken: "receipt-control")
        }
    }

    private func sentContext(_ name: String, user: String) throws -> [String: Any] {
        let event = try XCTUnwrap(AttributionCaptureProtocol.event(named: name, userId: user), "\(name) was never sent")
        return try XCTUnwrap(event["context"] as? [String: Any])
    }

    private func arm(_ context: [String: Any]) -> String? {
        context["assignment_token"] as? String
    }

    private func entryVariant(_ context: [String: Any]) -> String? {
        context["assignment_token"] as? String
    }

    func testExperimentExposureCarriesTheAssignmentsItsVariantWasDecidedUnder() async throws {
        let user = "user-decision-\(UUID().uuidString)"
        let client = try await identifiedClient(user: user, flagKey: "unused_flag")
        defer { client.destroy() }
        try moveArmInsideTheWindow(client, user: user)

        let result = client.experiment("pricing_test")
        client.exposureDecisionHookForTesting.value = nil
        await client.flush()

        XCTAssertEqual(result.variant, "treatment", "precondition: the app was given treatment")
        let event = try XCTUnwrap(AttributionCaptureProtocol.event(named: "$experiment_exposure", userId: user))
        XCTAssertEqual((event["properties"] as? [String: Any])?["variant"] as? String, "treatment")
        let context = try sentContext("$experiment_exposure", user: user)
        XCTAssertEqual(arm(context), "receipt-treatment", "the exposure must name the arm it reports, not the next config's")
        XCTAssertEqual(entryVariant(context), "receipt-treatment")
    }

    func testFlagExposureCarriesTheAssignmentsItsValueWasDecidedUnder() async throws {
        let user = "user-decision-\(UUID().uuidString)"
        let flagKey = "decision_flag_\(UUID().uuidString.prefix(8))"
        let client = try await identifiedClient(user: user, flagKey: flagKey)
        defer { client.destroy() }
        try moveArmInsideTheWindow(client, user: user)

        let value = client.flag(flagKey)
        client.exposureDecisionHookForTesting.value = nil
        await client.flush()

        XCTAssertEqual(value, .bool(true), "precondition: the app was given the served value")
        let event = try XCTUnwrap(AttributionCaptureProtocol.event(named: "$flag_exposure", userId: user))
        XCTAssertEqual((event["properties"] as? [String: Any])?["flag_value"] as? Bool, true)
        let context = try sentContext("$flag_exposure", user: user)
        XCTAssertEqual(arm(context), "receipt-treatment", "the exposure must carry the arms of the config its value came from")
        XCTAssertEqual(entryVariant(context), "receipt-treatment")
    }

    /// `ExposureDecisionGate`: a config applied on another thread while `flag()` is between reading
    /// its value and capturing the assignments waits for the decision, so the exposure pairs the
    /// value with the arms of the SAME config. Fails if either side drops the gate: the apply lands
    /// during the pause and the exposure carries the new config's `control`.
    func testAConfigAppliedWhileAFlagDecidesWaitsForTheDecision() async throws {
        let user = "user-decision-\(UUID().uuidString)"
        let flagKey = "decision_flag_\(UUID().uuidString.prefix(8))"
        let client = try await identifiedClient(user: user, flagKey: flagKey)
        defer { client.destroy() }
        let control = try assignment("control")
        let gate = client.exposureDecisionGateForTesting
        let applied = LockedBox(false)
        let heldAtDecision = LockedBox(false)
        let appliedInsideDecision = LockedBox(true)
        let applyReachedGate = LockedBox(false)
        client.flagDecisionInsideGateHookForTesting.value = { _ in
            heldAtDecision.set(gate.isHeldForTesting())
            // Ordering proof, no timing: the apply either reaches the gate (and must then wait for
            // this decision), or bypasses it and finishes. Whichever happens first is recorded.
            let reachedGate = DispatchSemaphore(value: 0)
            gate.willLockHookForTesting.value = { _ in reachedGate.signal() }
            Thread {
                client.applyConfigForTesting(flags: [flagKey: AnyCodable(false)],
                                             assignments: ["pricing_test": control], appliedUnder: .fetchedUnder(user), assignmentToken: "receipt-control")
                applied.set(true)
            }.start()
            let deadline = Date().addingTimeInterval(5)
            var reached = false
            while !reached, !applied.get(), Date() < deadline {
                reached = reachedGate.wait(timeout: .now() + .milliseconds(5)) == .success
            }
            applyReachedGate.set(reached)
            appliedInsideDecision.set(applied.get())
        }

        let value = client.flag(flagKey)
        client.flagDecisionInsideGateHookForTesting.value = nil
        gate.willLockHookForTesting.value = nil
        let deadline = Date().addingTimeInterval(5)
        while !applied.get(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        await client.flush()

        XCTAssertTrue(heldAtDecision.get(), "flag() decides while holding the gate")
        XCTAssertTrue(applyReachedGate.get(), "the apply reached the gate during the decision")
        XCTAssertFalse(appliedInsideDecision.get(), "the apply reached the gate and waited, rather than landing")
        XCTAssertTrue(applied.get(), "precondition: the concurrent apply finished")
        XCTAssertEqual(value, .bool(true))
        XCTAssertEqual(client.flag(flagKey), .bool(false), "precondition: the apply landed after the decision")
        let context = try sentContext("$flag_exposure", user: user)
        XCTAssertEqual(arm(context), "receipt-treatment", "the exposure carries the arms of the config its value came from")
    }

    /// DESIGN GUARD: an ordinary `track()` still stamps the assignments current at track time.
    func testAPlainTrackStampsTheCurrentAssignments() async throws {
        let user = "user-decision-\(UUID().uuidString)"
        let client = try await identifiedClient(user: user, flagKey: "unused_flag")
        defer { client.destroy() }
        client.seedAssignmentsForTesting(["pricing_test": try assignment("control")], appliedUnderUserId: user, assignmentToken: "receipt-control")

        let name = "decision_plain_\(UUID().uuidString.prefix(8))"
        client.track(name)
        await client.flush()

        XCTAssertEqual(arm(try sentContext(name, user: user)), "receipt-control")
    }
}
