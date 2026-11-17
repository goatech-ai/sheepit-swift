import XCTest
@testable import SheepitKit

/// SK-Q9: a logout rotation whose registration the server answers with a REPLACED id adopts it in
/// `DeviceRotation.adopt`. A second `reset()` landing after the register loop's `isCurrent` check
/// installs a newer placeholder, and the plain `setDeviceId` there overwrote it with the first
/// rotation's id. Now a compare-and-set, as the launch path (`adoptLaunchRegistration`). Also the
/// C5 replacement's guard for a device the client already left (`replaceErasedDevice`).
final class DeviceRotationAdoptRaceTests: XCTestCase {
    private static let replacedId = "dev_replaced_adopt_race"

    override func setUp() {
        super.setUp()
        AttributionCaptureProtocol.reset()
        AttributionCaptureProtocol.registerDeviceId = Self.replacedId
    }

    override func tearDown() {
        AttributionCaptureProtocol.reset()
        super.tearDown()
    }

    private struct Rig {
        let storage: WriteHookStorage
        let context: ContextManager
        let bus: DiagnosticBus
        let rotation: DeviceRotation
    }

    private func makeRig(beforeDeviceIdChange: @escaping @Sendable () -> Void = {}) -> Rig {
        let storage = WriteHookStorage()
        let context = ContextManager(storage: storage)
        let bus = DiagnosticBus()
        let log = Logger(debug: false)
        let http = HTTPClient(
            config: SheepitConfig(apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64),
                                  apiUrl: "https://stub.invalid", retryAttempts: 1),
            log: log, urlProtocolClasses: [AttributionCaptureProtocol.self])
        let rotation = DeviceRotation(.init(
            context: context,
            deviceManager: DeviceManager(http: http, log: log, appVersionOverride: "1.0"),
            policy: RegistrationPolicy(storage: storage, diagnostics: bus, log: log, now: { Date() }, appVersion: "1.0"),
            queue: EventQueue(maxSize: 100),
            offlineQueue: OfflineQueue(storage: storage),
            storage: storage,
            diagnostics: bus,
            configSync: ConfigSync(http: http, storage: storage, refreshInterval: 3600, log: log,
                                   identityProvider: { (.fetchedUnder(nil), 0) }, onConfig: { _, _, _ in }),
            registrationGate: RegistrationGate(),
            now: { Date() },
            isDestroyed: { false },
            onDeviceIdChanged: {},
            beforeDeviceIdChange: beforeDeviceIdChange
        ))
        rotation.retryDelayOverride = { _ in .milliseconds(1) }
        return Rig(storage: storage, context: context, bus: bus, rotation: rotation)
    }

    /// The receipt issued for the old device must be invalid BEFORE the new id is visible, or a capture
    /// in between pairs the old device's token with the new device id.
    func testTheReceiptIsInvalidatedBeforeEveryDeviceIdWrite() async {
        let seenAtCall = LockedBox<[String]>([])
        let holder = LockedBox<ContextManager?>(nil)
        let rig = makeRig(beforeDeviceIdChange: { seenAtCall.mutate { $0.append(holder.get()?.deviceId ?? "") } })
        holder.set(rig.context)
        defer { rig.rotation.cancel() }
        let original = rig.context.deviceId
        rig.rotation.rotate()
        let settled = await waitUntil {
            rig.bus.getRecentDiagnostics().contains { $0.code == "identity.device_rotated_on_reset" }
        }
        XCTAssertTrue(settled, "precondition: the rotation adopted the replaced id")
        let seen = seenAtCall.get()
        XCTAssertEqual(seen.count, 2, "once before the placeholder is written, once before the adopted id")
        XCTAssertEqual(seen.first, original, "called while the old device id was still current")
        XCTAssertFalse(seen.contains(Self.replacedId), "never after the replaced id became current")
    }

    func testASecondResetDuringAReplacedAdoptKeepsTheNewerDevice() async {
        let rig = makeRig()
        let (storage, context, bus, rotation) = (rig.storage, rig.context, rig.bus, rig.rotation)
        defer { rotation.cancel() }
        // The first write of the replaced id is `adopt`'s persist-ahead: the second `reset()` lands there.
        let newer = LockedBox<String?>(nil)
        storage.onStringWrite.value = { value in
            guard value == Self.replacedId, newer.get() == nil else { return }
            AttributionCaptureProtocol.holdRegister = true
            rotation.rotate()
            newer.set(context.deviceId)
        }

        rotation.rotate()

        let settled = await waitUntil {
            bus.getRecentDiagnostics().contains {
                $0.code == "identity.device_registration_superseded" || $0.code == "identity.device_rotated_on_reset"
            }
        }
        XCTAssertTrue(settled, "precondition: the first rotation's answer was handled")
        let placeholder = newer.get()
        XCTAssertNotNil(placeholder, "precondition: the second reset landed inside the adopt")
        XCTAssertNotEqual(placeholder, Self.replacedId)
        XCTAssertEqual(context.deviceId, placeholder, "the first rotation's replaced id overwrote the newer reset's device")
        XCTAssertEqual(storage.string(forKey: StorageKeys.deviceId), placeholder, "the newer device is not the one on disk")
    }

    /// C5's replacement for a device the client already left (a logout rotated between the trigger
    /// and the replacement): `replaceUnknown` answers with the device in use, which is not a
    /// replacement, so nothing is relabelled and no config is fetched for it.
    func testAnErasedDeviceReplacementForADeviceAlreadyLeftChangesNothing() async {
        let rig = makeRig()
        defer { rig.rotation.cancel() }
        rig.context.setServerHeldUser(.known("user-u"))
        let current = rig.context.deviceId

        let unreplaced = LockedBox(false)
        let outcome = ConfigSync.ErasedDeviceOutcome(minted: {}, unreplaced: { unreplaced.set(true) })
        XCTAssertEqual(rig.rotation.replaceErasedDevice("device-already-left", outcome: outcome), .notCurrent)
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(rig.context.deviceId, current)
        XCTAssertEqual(rig.context.serverHeldUser.user, .known("user-u"), "the device in use was relabelled")
        XCTAssertEqual(AttributionCaptureProtocol.configRequestCount, 0, "config was refetched for a device that was not replaced")
        XCTAssertEqual(AttributionCaptureProtocol.registerRequestCount, 0)
        XCTAssertFalse(unreplaced.get(), "the device in use had its values dropped")
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }
}

/// In-memory storage that reports every string write after it lands.
private final class WriteHookStorage: StorageProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: Any] = [:]
    let onStringWrite = LockedValue<(@Sendable (String?) -> Void)?>(nil)

    func string(forKey key: String) -> String? { lock.lock(); defer { lock.unlock() }; return store[key] as? String }
    func set(_ value: String?, forKey key: String) {
        put(value, key)
        onStringWrite.value?(value)
    }
    func data(forKey key: String) -> Data? { lock.lock(); defer { lock.unlock() }; return store[key] as? Data }
    func set(_ value: Data?, forKey key: String) { put(value, key) }
    func removeObject(forKey key: String) { put(nil, key) }

    private func put(_ value: Any?, _ key: String) {
        lock.lock()
        store[key] = value
        lock.unlock()
    }
}
