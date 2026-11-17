import XCTest
@testable import SheepitKit

/// The device id is scoped per (apiUrl, environment, key) since 0.10.0, matching sdk-js's
/// `gt_device_id:<scope>` (`Docs/Technical/SDK_DEVICE_REGISTRATION_CONTRACT.md`). A published
/// install's unscoped `gt_device_id` is carried into the first scope that launches, byte-for-byte,
/// and then deleted (sdk-js `migrateUnscopedDeviceId()`), so another scope mints its own id. 0.9.x
/// kept one unscoped id for every scope.
final class ScopedDeviceIdTests: XCTestCase {
    private static let hex = String(repeating: "a", count: 64)
    private static let configA = SheepitConfig(
        apiKey: "lp_pub_tst_\(hex)", apiUrl: "https://stub.invalid", crashes: CrashConfig(enabled: false))
    private static let configOtherKey = SheepitConfig(
        apiKey: "lp_pub_tst_\(String(repeating: "b", count: 64))", apiUrl: "https://stub.invalid",
        crashes: CrashConfig(enabled: false))
    private static let configOtherHost = SheepitConfig(
        apiKey: "lp_pub_tst_\(hex)", apiUrl: "https://other.invalid", crashes: CrashConfig(enabled: false))

    override func setUp() {
        super.setUp()
        SharedSDKStorage.clear()
        ContractStub.reset()
        TeardownFlushes.install()
    }

    override func tearDown() async throws {
        await TeardownFlushes.drain(context: name)
        SharedSDKStorage.clear()
        ContractStub.reset()
        try await super.tearDown()
    }

    private func client(_ config: SheepitConfig) -> SheepitClient {
        SheepitClient.createForTesting(
            config: config, now: { Date() }, urlProtocolClasses: [ContractStub.self],
            launchRegistrationRetryDelay: { _ in .seconds(60) }
        )
    }

    private var defaults: UserDefaults { UserDefaults(suiteName: SharedSDKStorage.suite)! }

    func testALegacyUnscopedIdIsAdoptedIntoTheScopeByteForByteAndRetired() {
        let legacy = "5F1B3C2E-AAAA-4BBB-8CCC-0123456789AB" // a 0.9.x uppercase id
        defaults.set(legacy, forKey: StorageKeys.deviceId)

        let first = client(Self.configA)
        defer { first.destroy() }

        XCTAssertEqual(first.status().deviceId, legacy, "the published install keeps its device, verbatim")
        XCTAssertEqual(defaults.string(forKey: SharedSDKStorage.key(StorageKeys.deviceId, for: Self.configA)), legacy)
        XCTAssertNil(defaults.string(forKey: StorageKeys.deviceId), "the legacy key is deleted once carried over")
    }

    func testASecondScopeOnTheSameInstallMintsItsOwnId() {
        let legacy = "5F1B3C2E-AAAA-4BBB-8CCC-0123456789AB"
        defaults.set(legacy, forKey: StorageKeys.deviceId)
        let first = client(Self.configA)
        let idA = first.status().deviceId
        first.destroy()

        for config in [Self.configOtherKey, Self.configOtherHost] {
            let other = client(config)
            defer { other.destroy() }
            XCTAssertNotEqual(other.status().deviceId, idA, "\(config.apiUrl): another scope never shares the id")
            XCTAssertEqual(other.status().deviceId, other.status().deviceId?.lowercased(), "a fresh mint")
            XCTAssertEqual(defaults.string(forKey: SharedSDKStorage.key(StorageKeys.deviceId, for: config)), other.status().deviceId)
        }

        let again = client(Self.configA)
        defer { again.destroy() }
        XCTAssertEqual(again.status().deviceId, idA, "each scope keeps its own id across launches")
    }

    /// M1: the legacy key is retired on EVERY launch once the slot holds an id, not only on the
    /// launch that carried it over: a downgrade to 0.9.x and back writes a fresh unscoped id while
    /// the slot keeps its own, and that id must not be left for the next scope to adopt.
    func testALegacyKeyBesideAPopulatedSlotIsRetiredSoAnotherScopeMintsItsOwn() {
        defaults.set("slot-a-device", forKey: SharedSDKStorage.key(StorageKeys.deviceId, for: Self.configA))
        defaults.set("legacy-from-a-downgrade", forKey: StorageKeys.deviceId)

        let first = client(Self.configA)
        XCTAssertEqual(first.status().deviceId, "slot-a-device", "A keeps its slot")
        first.destroy()
        XCTAssertNil(defaults.string(forKey: StorageKeys.deviceId), "the legacy key is gone even though A did not adopt it")

        let second = client(Self.configOtherKey)
        defer { second.destroy() }
        XCTAssertNotEqual(second.status().deviceId, "legacy-from-a-downgrade", "B never adopts the orphan")
        XCTAssertNotEqual(second.status().deviceId, "slot-a-device")
    }

    /// S2: replacing an unusable stored id is reported, with a reason and never the id.
    func testReplacingAnUnusableStoredIdEmitsADiagnosticWithoutTheId() {
        defaults.set("has space", forKey: SharedSDKStorage.key(StorageKeys.deviceId, for: Self.configA))
        let sdk = client(Self.configA)
        defer { sdk.destroy() }
        let event = sdk.getRecentDiagnostics().first { $0.code == "identity.device_id_replaced_unusable" }
        XCTAssertEqual(event?.data?["reason"]?.value as? String, "invalid_character")
        XCTAssertNotEqual(sdk.status().deviceId, "has space")
        let rendered = "\(event?.message ?? "") \(String(describing: event?.data))"
        XCTAssertFalse(rendered.contains("has space"), "the raw id is never logged")
    }

    func testTheProposalIsTheScopedId() async {
        defaults.set("legacy-device-1", forKey: StorageKeys.deviceId)
        ContractStub.script = [.echo]
        let sdk = client(Self.configA)
        defer { sdk.destroy() }
        let deadline = Date().addingTimeInterval(3)
        while ContractStub.registerBodies().isEmpty, Date() < deadline { try? await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(ContractStub.registerBodies().first?["device_id"] as? String, "legacy-device-1")
    }
}
