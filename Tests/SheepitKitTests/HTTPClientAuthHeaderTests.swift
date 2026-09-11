import XCTest
@testable import SheepitKit

/// Regression coverage for the 2026-09 security follow-up to #972, finding E-004: a key
/// admitted with a trailing newline/space (common when copied from a terminal, `.env` file,
/// or plist) must not reach the wire untrimmed. Foundation's `URLRequest` silently drops the
/// entire `Authorization` header rather than sending one with an embedded control character
/// — so an untrimmed key does not fail loudly, it makes every request go out unauthenticated.
final class HTTPClientAuthHeaderTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func makeConfig(apiKey: String) -> SheepitConfig {
        SheepitConfig(apiKey: apiKey, apiUrl: "https://stub.invalid", retryAttempts: 1)
    }

    func testAuthorizationHeaderIsSentForAKeyWithATrailingNewline() async throws {
        let dirtyKey = "lp_pub_xxx_\(String(repeating: "a", count: 64))\n"
        let http = HTTPClient(
            config: makeConfig(apiKey: dirtyKey),
            log: Logger(debug: false),
            urlProtocolClasses: [StubURLProtocol.self]
        )

        _ = try? await http.postRaw(path: "/v1/ping", body: Optional<Int>.none)

        let header = StubURLProtocol.lastRequestHeaders?["Authorization"]
        XCTAssertNotNil(
            header,
            "An untrimmed key must not make Foundation silently drop the Authorization header."
        )
        XCTAssertEqual(header, "Bearer lp_pub_xxx_\(String(repeating: "a", count: 64))")
        XCTAssertFalse(header?.contains("\n") == true)
    }

    func testAuthorizationHeaderTrimsCRLFAndTrailingSpace() async throws {
        for dirty in ["lp_pub_xxx_\(String(repeating: "a", count: 64))\r\n",
                      "lp_pub_xxx_\(String(repeating: "a", count: 64)) "] {
            StubURLProtocol.reset()
            let http = HTTPClient(
                config: makeConfig(apiKey: dirty),
                log: Logger(debug: false),
                urlProtocolClasses: [StubURLProtocol.self]
            )
            _ = try? await http.postRaw(path: "/v1/ping", body: Optional<Int>.none)
            XCTAssertEqual(
                StubURLProtocol.lastRequestHeaders?["Authorization"],
                "Bearer lp_pub_xxx_\(String(repeating: "a", count: 64))",
                "\(dirty.debugDescription) must be trimmed before it reaches the wire"
            )
        }
    }

    /// Regression coverage for finding E-003: `HTTPClient.init` used to
    /// `URL(string: config.apiUrl)!`, a force-unwrap on config/attacker-controlled input
    /// that traps the host process in a release build. `SheepitClient.create()` already
    /// catches a malformed apiUrl before `HTTPClient` is ever constructed on the live path
    /// (see `SecretKeyGuardTests`), but this proves `HTTPClient` doesn't ALSO need that
    /// upstream gate to stay safe — defense in depth for a caller that constructs it
    /// directly, bypassing `SheepitClient.create()` entirely.
    /// Regression coverage for the 2026-09 security follow-up round 3, finding MF-4:
    /// `SheepitClient.create`'s admission gate judges the TRIMMED `apiUrl`, so a value with
    /// surrounding whitespace was ADMITTED (`status().initialized == true`) — but
    /// `HTTPClient.init` built `baseURL` from the UNTRIMMED string, and `URL(string:)` fails
    /// to parse ANY of these forms (verified: leading space, trailing newline, trailing
    /// space, leading tab all parse to `nil`), silently falling back to
    /// `unreachableFallbackURL`. Every request from an "initialized" client went to a domain
    /// that doesn't exist. Gate and transport must resolve to the SAME host.
    func testASurroundingWhitespaceApiUrlResolvesToTheSameHostAsItsTrimmedForm() async {
        for dirtyUrl in [
            " https://stub.invalid",
            "https://stub.invalid\n",
            "https://stub.invalid ",
            "\thttps://stub.invalid",
        ] {
            let http = HTTPClient(
                config: makeConfig(apiKey: "lp_pub_xxx_\(String(repeating: "a", count: 64))")
                    .withApiUrl(dirtyUrl),
                log: Logger(debug: false)
            )
            let resolvedHost = await http.baseURLForTesting.host
            XCTAssertEqual(
                resolvedHost, "stub.invalid",
                "\(dirtyUrl.debugDescription) must resolve to the trimmed form's host, not " +
                "silently fall back to the unreachable placeholder."
            )
        }
    }

    func testConstructionWithAMalformedApiUrlDoesNotCrash() {
        for badUrl in ["", "not-a-url", "   "] {
            _ = HTTPClient(
                config: makeConfig(apiKey: "lp_pub_xxx_\(String(repeating: "a", count: 64))")
                    .withApiUrl(badUrl),
                log: Logger(debug: false),
                urlProtocolClasses: [StubURLProtocol.self]
            )
            // Reaching this line at all is the assertion — the old force-unwrap trapped
            // the process before returning from `init`, so a crash here fails the whole
            // test binary rather than this one test method.
        }
        XCTAssertTrue(true, "HTTPClient must construct without trapping on a malformed apiUrl.")
    }
}

private extension SheepitConfig {
    func withApiUrl(_ url: String) -> SheepitConfig {
        var copy = self
        copy.apiUrl = url
        return copy
    }
}
