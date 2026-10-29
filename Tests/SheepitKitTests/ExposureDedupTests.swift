import XCTest
@testable import SheepitKit

/// R7 A1s + A2s: exposure dedup survives a config refresh, and is keyed per flag VALUE and per
/// experiment ARM. Mirrors sdk-js #1332 (`flags.ts`, `experiments.ts`).
///
/// Against SheepitKit 0.7.0 these fail: `setEvaluatedFlags` cleared the flag dedup on every apply,
/// so every refresh re-fired `$flag_exposure` for every flag read; experiment dedup was keyed per
/// experiment, so a subject moved to another arm was never exposed to it.
final class ExposureDedupTests: XCTestCase {
    private typealias FlagExposure = (key: String, value: FlagValue, reason: FlagExposureReason)
    private typealias ArmExposure = (key: String, variant: String, reason: ExperimentExposureReason)

    // MARK: - Flags

    private func read(_ manager: FlagManager, _ key: String) -> [FlagExposure] {
        var fired: [FlagExposure] = []
        _ = manager.evaluate(flagKey: key, defaultValue: .bool(false)) { fired.append(($0, $1, $2)) }
        return fired
    }

    func testARefreshWithTheSameValueDoesNotReExpose() {
        let manager = FlagManager()
        manager.setEvaluatedFlags(["a": AnyCodable(true)])
        XCTAssertEqual(read(manager, "a").map(\.reason), [.first])

        manager.setEvaluatedFlags(["a": AnyCodable(true)])
        XCTAssertTrue(read(manager, "a").isEmpty, "a refresh that returns the same value is not a new exposure")
    }

    func testAChangedValueExposesOnceMore() {
        let manager = FlagManager()
        manager.setEvaluatedFlags(["a": AnyCodable("red")])
        _ = read(manager, "a")

        manager.setEvaluatedFlags(["a": AnyCodable("blue")])
        let fired = read(manager, "a")
        XCTAssertEqual(fired.map(\.reason), [.valueChanged])
        XCTAssertEqual(fired.first?.value, .string("blue"))
        XCTAssertTrue(read(manager, "a").isEmpty)
    }

    func testAValueThatChangesAndComesBackBeforeAReadIsNotReExposed() {
        let manager = FlagManager()
        manager.setEvaluatedFlags(["a": AnyCodable(1)])
        _ = read(manager, "a")
        manager.setEvaluatedFlags(["a": AnyCodable(2)])
        manager.setEvaluatedFlags(["a": AnyCodable(1)])
        XCTAssertTrue(read(manager, "a").isEmpty, "the caller was only ever shown 1")
    }

    func testAnObjectValueWithReorderedKeysIsTheSameValue() throws {
        let manager = FlagManager()
        let first = try JSONDecoder().decode([String: AnyCodable].self, from: Data(#"{"a":{"x":1,"y":[1,2]}}"#.utf8))
        let second = try JSONDecoder().decode([String: AnyCodable].self, from: Data(#"{"a":{"y":[1,2],"x":1}}"#.utf8))
        manager.setEvaluatedFlags(first)
        _ = read(manager, "a")
        manager.setEvaluatedFlags(second)
        XCTAssertTrue(read(manager, "a").isEmpty)
    }

    func testAFlagTheServerStoppedSendingIsFirstAgainWhenItReturns() {
        let manager = FlagManager()
        manager.setEvaluatedFlags(["a": AnyCodable(true)])
        _ = read(manager, "a")
        manager.setEvaluatedFlags([:])
        manager.setEvaluatedFlags(["a": AnyCodable(true)])
        XCTAssertEqual(read(manager, "a").map(\.reason), [.first])
    }

    func testAnIdentityChangeReArmsEveryFlag() {
        let manager = FlagManager()
        manager.setEvaluatedFlags(["a": AnyCodable(true)])
        _ = read(manager, "a")
        manager.clearExposed()
        XCTAssertEqual(read(manager, "a").map(\.reason), [.first])
    }

    // MARK: - Experiments

    private func assignment(_ variant: String) throws -> SDKExperimentAssignment {
        try JSONDecoder().decode(SDKExperimentAssignment.self, from: Data(#"{"variant_key":"\#(variant)","payload":{}}"#.utf8))
    }

    private func read(_ manager: ExperimentManager, _ key: String) -> [ArmExposure] {
        var fired: [ArmExposure] = []
        _ = manager.resolve(experimentKey: key) { fired.append(($0, $1, $2)) }
        return fired
    }

    func testARefreshWithTheSameArmDoesNotReExpose() throws {
        let manager = ExperimentManager(storage: InMemoryStorage())
        manager.setAssignments(["e": try assignment("a")], appliedUnderUserId: nil)
        XCTAssertEqual(read(manager, "e").map(\.reason), [.first])
        manager.setAssignments(["e": try assignment("a")], appliedUnderUserId: nil)
        XCTAssertTrue(read(manager, "e").isEmpty)
    }

    func testAMoveToAnotherArmIsExposedForTheNewArm() throws {
        let manager = ExperimentManager(storage: InMemoryStorage())
        manager.setAssignments(["e": try assignment("a")], appliedUnderUserId: nil)
        _ = read(manager, "e")

        manager.setAssignments(["e": try assignment("b")], appliedUnderUserId: nil)
        let fired = read(manager, "e")
        XCTAssertEqual(fired.map(\.reason), [.variantChanged], "keyed per experiment, arm b was never exposed")
        XCTAssertEqual(fired.first?.variant, "b")
        XCTAssertTrue(read(manager, "e").isEmpty)
    }

    func testAnExperimentTheServerStoppedSendingIsFirstAgainWhenItReturns() throws {
        let manager = ExperimentManager(storage: InMemoryStorage())
        manager.setAssignments(["e": try assignment("a")], appliedUnderUserId: nil)
        _ = read(manager, "e")
        manager.setAssignments([:], appliedUnderUserId: nil)
        manager.setAssignments(["e": try assignment("b")], appliedUnderUserId: nil)
        XCTAssertEqual(read(manager, "e").map(\.reason), [.first])
    }

    func testAnIdentityChangeReArmsEveryArm() throws {
        let manager = ExperimentManager(storage: InMemoryStorage())
        manager.setAssignments(["e": try assignment("a")], appliedUnderUserId: nil)
        _ = read(manager, "e")
        manager.clearAssignments()
        XCTAssertEqual(read(manager, "e").map(\.reason), [.first], "identify() keeps the arm but re-arms its exposure")
    }

    func testTheLegacyStickyMapIsDroppedOnRequestAndNeverWritten() throws {
        let storage = InMemoryStorage()
        storage.set(Data(#"{"e":"a"}"#.utf8), forKey: StorageKeys.experimentAssignments)

        let manager = ExperimentManager(storage: storage)
        XCTAssertNotNil(storage.data(forKey: StorageKeys.experimentAssignments), "construction writes nothing")
        manager.dropLegacyStickyMap()
        XCTAssertNil(storage.data(forKey: StorageKeys.experimentAssignments), "an older SDK's sticky map is dropped")

        manager.setAssignments(["e": try assignment("b")], appliedUnderUserId: nil)
        _ = read(manager, "e")
        XCTAssertNil(storage.data(forKey: StorageKeys.experimentAssignments), "nothing reads it, so nothing writes it")
    }

    // MARK: - Through the client

    override func setUp() {
        super.setUp()
        SharedSDKStorage.clear()
    }

    override func tearDown() {
        SharedSDKStorage.clear()
        super.tearDown()
    }

    private func makeClient(events: ExposureLog) -> SheepitClient {
        SheepitClient.createForTesting(
            config: SheepitConfig(
                apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64),
                apiUrl: "https://stub.invalid",
                flushInterval: 3600,
                flushSize: 1000,
                configRefreshInterval: 3600,
                retryAttempts: 1,
                onEvent: { name, properties in events.record(name, properties) },
                // A client with crash reporting on installs real signal handlers into the test process.
                crashes: CrashConfig(enabled: false)
            ),
            now: { Date() },
            // Every request fails, so the client's own config fetch never applies over the seeded state.
            urlProtocolClasses: [OfflineURLProtocol.self]
        )
    }

    /// An inert client must make zero writes to disk (E-001); only a client that begins work drops
    /// the legacy key.
    func testOnlyAClientThatBeginsWorkDropsTheLegacyStickyMap() {
        guard let defaults = UserDefaults(suiteName: SharedSDKStorage.suite) else { return XCTFail("no suite") }
        let legacy = Data(#"{"e":"a"}"#.utf8)
        defaults.set(legacy, forKey: StorageKeys.experimentAssignments)

        let inert = SheepitClient.create(config: SheepitConfig(
            apiKey: "lp_sec_tst_" + String(repeating: "a", count: 64),
            crashes: CrashConfig(enabled: false)
        ))
        XCTAssertNotNil(inert.inertReason)
        inert.destroy()
        XCTAssertEqual(defaults.data(forKey: StorageKeys.experimentAssignments), legacy, "an inert client wrote to disk")

        let live = makeClient(events: ExposureLog())
        defer { live.destroy() }
        XCTAssertNil(defaults.data(forKey: StorageKeys.experimentAssignments))
    }

    func testFlagExposureCarriesItsReasonAndAChangeIsDiagnosed() {
        let events = ExposureLog()
        let sdk = makeClient(events: events)
        defer { sdk.destroy() }

        sdk.flagManager.setEvaluatedFlags(["a": AnyCodable("red")])
        _ = sdk.flag("a")
        sdk.flagManager.setEvaluatedFlags(["a": AnyCodable("red")])
        _ = sdk.flag("a")
        sdk.flagManager.setEvaluatedFlags(["a": AnyCodable("blue")])
        _ = sdk.flag("a")

        XCTAssertEqual(events.reasons(of: "$flag_exposure"), ["first", "value_changed"])
        let codes = sdk.diagnosticBus.getRecentDiagnostics().map(\.code)
        XCTAssertEqual(codes.filter { $0 == "flag.exposure_value_changed" }.count, 1)
    }

    func testExperimentExposureCarriesItsReasonAndAMoveIsDiagnosed() throws {
        let events = ExposureLog()
        let sdk = makeClient(events: events)
        defer { sdk.destroy() }

        sdk.seedAssignmentsForTesting(["e": try assignment("a")], appliedUnderUserId: nil)
        _ = sdk.experiment("e")
        sdk.seedAssignmentsForTesting(["e": try assignment("a")], appliedUnderUserId: nil)
        _ = sdk.experiment("e")
        sdk.seedAssignmentsForTesting(["e": try assignment("b")], appliedUnderUserId: nil)
        _ = sdk.experiment("e")

        XCTAssertEqual(events.reasons(of: "$experiment_exposure"), ["first", "variant_changed"])
        let codes = sdk.diagnosticBus.getRecentDiagnostics().map(\.code)
        XCTAssertEqual(codes.filter { $0 == "experiment.exposure_variant_changed" }.count, 1)
    }
}

private final class ExposureLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(name: String, reason: String?)] = []

    func record(_ name: String, _ properties: [String: Any]?) {
        lock.lock()
        defer { lock.unlock() }
        entries.append((name, properties?["exposure_reason"] as? String))
    }

    func reasons(of name: String) -> [String?] {
        lock.lock()
        defer { lock.unlock() }
        return entries.filter { $0.name == name }.map(\.reason)
    }
}
