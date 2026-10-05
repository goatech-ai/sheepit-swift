// `SheepitConfig(bundle:)` / `init(infoDictionary:)`: the xcconfig → Info.plist path.
//
// Admission is judged with `constructOnlyForTesting`, which runs the real gate but never starts
// the client, so an admitted config makes no network call and installs no crash handler.

import XCTest
@testable import SheepitKit

final class InfoPlistConfigTests: XCTestCase {
    private static let key = "lp_pub_xxx_" + String(repeating: "a", count: 64)

    private func config(url: Any? = nil, key: Any? = InfoPlistConfigTests.key, environment: Any? = nil) -> SheepitConfig {
        var info: [String: Any] = [:]
        if let key { info["SheepitAPIKey"] = key }
        if let url { info["SheepitAPIURL"] = url }
        if let environment { info["SheepitEnvironment"] = environment }
        return SheepitConfig(infoDictionary: info)
    }

    /// The real admission gate's verdict: `nil` = admitted.
    private func rejection(_ config: SheepitConfig) -> String? {
        var cfg = config
        cfg.crashes = CrashConfig(enabled: false)
        let client = SheepitClient.constructOnlyForTesting(config: cfg)
        defer { client.destroy() }
        return client.inertReason
    }

    // MARK: - SheepitAPIURL

    func testBareHostGetsHTTPSPrepended() {
        let cfg = config(url: "sheepit.example.com")
        XCTAssertEqual(cfg.apiUrl, "https://sheepit.example.com")
        XCTAssertNil(rejection(cfg))
    }

    func testBareHostWithPathKeepsThePath() {
        let cfg = config(url: "sheepit.example.com/_sheepit")
        XCTAssertEqual(cfg.apiUrl, "https://sheepit.example.com/_sheepit")
        XCTAssertNil(rejection(cfg))
    }

    func testFullURLIsUsedAsWritten() {
        for url in ["https://sheepit.example.com/_sheepit", "http://localhost:3000"] {
            let cfg = config(url: url)
            XCTAssertEqual(cfg.apiUrl, url)
            XCTAssertNil(rejection(cfg), url)
        }
    }

    func testSurroundingWhitespaceIsTrimmed() {
        let cfg = config(url: "  sheepit.example.com\n", key: " \(Self.key)\n", environment: " staging ")
        XCTAssertEqual(cfg.apiUrl, "https://sheepit.example.com")
        XCTAssertEqual(cfg.environment, "staging")
        XCTAssertNil(rejection(cfg))
    }

    func testURLTruncatedByAnXcconfigCommentIsInertAndNamesTheCause() {
        for url in ["https:", "http:", "https:/", "http:/", "HTTPS:", " https: "] {
            let cfg = config(url: url)
            XCTAssertNotEqual(cfg.apiUrl, SheepitConfig.defaultAPIUrl, url)
            let reason = rejection(cfg) ?? ""
            XCTAssertTrue(reason.contains("comment"), "\(url.debugDescription): \(reason)")
            XCTAssertTrue(reason.contains("bare host"), "\(url.debugDescription): \(reason)")
        }
    }

    func testSchemeWithoutDoubleSlashIsInert() {
        let cfg = config(url: "https:/sheepit.example.com")
        XCTAssertTrue(rejection(cfg)?.contains("bare host") ?? false)
    }

    /// Present-but-empty must not be read as "unset → hosted default": for a self-hosted
    /// install that would send its users' events to the hosted cloud.
    func testEmptyURLIsInertNotTheHostedDefault() {
        for url in ["", "   ", "\n"] {
            let cfg = config(url: url)
            XCTAssertNotEqual(cfg.apiUrl, SheepitConfig.defaultAPIUrl, url.debugDescription)
            let reason = rejection(cfg) ?? ""
            XCTAssertTrue(reason.contains("SheepitAPIURL is empty"), "\(url.debugDescription): \(reason)")
        }
    }

    /// `https://$(SHEEPIT_API_URL)` is a well-formed URL (`$`, `(` and `)` are legal in a host),
    /// so without this check an unexpanded reference is admitted as a live client.
    func testUnexpandedBuildSettingIsInert() {
        for url in ["$(SHEEPIT_API_URL)", "${SHEEPIT_API_URL}"] {
            let cfg = config(url: url)
            XCTAssertNotEqual(cfg.apiUrl, SheepitConfig.defaultAPIUrl, url)
            let reason = rejection(cfg) ?? ""
            XCTAssertTrue(reason.contains("unexpanded"), "\(url): \(reason)")
        }
    }

    func testAbsentURLKeyUsesTheHostedDefault() {
        let cfg = config(url: nil)
        XCTAssertEqual(cfg.apiUrl, SheepitConfig.defaultAPIUrl)
        XCTAssertNil(rejection(cfg))
    }

    func testHostThatDoesNotFormAURLIsInert() {
        let reason = rejection(config(url: "/_sheepit")) ?? ""
        XCTAssertTrue(reason.contains("does not form a usable URL"), reason)
    }

    func testNonStringValueIsInert() {
        let reason = rejection(config(url: 42)) ?? ""
        XCTAssertTrue(reason.contains("must be a String"), reason)
    }

    /// The issue follows the field: a host that sets `apiUrl` itself after reading the bundle
    /// has resolved it.
    func testOverwritingTheFieldClearsItsIssue() {
        var cfg = config(url: "https:")
        cfg.apiUrl = "https://stub.invalid"
        XCTAssertNil(rejection(cfg))
    }

    // MARK: - SheepitAPIKey

    func testAbsentAPIKeyIsInertAndNamesTheKey() {
        let cfg = config(key: nil)
        let reason = rejection(cfg) ?? ""
        XCTAssertTrue(reason.contains("no SheepitAPIKey entry"), reason)
    }

    func testEmptyOrUnexpandedAPIKeyIsInert() {
        XCTAssertTrue(rejection(config(key: ""))?.contains("SheepitAPIKey is empty") ?? false)
        XCTAssertTrue(rejection(config(key: "$(SHEEPIT_API_KEY)"))?.contains("unexpanded") ?? false)
    }

    func testTwoIssuesAreBothReported() {
        let reason = rejection(config(url: "https:", key: nil)) ?? ""
        XCTAssertTrue(reason.contains("SheepitAPIKey"), reason)
        XCTAssertTrue(reason.contains("SheepitAPIURL"), reason)
    }

    // MARK: - SheepitEnvironment

    func testEnvironmentDefaultsToProductionAndIsRead() {
        XCTAssertEqual(config().environment, "production")
        XCTAssertEqual(config(environment: "staging").environment, "staging")
    }

    func testEmptyEnvironmentIsInert() {
        XCTAssertTrue(rejection(config(environment: ""))?.contains("SheepitEnvironment is empty") ?? false)
    }

    // MARK: - Through the public factory

    /// A misconfigured plist never aborts the host: `create(config:)` returns an inert client
    /// that reports the Info.plist message publicly and on the diagnostic bus.
    func testCreateReturnsAnInertClientWithTheMessage() {
        let sink = DiagnosticSink()
        var cfg = config(url: "https:")
        cfg.crashes = CrashConfig(enabled: false)
        cfg.onDiagnostic = { @Sendable event in sink.append(event) }
        let sdk = SheepitClient.create(config: cfg)
        defer { sdk.destroy() }
        XCTAssertFalse(sdk.status().initialized)
        XCTAssertTrue(sdk.status().rejectionReason?.contains("SheepitAPIURL") ?? false)
        XCTAssertTrue(sink.messages.contains { $0.contains("SheepitAPIURL") })
    }

    /// `init(bundle:)` reads the bundle's real Info.plist, not just the dictionary seam.
    func testReadsARealBundle() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("prB-\(UUID().uuidString).bundle")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let plist: [String: Any] = [
            "CFBundleIdentifier": "ai.sheepit.tests.infoplist",
            "SheepitAPIKey": Self.key,
            "SheepitAPIURL": "sheepit.example.com/_sheepit",
            "SheepitEnvironment": "staging",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: dir.appendingPathComponent("Info.plist"))

        let bundle = try XCTUnwrap(Bundle(url: dir))
        let cfg = SheepitConfig(bundle: bundle)
        XCTAssertEqual(cfg.apiKey, Self.key)
        XCTAssertEqual(cfg.apiUrl, "https://sheepit.example.com/_sheepit")
        XCTAssertEqual(cfg.environment, "staging")
        XCTAssertNil(rejection(cfg))
    }

    // MARK: - Near-miss key names

    /// Key names are case-sensitive. A near-miss spelling next to a correct key must not read as
    /// "absent → hosted default": that sent a self-hosted app's events to the hosted API.
    func testNearMissURLKeyIsInertNotTheHostedDefault() {
        for wrong in ["SheepitAPIUrl", "SheepitApiURL", "SheepitApiUrl", "SheepitAPIURL ", "SHEEPIT_API_URL", "sheepit-api-url"] {
            let cfg = SheepitConfig(infoDictionary: ["SheepitAPIKey": Self.key, wrong: "sheepit.example.com"])
            XCTAssertNotEqual(cfg.apiUrl, SheepitConfig.defaultAPIUrl, wrong.debugDescription)
            XCTAssertNil(cfg.activeInfoPlistNotice, wrong.debugDescription)
            let reason = rejection(cfg) ?? ""
            XCTAssertTrue(reason.contains("rename it to exactly SheepitAPIURL"), "\(wrong.debugDescription): \(reason)")
            XCTAssertTrue(reason.contains(wrong.debugDescription), "\(wrong.debugDescription): \(reason)")
        }
    }

    func testNearMissAPIKeyNameIsInert() {
        let key = rejection(SheepitConfig(infoDictionary: ["SheepitApiKey": Self.key])) ?? ""
        XCTAssertTrue(key.contains("rename it to exactly SheepitAPIKey"), key)
        XCTAssertFalse(key.contains(Self.key), "the key value must never be echoed")
    }

    /// An environment label sends no data anywhere it should not go, so a spelling variant only
    /// warns and keeps "production" — it must not brick an app that worked before.
    func testNearMissEnvironmentNameWarnsAndKeepsProduction() {
        let cfg = SheepitConfig(infoDictionary: ["SheepitAPIKey": Self.key, "SHEEPIT_ENVIRONMENT": "staging"])
        XCTAssertEqual(cfg.environment, "production")
        XCTAssertNil(rejection(cfg))
        XCTAssertTrue(cfg.activeInfoPlistWarnings.contains { $0.contains("rename it to exactly SheepitEnvironment") })
        var overridden = cfg
        overridden.environment = "staging"
        XCTAssertTrue(overridden.activeInfoPlistWarnings.isEmpty)
    }

    /// Only case/whitespace/punctuation variants are near-misses; other names are not guessed at.
    /// `SheepitURL` reads as absent, which the hosted-default notice then makes visible.
    func testOtherSpellingsAreNotNearMisses() {
        let cfg = SheepitConfig(infoDictionary: ["SheepitAPIKey": Self.key, "SheepitURL": "x.example.com", "SheepitEnv": "staging"])
        XCTAssertEqual(cfg.apiUrl, SheepitConfig.defaultAPIUrl)
        XCTAssertNotNil(cfg.activeInfoPlistNotice)
        XCTAssertEqual(cfg.environment, "production")
        XCTAssertTrue(cfg.activeInfoPlistWarnings.isEmpty)
        XCTAssertNil(rejection(cfg))
    }

    func testStartedClientEmitsTheEnvironmentWarning() {
        let sink = DiagnosticSink()
        var cfg = SheepitConfig(infoDictionary: [
            "SheepitAPIKey": Self.key, "SheepitAPIURL": "stub.invalid", "SheepitEnvironment ": "staging",
        ])
        cfg.crashes = CrashConfig(enabled: false)
        cfg.onDiagnostic = { @Sendable event in sink.append(event) }
        let client = SheepitClient.createForTesting(
            config: cfg, now: { Date() }, urlProtocolClasses: [OfflineURLProtocol.self]
        )
        defer { client.destroy() }
        XCTAssertTrue(client.status().initialized)
        XCTAssertTrue(sink.codes.contains(InfoPlistReader.warningCode), "\(sink.codes)")
    }

    func testExactKeyWinsOverANearMissAndUnrelatedKeysAreIgnored() {
        let cfg = SheepitConfig(infoDictionary: [
            "SheepitAPIKey": Self.key,
            "SheepitAPIURL": "sheepit.example.com",
            "SheepitAPIUrl": "other.example.com",
            "SheepitAnalyticsEnabled": "YES",
        ])
        XCTAssertEqual(cfg.apiUrl, "https://sheepit.example.com")
        XCTAssertNil(rejection(cfg))
    }

    // MARK: - Hosted-default notice

    func testAbsentURLKeyCarriesANoticeNamingTheHost() {
        let notice = config(url: nil).activeInfoPlistNotice ?? ""
        XCTAssertTrue(notice.contains("api.sheepit.ai"), notice)
        var overridden = config(url: nil)
        overridden.apiUrl = "https://stub.invalid"
        XCTAssertNil(overridden.activeInfoPlistNotice)
        XCTAssertNil(config(url: "sheepit.example.com").activeInfoPlistNotice)
        XCTAssertNil(SheepitConfig(apiKey: Self.key).activeInfoPlistNotice)
    }

    /// A started client reports the hosted default on the diagnostic bus (and logs it publicly
    /// alongside). The network is stubbed so nothing reaches the real host.
    func testStartedClientEmitsTheHostedDefaultNotice() {
        let sink = DiagnosticSink()
        var cfg = config(url: nil)
        cfg.crashes = CrashConfig(enabled: false)
        cfg.onDiagnostic = { @Sendable event in sink.append(event) }
        let client = SheepitClient.createForTesting(
            config: cfg, now: { Date() }, urlProtocolClasses: [OfflineURLProtocol.self]
        )
        defer { client.destroy() }
        XCTAssertTrue(sink.codes.contains(InfoPlistReader.hostedDefaultCode), "\(sink.codes)")
        XCTAssertTrue(sink.messages.contains { $0.contains("api.sheepit.ai") })
    }

    // MARK: - Console visibility

    /// `log.error` is `%{private}@`; the Info.plist reason is repeated publicly, and it must not
    /// carry the key value.
    func testInfoPlistReasonIsRepeatedForTheConsoleWithoutTheKeyValue() {
        let cfg = config(url: "https:", key: "lp_pub_xxx_$(SECRET_PART)")
        let reason = rejection(cfg) ?? ""
        let line = cfg.infoPlistConsoleWarning(forInertReason: reason)
        XCTAssertEqual(line, reason)
        XCTAssertFalse(reason.contains("lp_pub_xxx"), reason)
        XCTAssertNil(SheepitConfig(apiKey: "bad").infoPlistConsoleWarning(forInertReason: "Invalid API key format."))
    }

    /// No public text — `status().rejectionReason`, the diagnostic, the console line — may echo
    /// a configured URL: it can carry gateway credentials in forms `redactingUserinfo` misses.
    func testNoPublicTextEchoesAUserinfoBearingURL() {
        for url in [
            "https:/admin:s3cret@gw.internal.corp",
            "http:/admin:s3cret@gw.internal.corp/_sheepit",
            "admin:s3cret@/_sheepit",
            "https://admin:s3cret@",
        ] {
            let sink = DiagnosticSink()
            var cfg = config(url: url)
            cfg.crashes = CrashConfig(enabled: false)
            cfg.onDiagnostic = { @Sendable event in sink.append(event) }
            let sdk = SheepitClient.create(config: cfg)
            defer { sdk.destroy() }
            let reason = sdk.status().rejectionReason ?? ""
            XCTAssertFalse(reason.isEmpty, url)
            let texts = [reason, cfg.infoPlistConsoleWarning(forInertReason: reason) ?? ""] + sink.messages
            for text in texts {
                for part in ["admin", "s3cret", "gw.internal"] {
                    XCTAssertFalse(text.contains(part), "\(url) leaked \(part): \(text)")
                }
            }
        }
    }

    // MARK: - Quotes

    func testSurroundingQuotesAreStripped() {
        XCTAssertEqual(config(url: "\"sheepit.example.com\"").apiUrl, "https://sheepit.example.com")
        XCTAssertEqual(config(url: "'sheepit.example.com'").apiUrl, "https://sheepit.example.com")
        let reason = rejection(config(url: "\"https:")) ?? ""
        XCTAssertTrue(reason.contains("comment"), reason)
    }

    final class DiagnosticSink: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [DiagnosticEvent] = []

        func append(_ event: DiagnosticEvent) {
            lock.lock(); defer { lock.unlock() }
            events.append(event)
        }

        var messages: [String] {
            lock.lock(); defer { lock.unlock() }
            return events.map(\.message)
        }

        var codes: [String] {
            lock.lock(); defer { lock.unlock() }
            return events.map(\.code)
        }
    }
}

/// Fails every request without touching the network.
final class OfflineURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
