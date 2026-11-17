import XCTest
@testable import SheepitKit

/// Host rules, path encoding and the device-id shape:
/// `Docs/Technical/SDK_DEVICE_REGISTRATION_CONTRACT.md` § 1 and § 4 (acceptance test 9), identical
/// in every SDK. 0.9.x admitted credentials, a query string, a fragment and an out-of-range port,
/// interpolated device ids into paths unencoded, and minted uppercase ids.
final class APIURLValidationTests: XCTestCase {
    func testCredentialsQueryFragmentAndBadPortsAreRefused() {
        for url in [
            "https://user:secret@api.example.com",
            "https://token@api.example.com",
            "https://api.example.com?env=prod",
            "https://api.example.com/_sheepit?",
            "https://api.example.com#frag",
            "https://api.example.com:70000",
            "https://api.example.com:0",
            "http://localhost:0/_sheepit",
            "https://api.example.com:abc",
            "ftp://api.example.com",
            "https://",
            "not a url",
        ] {
            XCTAssertNotNil(SheepitClient.apiURLRejectionReason(for: url), "\(url) must be refused")
        }
    }

    func testPlainHTTPLocalhostIPLiteralsRegistryNamesAndPathPrefixesAreAllowed() {
        for url in [
            "https://api.sheepit.ai",
            "http://api.example.com",
            "http://localhost:3000",
            "http://127.0.0.1:8080",
            "http://[::1]:8080",
            "http://sheepit_api:3000",
            "http://h:",
            "https://app.example.com/_sheepit/",
        ] {
            XCTAssertNil(SheepitClient.apiURLRejectionReason(for: url), "\(url) must be allowed")
        }
    }

    func testARefusedURLNeverEchoesItsCredentials() {
        let reason = SheepitClient.apiURLRejectionReason(for: "https://user:sup3rs3cret@api.example.com") ?? ""
        XCTAssertFalse(reason.contains("sup3rs3cret"))
    }

    func testARefusedURLMakesTheClientInertRatherThanFallingBack() {
        let config = SheepitConfig(apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))", apiUrl: "https://u:p@api.example.com")
        let client = SheepitClient.create(config: config)
        defer { client.destroy() }
        XCTAssertFalse(client.status().initialized)
    }

    // MARK: - § 1: path-interpolated ids are percent-encoded

    func testPathInterpolatedIdsArePercentEncodedOnceOnTheWire() async {
        XCTAssertEqual(SDKEndpoints.deviceIdentify(deviceId: "a/b?c#d %e"), "/v1/devices/a%2Fb%3Fc%23d%20%25e/identify")
        XCTAssertEqual(SDKEndpoints.deviceIdentify(deviceId: ".."), "/v1/devices/%2E%2E/identify")
        XCTAssertEqual(SDKEndpoints.deviceIdentify(deviceId: "dev_9f-A"), "/v1/devices/dev_9f-A/identify")
        let http = HTTPClient(config: SheepitConfig(apiKey: "k", apiUrl: "https://gw.example.com/_sheepit/"), log: Logger(debug: false))
        let url = await http.endpointURL(SDKEndpoints.deviceIdentify(deviceId: "a/b"))
        XCTAssertEqual(url.absoluteString, "https://gw.example.com/_sheepit/v1/devices/a%2Fb/identify", "encoded once, never twice")
    }

    // MARK: - § 1 (server review): the id shape before the first send, and lowercase mints

    func testAShapeInvalidStoredIdIsReplacedBeforeTheFirstSend() {
        for bad in ["..", ".", "has space", "tab\tinside", "é", ""] {
            let storage = InMemoryStorage()
            storage.set(bad, forKey: StorageKeys.deviceId)
            let context = ContextManager(storage: storage)
            XCTAssertNotEqual(context.deviceId, bad, "\(bad.debugDescription) is never proposed")
            XCTAssertTrue(DeviceManager.isUsableDeviceId(context.deviceId))
            XCTAssertEqual(storage.string(forKey: StorageKeys.deviceId), context.deviceId, "the replacement is persisted")
            XCTAssertTrue(context.replacedUnusableDeviceId)
        }
    }

    func testAUsableLegacyStoredIdIsKeptVerbatim() {
        for legacy in ["legacy:odd", "dev_ABC/9~x"] {
            let storage = InMemoryStorage()
            storage.set(legacy, forKey: StorageKeys.deviceId)
            let context = ContextManager(storage: storage)
            XCTAssertEqual(context.deviceId, legacy, "the server honours legacy rows of any usable shape")
            XCTAssertFalse(context.replacedUnusableDeviceId)
        }
    }

    func testFreshIdsAreMintedLowercaseAndStoredIdsAreKeptVerbatim() {
        let fresh = ContextManager(storage: InMemoryStorage())
        XCTAssertEqual(fresh.deviceId, fresh.deviceId.lowercased(), "minted lowercase, like sdk-js and Kotlin")
        XCTAssertNotNil(UUID(uuidString: fresh.deviceId))

        let storage = InMemoryStorage()
        storage.set("5F1B3C2E-0000-4000-8000-000000000000", forKey: StorageKeys.deviceId)
        XCTAssertEqual(ContextManager(storage: storage).deviceId, "5F1B3C2E-0000-4000-8000-000000000000",
                       "an existing uppercase id is kept byte-for-byte")
    }
}
