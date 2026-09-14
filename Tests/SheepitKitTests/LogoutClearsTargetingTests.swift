import XCTest

@testable import SheepitKit

/// 🔴 Logout must not leave the previous user's targeting on the device.
///
/// `reset()` cleared the IDENTITY but not what had been evaluated FOR it, and
/// that lived in three separate places — the cached `/v1/config` body in
/// storage, the evaluated flag values in memory, and the server experiment
/// assignments in memory. The cache key carries no user component, so the body
/// persisted and was re-applied on the next launch.
///
/// `UserDefaults` is included in device backups, so on iOS the copy outlives
/// the app rather than merely the session.
final class LogoutClearsTargetingTests: XCTestCase {

    /// Client-level tests here share the real `ai.goatech.sdk` suite with every other suite, so
    /// the config and label keys are cleared around each test.
    private static func clearConfigStorage() {
        guard let defaults = UserDefaults(suiteName: "ai.goatech.sdk") else { return }
        for key in [StorageKeys.sdkConfig, StorageKeys.sdkConfigCachedAt,
                    StorageKeys.sdkConfigFetchedUnder, StorageKeys.serverHeldUser] {
            defaults.removeObject(forKey: key)
        }
    }

    override func setUp() {
        super.setUp()
        Self.clearConfigStorage()
    }

    override func tearDown() {
        Self.clearConfigStorage()
        super.tearDown()
    }

    /// Built by DECODING rather than with the memberwise init: the wire type
    /// gains fields over time (S3 added four), and a memberwise call would have
    /// to be edited every time. This also exercises the path the SDK really uses.
    private func assignment(variant: String) throws -> SDKExperimentAssignment {
        let json = #"{"variant_key":"\#(variant)","payload":{}}"#
        return try JSONDecoder().decode(
            SDKExperimentAssignment.self, from: Data(json.utf8))
    }

    // MARK: - In-memory state

    func testClearEvaluatedForgetsFlagValues() {
        let mgr = FlagManager()
        mgr.setEvaluatedFlags(["premium_ui": AnyCodable(true)])
        XCTAssertEqual(
            mgr.count(), 1,
            "precondition: the value must be live, or the assertion below proves nothing")

        mgr.clearEvaluated()

        XCTAssertEqual(
            mgr.count(), 0, "the logged-out user's flag values must not survive reset()")
    }

    func testClearForLogoutForgetsTheServerAssignment() throws {
        let mgr = ExperimentManager(storage: InMemoryStorage())
        mgr.setAssignments(["pricing_test": try assignment(variant: "treatment")], appliedUnderUserId: nil)
        XCTAssertEqual(mgr.count(), 1, "precondition: the assignment must be live")

        mgr.clearForLogout()

        XCTAssertEqual(
            mgr.count(), 0,
            "the logged-out user's variant and payload must not survive reset()")
    }

    /// The distinction that keeps `identify()` correct: it clears the STICKY map
    /// only. Wiping the server's assignments there would make `experiment()`
    /// answer "control" — a real arm — for a subject never bucketed into it,
    /// for the whole window until the next `/v1/config` landed.
    func testClearAssignmentsLeavesTheServerAssignmentForIdentify() throws {
        let mgr = ExperimentManager(storage: InMemoryStorage())
        mgr.setAssignments(["pricing_test": try assignment(variant: "treatment")], appliedUnderUserId: nil)

        mgr.clearAssignments()

        XCTAssertEqual(
            mgr.count(), 1, "identify() must not drop the server's current bucketing")
    }

    // MARK: - Through the real reset()

    /// 🔴 The manager-level tests above would ALL still pass if the body of
    /// `SheepitClient.reset()` were deleted — they never call it. This one does,
    /// against the same `UserDefaults` suite the client really uses, so it fails
    /// if the wiring is removed rather than only if a manager is.
    func testSheepitClientResetRemovesTheCachedConfigFromDisk() throws {
        let suite = "ai.goatech.sdk"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(Data("{}".utf8), forKey: StorageKeys.sdkConfig)
        defaults.set(String(Date().timeIntervalSince1970), forKey: StorageKeys.sdkConfigCachedAt)
        XCTAssertNotNil(
            defaults.data(forKey: StorageKeys.sdkConfig),
            "precondition: the cache must be seeded")

        let client = SheepitClient.createForTesting(
            config: SheepitConfig(
                apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64),
                apiUrl: "https://stub.invalid",
                // Real crash handlers in the test process crash a later test with signal 11.
                crashes: CrashConfig(enabled: false)),
            now: { Date() },
            urlProtocolClasses: [StubURLProtocol.self])
        defer { client.destroy() }

        client.reset()

        XCTAssertNil(
            defaults.data(forKey: StorageKeys.sdkConfig),
            "reset() must remove the cached config synchronously, not in a detached Task")
        XCTAssertNil(defaults.string(forKey: StorageKeys.sdkConfigCachedAt))
    }

    /// 🔴 `reset()` must call `clearForLogout()`, not `clearAssignments()`.
    ///
    /// The two differ only in whether the SERVER's in-memory assignments go,
    /// and a mutation run showed that swapping one for the other in `reset()`
    /// was caught by nothing — the manager-level tests pass either way because
    /// they call the manager directly. This drives the real client.
    func testSheepitClientResetForgetsTheServerAssignmentNotJustTheStickyMap() throws {
        let client = SheepitClient.createForTesting(
            config: SheepitConfig(
                apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64),
                apiUrl: "https://stub.invalid",
                // Real crash handlers in the test process crash a later test with signal 11.
                crashes: CrashConfig(enabled: false)),
            now: { Date() },
            urlProtocolClasses: [StubURLProtocol.self])
        defer { client.destroy() }

        client.seedAssignmentsForTesting([
            "pricing_test": try assignment(variant: "treatment")
        ])
        XCTAssertEqual(
            client.experiment("pricing_test").variant, "treatment",
            "precondition: the assignment must be live before reset()")

        client.reset()

        XCTAssertEqual(
            client.experiment("pricing_test").variant, "control",
            "the logged-out user's arm must not survive reset()")
    }

    // MARK: - The cached body

    func testClearCacheRemovesBothTheBodyAndItsTimestamp() async {
        let storage = InMemoryStorage()
        storage.set(Data("{}".utf8), forKey: StorageKeys.sdkConfig)
        storage.set("123", forKey: StorageKeys.sdkConfigCachedAt)

        let sync = ConfigSync(
            http: HTTPClient(
                config: SheepitConfig(
                    apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64),
                    apiUrl: "https://stub.invalid"),
                log: Logger(debug: false)),
            storage: storage,
            refreshInterval: 60,
            log: Logger(debug: false),
            identityProvider: { (.fetchedUnder(nil), 0) },
            onConfig: { _, _ in })
        await sync.clearCache()

        XCTAssertNil(storage.data(forKey: StorageKeys.sdkConfig))
        XCTAssertNil(storage.string(forKey: StorageKeys.sdkConfigCachedAt))
    }
}
