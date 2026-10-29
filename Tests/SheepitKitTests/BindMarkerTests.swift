import XCTest
@testable import SheepitKit

/// The shared bind marker (`BindMarker`) keeps every recently bound device id. It used to hold one id
/// that every bind overwrote, so one client's bind hid another's unanswered POST and that client's
/// `reset()` kept a device that may hold the user.
final class BindMarkerTests: XCTestCase {
    /// 0.6.0 through 0.7.x wrote a bare device id. Reading it as nothing would keep that device on the
    /// first logout after the upgrade.
    func testALegacySingleIdReadsAsAOneElementSet() {
        let storage = InMemoryStorage()
        storage.set("legacy-device", forKey: StorageKeys.deviceBindAttempted)

        XCTAssertTrue(BindMarker.contains("legacy-device", in: storage))
        BindMarker.insert("next-device", in: storage)
        XCTAssertEqual(BindMarker.ids(in: storage), ["legacy-device", "next-device"], "the legacy id is kept, not overwritten")
    }

    func testTheCapTrimsTheOldestAndARebindMovesAnIdToNewest() {
        let storage = InMemoryStorage()
        for index in 0..<BindMarker.cap {
            BindMarker.insert("d\(index)", in: storage)
        }
        let cap = BindMarker.cap
        BindMarker.insert("d0", in: storage)
        XCTAssertEqual(BindMarker.ids(in: storage), (1..<cap).map { "d\($0)" } + ["d0"])

        BindMarker.insert("d\(cap)", in: storage)

        XCTAssertEqual(BindMarker.ids(in: storage), (2..<cap).map { "d\($0)" } + ["d0", "d\(cap)"])
        XCTAssertFalse(BindMarker.contains("d1", in: storage))
    }

    /// A corrupt array must not read as "no bind": that keeps a device that may hold the user.
    func testAnUndecodableArrayCountsAsBoundUntilTheNextBindOverwritesIt() {
        let storage = InMemoryStorage()
        storage.set("[\"truncated", forKey: StorageKeys.deviceBindAttempted)

        XCTAssertTrue(BindMarker.contains("any-device", in: storage))

        BindMarker.insert("next-device", in: storage)
        XCTAssertEqual(BindMarker.ids(in: storage), ["next-device"])
        XCTAssertFalse(BindMarker.contains("any-device", in: storage))
    }

    /// 🔴 Two clients (two storage instances over one suite) marking at once must both survive: a lost
    /// update here is the under-rotation this type exists to prevent. The storage delays reads so
    /// both read-modify-writes overlap unless something serialises them.
    func testConcurrentBindsFromTwoClientsKeepBothIds() {
        let shared = SlowSharedStorage()
        let clients = [shared.client(), shared.client()]
        for round in 0..<20 {
            shared.removeObject(forKey: StorageKeys.deviceBindAttempted)
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                BindMarker.insert("client\(index)-round\(round)", in: clients[index])
            }

            XCTAssertEqual(
                Set(BindMarker.ids(in: shared)),
                ["client0-round\(round)", "client1-round\(round)"],
                "round \(round): one client's bind was lost"
            )
        }
    }

    /// The 0.5.x upgrade inserts the labelled device into the marker. It used to write only when the
    /// marker was empty, which once the marker is a set means another client's id hid this one.
    func testThe05UpgradeAddsTheLabelledDeviceToAMarkerThatHoldsAnotherId() throws {
        let raw = InMemoryStorage()
        raw.set("device-d", forKey: StorageKeys.deviceId)
        raw.set(try JSONEncoder().encode(ServerHeldUser.known("user-1")), forKey: StorageKeys.serverHeldUser)
        BindMarker.insert("device-other", in: raw)

        _ = StorageScope.adoptLegacyState(raw: raw, into: OfflineQueue(storage: InMemoryStorage()))

        XCTAssertEqual(BindMarker.ids(in: raw), ["device-other", "device-d"])
    }
}

/// One dictionary behind a lock, with a pause on every read so concurrent read-modify-writes overlap.
private final class SlowSharedStorage: StorageProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var store: [String: Any] = [:]

    /// A separate provider instance over the same store, as each client holds its own.
    func client() -> StorageProvider { Forwarding(target: self) }

    func string(forKey key: String) -> String? {
        lock.lock()
        let value = store[key] as? String
        lock.unlock()
        Thread.sleep(forTimeInterval: 0.005)
        return value
    }

    func set(_ value: String?, forKey key: String) { put(value, key) }
    func data(forKey key: String) -> Data? { lock.lock(); defer { lock.unlock() }; return store[key] as? Data }
    func set(_ value: Data?, forKey key: String) { put(value, key) }
    func removeObject(forKey key: String) { put(nil, key) }

    private func put(_ value: Any?, _ key: String) {
        lock.lock()
        store[key] = value
        lock.unlock()
    }

    private final class Forwarding: StorageProvider, @unchecked Sendable {
        let target: SlowSharedStorage
        init(target: SlowSharedStorage) { self.target = target }
        func string(forKey key: String) -> String? { target.string(forKey: key) }
        func set(_ value: String?, forKey key: String) { target.set(value, forKey: key) }
        func data(forKey key: String) -> Data? { target.data(forKey: key) }
        func set(_ value: Data?, forKey key: String) { target.set(value, forKey: key) }
        func removeObject(forKey key: String) { target.removeObject(forKey: key) }
    }
}
