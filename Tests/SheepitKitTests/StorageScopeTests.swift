import XCTest
@testable import SheepitKit

/// `StorageScope.hash` must equal sdk-js `tenancyScopeHash` byte for byte. The expected values were
/// computed by running sdk-js itself (`tsx`, `packages/sdk-js/src/config-sync.ts`):
///
///     tenancyScopeHash("https://api.sheepit.ai", "production", "lp_pub_aaa_" + "a".repeat(64)) // 9tzqbk
///
/// Regenerate them the same way if either side changes; never from this file's own implementation.
final class StorageScopeTests: XCTestCase {
    func testTheScopeHashMatchesSdkJs() {
        XCTAssertEqual(
            StorageScope.hash(apiUrl: "https://api.sheepit.ai", environment: "production",
                              apiKey: "lp_pub_aaa_" + String(repeating: "a", count: 64)),
            "9tzqbk"
        )
        // The RAW apiUrl: a trailing slash is a different scope, as in sdk-js.
        XCTAssertEqual(
            StorageScope.hash(apiUrl: "https://stub.invalid/", environment: "staging",
                              apiKey: "lp_pub_bbb_" + String(repeating: "b", count: 64)),
            "f68lgh"
        )
        // JSON escaping, non-ASCII, a surrogate pair (two UTF-16 units) and U+2028, which JS leaves raw.
        XCTAssertEqual(
            StorageScope.hash(apiUrl: "https://x.example/a\"b\\c\n\t\u{01}é/ü😀", environment: "env/ñ\u{2028}", apiKey: "k"),
            "whv6cg"
        )
    }

    func testOnlyServerStateMovesIntoTheSlot() {
        let base = InMemoryStorage()
        let scoped = ScopedStorage(base: base, scope: "abc")
        scoped.set("1", forKey: StorageKeys.deviceRegistered)
        scoped.set("device", forKey: StorageKeys.deviceId)

        XCTAssertEqual(base.string(forKey: "\(StorageKeys.deviceRegistered):abc"), "1")
        XCTAssertNil(base.string(forKey: StorageKeys.deviceRegistered))
        XCTAssertEqual(base.string(forKey: StorageKeys.deviceId), "device", "the device id is shared by every scope")
        for key in [StorageKeys.anonymousId, StorageKeys.identity, StorageKeys.sessionId, StorageKeys.installedAppVersion] {
            XCTAssertEqual(scoped.resolve(key), key)
        }
    }
}
