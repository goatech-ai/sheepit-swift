import XCTest
@testable import SheepitKit

/// 🔴 A device whose registration body the API rejects never registers, and an unregistered device
/// is dead weight: `/v1/config` resolves no row for it and identify has nothing to bind. Two
/// fields of `deviceRegisterSchema` (`packages/shared/src/schemas/platform.ts`) were rejected
/// for ordinary users:
///
///   - `locale` is `max(16)`, and the SDK sent `Locale.current.identifier`, which carries
///     `@key=value` keywords once the user picks a non-default calendar, numbering system or
///     collation: `"en_US@calendar=japanese"` is 23 characters.
///   - `country` is `length(2)`, and the SDK sent `Locale.region`, which is a UN M.49 area on
///     es-419 devices (`"419"`) and on `en_001`.
///
/// And a 400 used to count as a transient failure (`SDKError.badRequest` is not
/// `.httpError(400)`), so the same doomed request was re-sent on every launch.
final class DeviceRegistrationPayloadTests: XCTestCase {
    private let suiteName = "ai.goatech.sdk"

    /// `deviceRegisterSchema`'s bounds, in UTF-16 code units (zod counts `String.length`).
    private let schemaMax: [String: Int] = [
        "device_id": 256, "anonymous_id": 256, "device_model": 256, "os_name": 128,
        "os_version": 64, "app_version": 64, "build_number": 64, "locale": 16, "timezone": 64,
    ]

    /// Identifiers `Locale.current.identifier` really produces. Each of the first six exceeds 16.
    private let identifiers: [(identifier: String, locale: String, country: String?)] = [
        ("en_US@calendar=japanese", "en-US", "US"),
        ("ja_JP@calendar=japanese", "ja-JP", "JP"),
        ("es_419@numbers=latn", "es-419", nil),
        ("de_DE@collation=phonebook", "de-DE", "DE"),
        ("ar_SA@numbers=latn;calendar=gregorian", "ar-SA", "SA"),
        ("zh_Hans_CN@calendar=chinese", "zh-CN", "CN"),
        ("es_419", "es-419", nil),
        ("en_001", "en-001", nil),
        ("en_US_POSIX", "en-US", "US"),
        ("sr_Latn_RS", "sr-Latn-RS", "RS"),
        ("ca_ES_VALENCIA", "ca-ES-valencia", "ES"),
        ("en_US", "en-US", "US"),
    ]

    private func encoded(_ request: DeviceRegisterRequest) throws -> [String: Any] {
        let data = try JSONEncoder().encode(request)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: - Payload

    func testEveryRegistrationFieldFitsTheSchemaForEveryRealLocale() throws {
        for sample in identifiers {
            let body = try encoded(DeviceManager.registrationRequest(
                anonymousId: "anon-1",
                existingDeviceId: nil,
                locale: Locale(identifier: sample.identifier)
            ))
            for (field, max) in schemaMax {
                guard let value = body[field] as? String else { continue }
                XCTAssertLessThanOrEqual(
                    value.utf16.count, max,
                    "\(sample.identifier): `\(field)` = \"\(value)\" exceeds the schema's max(\(max))")
            }
            if let country = body["country"] as? String {
                XCTAssertEqual(country.utf16.count, 2, "\(sample.identifier): country must be length(2)")
            }
        }
    }

    func testLocaleIsTheBCP47TagWithoutExtensionsAndCountryIsAlpha2Only() throws {
        for sample in identifiers {
            let body = try encoded(DeviceManager.registrationRequest(
                anonymousId: "anon-1",
                existingDeviceId: nil,
                locale: Locale(identifier: sample.identifier)
            ))
            XCTAssertEqual(body["locale"] as? String, sample.locale, sample.identifier)
            XCTAssertEqual(body["country"] as? String, sample.country, sample.identifier)
        }
    }

    func testAnOverlongTagIsCutOnASubtagBoundary() {
        XCTAssertEqual(DeviceProfile.clampLanguageTag("zh-Hant-TW-variant1-variant2", 16), "zh-Hant-TW")
        XCTAssertEqual(DeviceProfile.clampLanguageTag("en-US-u-ca-japanese", 16), "en-US")
        XCTAssertEqual(DeviceProfile.clampLanguageTag("en-US-x-private", 16), "en-US")
        XCTAssertEqual(DeviceProfile.clampLanguageTag("en-US", 16), "en-US")
        XCTAssertNil(DeviceProfile.clampLanguageTag("", 16))
        XCTAssertNil(DeviceProfile.clampLanguageTag("abcdefghijklmnopqrstuvwxyz", 16))
    }

    // MARK: - 400 is terminal at launch

    private func clearDeviceStorage() {
        guard let defaults = UserDefaults(suiteName: suiteName) else { return }
        for key in [StorageKeys.deviceId, StorageKeys.deviceRegistered,
                    StorageKeys.deviceRegistrationBackoffUntil,
                    StorageKeys.deviceRegistrationBackoffSDKVersion, StorageKeys.sessionId,
                    StorageKeys.sessionLastSeen, StorageKeys.identity] {
            defaults.removeObject(forKey: key)
        }
    }

    override func setUp() {
        super.setUp()
        clearDeviceStorage()
        RegistrationStubURLProtocol.reset()
    }

    override func tearDown() {
        clearDeviceStorage()
        RegistrationStubURLProtocol.reset()
        super.tearDown()
    }

    private func makeConfig() -> SheepitConfig {
        SheepitConfig(
            apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))",
            apiUrl: "https://stub.invalid",
            configRefreshInterval: 300,
            retryAttempts: 1,
            crashes: CrashConfig(enabled: false)
        )
    }

    private func waitUntil(timeout: TimeInterval = 3.0, _ condition: @escaping () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    private static let configBody = #"{"data":{"config_version":"1","etag":"e1","flags":{},"experiments":{}}}"#
    /// The route's real 400 body (`apps/api/src/routes/v1/devices.ts`: `error.flatten()`).
    static let validationErrorBody = """
    {"error":{"code":"VALIDATION_ERROR","message":"Invalid request body.",\
    "details":{"formErrors":[],"fieldErrors":{"locale":["String must contain at most 16 character(s)"],\
    "country":["String must contain exactly 2 character(s)"]}}}}
    """

    func testA400BacksOffLikeARevokedKeyAndNamesTheRejectedFieldsButNoValues() async {
        RegistrationStubURLProtocol.setResponder { method, path in
            if method == "POST", path == SDKEndpoints.deviceRegister {
                return .status(400, body: Self.validationErrorBody)
            }
            return .status(200, body: Self.configBody)
        }
        let fixedNow = Date(timeIntervalSince1970: 1_700_000_000)
        let client = SheepitClient.createForTesting(
            config: makeConfig(),
            now: { fixedNow },
            urlProtocolClasses: [RegistrationStubURLProtocol.self]
        )
        defer { client.destroy() }

        await waitUntil {
            client.getRecentDiagnostics().contains { $0.code == "identity.device_registration_terminal_failure" }
        }

        let raw = UserDefaults(suiteName: suiteName)?.string(forKey: StorageKeys.deviceRegistrationBackoffUntil)
        XCTAssertNotNil(raw, "a 400 re-sends the same body forever: it must back off, not retry every launch")
        XCTAssertNil(UserDefaults(suiteName: suiteName)?.string(forKey: StorageKeys.deviceRegistered))

        let diagnostic = client.getRecentDiagnostics().first {
            $0.code == "identity.device_registration_terminal_failure"
        }
        XCTAssertEqual(diagnostic?.data?["outcome"]?.value as? String, "invalid_request")
        XCTAssertEqual(diagnostic?.data?["status_code"]?.value as? Int, 400)
        XCTAssertEqual(diagnostic?.data?["reason"]?.value as? String, "VALIDATION_ERROR")
        XCTAssertEqual(diagnostic?.data?["rejected_fields"]?.value as? [String], ["country", "locale"])
        let rendered = "\(diagnostic?.message ?? "") \(String(describing: diagnostic?.data))"
        XCTAssertFalse(rendered.contains("at most 16"), "the server's messages are not forwarded")
    }

    // MARK: - Crash context follows the launch adoption

    func testLaunchRegistrationAdoptionRefreshesTheCrashContext() async {
        RegistrationStubURLProtocol.setResponder { method, path in
            if method == "POST", path == SDKEndpoints.deviceRegister {
                // Held long enough for the hook below to be installed first.
                return .delayed(
                    seconds: 0.3,
                    then: .status(201, body: """
                    {"data":{"device_id":"dev_adopted","anonymous_id":"anon-1", \
                    "flag_assignments":{},"experiment_assignments":{}, \
                    "config":{"flush_interval_ms":1000,"flush_size":20}}}
                    """)
                )
            }
            return .status(200, body: Self.configBody)
        }
        let seen = LockedBox<[String]>([])
        let client = SheepitClient.createForTesting(
            config: makeConfig(),
            now: { Date() },
            urlProtocolClasses: [RegistrationStubURLProtocol.self]
        )
        client.deviceIdChangeHookForTesting.value = { id in seen.mutate { $0.append(id) } }
        defer { client.destroy() }

        await waitUntil { client.status().deviceId == "dev_adopted" && !seen.get().isEmpty }

        XCTAssertEqual(
            seen.get(), ["dev_adopted"],
            "the crash context must be refreshed when launch registration adopts the server's id")
    }
    // MARK: - Which 400s are terminal, and how long the backoff holds

    private func startWithRegisterReply(_ stub: RegistrationStubURLProtocol.Stub, now: Date = Date()) -> SheepitClient {
        RegistrationStubURLProtocol.setResponder { method, path in
            if method == "POST", path == SDKEndpoints.deviceRegister { return stub }
            return .status(200, body: Self.configBody)
        }
        return SheepitClient.createForTesting(
            config: makeConfig(),
            now: { now },
            urlProtocolClasses: [RegistrationStubURLProtocol.self]
        )
    }

    private var registerCount: Int {
        RegistrationStubURLProtocol.requests(method: "POST", path: SDKEndpoints.deviceRegister).count
    }

    private static let registered = """
    {"data":{"device_id":"dev_ok","anonymous_id":"anon-1","flag_assignments":{},\
    "experiment_assignments":{},"config":{"flush_interval_ms":1000,"flush_size":20}}}
    """

    /// A proxy or load balancer page is not the API rejecting the body: retry next launch.
    func testA400WithoutTheAPIsValidationEnvelopeIsTransient() async {
        let client = startWithRegisterReply(.status(400, body: "<html><body>Bad Request</body></html>"))
        defer { client.destroy() }
        await waitUntil { self.registerCount >= 1 }
        try? await Task.sleep(for: .milliseconds(100))

        XCTAssertNil(
            UserDefaults(suiteName: suiteName)?.string(forKey: StorageKeys.deviceRegistrationBackoffUntil),
            "only a VALIDATION_ERROR from the API is terminal")
        XCTAssertFalse(client.getRecentDiagnostics().contains {
            $0.code == "identity.device_registration_terminal_failure"
        })
    }

    /// A new build may carry the fix for whatever was rejected, so it retries at once.
    func testABackoffWrittenByAnotherSDKVersionIsIgnored() async {
        let now = Date()
        let defaults = UserDefaults(suiteName: suiteName)
        defaults?.set(String(now.timeIntervalSince1970 + 3600), forKey: StorageKeys.deviceRegistrationBackoffUntil)
        defaults?.set("0.0.1", forKey: StorageKeys.deviceRegistrationBackoffSDKVersion)
        let client = startWithRegisterReply(.status(201, body: Self.registered), now: now)
        defer { client.destroy() }
        await waitUntil { self.registerCount >= 1 }
        XCTAssertEqual(registerCount, 1)
    }

    /// A backoff-until further out than the backoff itself can only come from a clock that moved.
    func testABackoffFurtherOutThanItsOwnLengthIsIgnored() async {
        let now = Date()
        let defaults = UserDefaults(suiteName: suiteName)
        defaults?.set(
            String(now.timeIntervalSince1970 + 2 * SDKDefaults.deviceRegistrationTerminalBackoff),
            forKey: StorageKeys.deviceRegistrationBackoffUntil)
        defaults?.set(SDKDefaults.sdkVersion, forKey: StorageKeys.deviceRegistrationBackoffSDKVersion)
        let client = startWithRegisterReply(.status(201, body: Self.registered), now: now)
        defer { client.destroy() }
        await waitUntil { self.registerCount >= 1 }
        XCTAssertEqual(registerCount, 1)
    }

    func testASuccessfulRegistrationClearsTheBackoff() async {
        let now = Date()
        let defaults = UserDefaults(suiteName: suiteName)
        defaults?.set(String(now.timeIntervalSince1970 - 1), forKey: StorageKeys.deviceRegistrationBackoffUntil)
        defaults?.set(SDKDefaults.sdkVersion, forKey: StorageKeys.deviceRegistrationBackoffSDKVersion)
        let client = startWithRegisterReply(.status(201, body: Self.registered), now: now)
        defer { client.destroy() }
        await waitUntil { client.status().deviceId == "dev_ok" }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(defaults?.string(forKey: StorageKeys.deviceRegistrationBackoffUntil))
        XCTAssertNil(defaults?.string(forKey: StorageKeys.deviceRegistrationBackoffSDKVersion))
    }
}
