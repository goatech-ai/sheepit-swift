import XCTest
@testable import SheepitKit

/// `RequestTelemetryPolicy` on its own: the allowlist matcher, the SDK-own-API exclusion and the
/// recorded URL form. Pure — no client, no storage, no network.
final class RequestTelemetryPolicyTests: XCTestCase {
    private func target(_ string: String, hosts: [String], apiUrl: String = "https://api.sheepit.ai") -> RequestTelemetryPolicy.Target? {
        RequestTelemetryPolicy(hosts: hosts, apiUrl: apiUrl).target(for: URL(string: string)!)
    }

    func testAnExactHostMatchesCaseInsensitivelyAndNothingElse() {
        let hosts = ["API.Example.com"]
        XCTAssertNotNil(target("https://api.example.com/x", hosts: hosts))
        XCTAssertNotNil(target("https://API.EXAMPLE.COM/x", hosts: hosts))
        XCTAssertNotNil(target("https://api.example.com./x", hosts: hosts), "a trailing dot is the same host")
        XCTAssertNil(target("https://v2.api.example.com/x", hosts: hosts), "an exact entry does not cover subdomains")
        XCTAssertNil(target("https://example.com/x", hosts: hosts))
        XCTAssertNil(target("https://api.example.com.evil.net/x", hosts: hosts))
        XCTAssertNil(target("https://notapi.example.com/x", hosts: hosts))
    }

    func testAWildcardMatchesEverySubdomainButNotTheApex() {
        let hosts = ["*.example.com"]
        XCTAssertNotNil(target("https://api.example.com/x", hosts: hosts))
        XCTAssertNotNil(target("https://a.b.example.com/x", hosts: hosts))
        XCTAssertNil(target("https://example.com/x", hosts: hosts), "list the apex separately")
        XCTAssertNil(target("https://badexample.com/x", hosts: hosts))
        XCTAssertNil(target("https://example.com.evil.net/x", hosts: hosts))
    }

    func testUnusableEntriesAreIgnoredAndCounted() {
        let policy = RequestTelemetryPolicy(
            hosts: ["https://a.com", "a.com:443", "a.com/v1", "user@a.com", "*", "*.", "a*.com", "  ", "*.com", "ok.com", " spaced.com "],
            apiUrl: "https://api.sheepit.ai"
        )
        XCTAssertEqual(policy.ignoredEntries, 9)
        XCTAssertNotNil(policy.target(for: URL(string: "https://ok.com/")!))
        XCTAssertNotNil(policy.target(for: URL(string: "https://spaced.com/")!), "surrounding whitespace is trimmed")
        XCTAssertNil(policy.target(for: URL(string: "https://a.com/")!))
    }

    /// `URLComponents` percent-decodes an entry, so a `/` or NUL can hide behind `%2F` / `%00`
    /// until canonicalization; and a leading dot, an empty label or a backslash can never match a
    /// request host. Each must be refused and counted, not silently kept.
    func testEntriesThatCanNeverMatchAreRefusedAfterCanonicalization() {
        let vectors = [
            "example.com%2Fevil", "exa%2Fmple.com", "exa%00mple.com", "example.com%00",
            ".example.com", "example..com", "a\\b.com", "exa\u{7}mple.com", "*..example.com", "*.%2Fcom.example",
        ]
        for vector in vectors {
            let policy = RequestTelemetryPolicy(hosts: [vector], apiUrl: "https://api.sheepit.ai")
            XCTAssertEqual(policy.ignoredEntries, 1, vector)
            XCTAssertTrue(policy.isEmpty, vector)
        }
        let kept = RequestTelemetryPolicy(hosts: ["b%C3%BCcher.example"], apiUrl: "https://api.sheepit.ai")
        XCTAssertEqual(kept.ignoredEntries, 0, "a percent-encoded name that decodes to a valid host is kept")
        XCTAssertNotNil(kept.target(for: URL(string: "https://xn--bcher-kva.example/")!))
    }

    /// No public-suffix list ships: a single-label wildcard is refused, a multi-label public suffix
    /// is not (documented).
    func testASingleLabelWildcardIsRefused() {
        let policy = RequestTelemetryPolicy(hosts: ["*.com", "*.localhost", "*.co.uk"], apiUrl: "https://api.sheepit.ai")
        XCTAssertEqual(policy.ignoredEntries, 2)
        XCTAssertNil(policy.target(for: URL(string: "http://api.localhost/")!), "local dev: list the exact host")
        XCTAssertNil(policy.target(for: URL(string: "https://anything.com/")!))
        XCTAssertNotNil(policy.target(for: URL(string: "https://anything.co.uk/")!), "no PSL: documented residual")
    }

    /// Measured on macOS 27: `URLComponents.host` decodes an IDN's punycode, and entries are
    /// canonicalized through the same API, so either spelling of the entry matches either
    /// spelling of the URL. The recorded host is the decoded form.
    func testAnIDNHostMatchesInEitherSpelling() throws {
        for entry in ["xn--bcher-kva.example", "bücher.example", "*.xn--bcher-kva.example"] {
            let host = entry.hasPrefix("*.") ? "api." : ""
            let hit = try XCTUnwrap(target("https://\(host)xn--bcher-kva.example/p", hosts: [entry]), entry)
            XCTAssertEqual(hit.host, "\(host)bücher.example", entry)
        }
    }

    func testTheAPIHostIsFlaggedOnlyWhenAPIURLHasNoPathAndTheHostIsAllowlisted() {
        XCTAssertEqual(RequestTelemetryPolicy(hosts: ["app.example.com"], apiUrl: "https://app.example.com").apiHostExcluded, "app.example.com")
        XCTAssertEqual(RequestTelemetryPolicy(hosts: ["*.example.com"], apiUrl: "https://app.example.com/").apiHostExcluded, "app.example.com")
        XCTAssertNil(RequestTelemetryPolicy(hosts: ["app.example.com"], apiUrl: "https://app.example.com/_sheepit").apiHostExcluded)
        XCTAssertNil(RequestTelemetryPolicy(hosts: ["api.example.com"], apiUrl: "https://app.example.com").apiHostExcluded)
    }

    func testAnIPv6EntryMatchesAndIsBracketedInTheURL() throws {
        let hit = try XCTUnwrap(target("http://[::1]:8080/p?q=1", hosts: ["[::1]"]))
        XCTAssertEqual(hit, .init(url: "http://[::1]:8080/p", host: "::1", path: "/p"))
        XCTAssertNotNil(target("http://[::1]/p", hosts: ["::1"]))
    }

    func testARelativeURLIsNeverRecorded() {
        XCTAssertNil(target("/v1/items", hosts: ["api.example.com"]))
    }

    func testTheSDKsOwnAPIIsExcludedByHostAndPathPrefixIgnoringSchemeAndPort() {
        let hosts = ["api.sheepit.ai", "app.example.com"]
        XCTAssertNil(target("https://api.sheepit.ai/v1/ingest", hosts: hosts))
        XCTAssertNil(target("http://API.sheepit.ai:8080/anything", hosts: hosts))

        let proxied = "https://app.example.com/_sheepit"
        XCTAssertNil(target("https://app.example.com/_sheepit", hosts: hosts, apiUrl: proxied))
        XCTAssertNil(target("https://app.example.com/_sheepit/v1/config", hosts: hosts, apiUrl: proxied))
        XCTAssertNotNil(target("https://app.example.com/_sheepit2/v1", hosts: hosts, apiUrl: proxied))
        XCTAssertNotNil(target("https://app.example.com/api/orders", hosts: hosts, apiUrl: proxied))
        XCTAssertNotNil(target("https://api.sheepit.ai/v1/ingest", hosts: hosts, apiUrl: proxied),
                        "only the CONFIGURED apiUrl is the SDK's own")
    }

    func testAnEmptyAllowlistIsEmpty() {
        XCTAssertTrue(RequestTelemetryPolicy(hosts: [], apiUrl: "https://api.sheepit.ai").isEmpty)
        XCTAssertTrue(RequestTelemetryPolicy(hosts: ["https://bad"], apiUrl: "https://api.sheepit.ai").isEmpty)
    }
}
