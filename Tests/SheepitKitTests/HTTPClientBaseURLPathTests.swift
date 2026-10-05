import XCTest
@testable import SheepitKit

/// `apiUrl` may carry a path — a same-origin proxy such as `https://app.example.com/_sheepit`
/// in front of the API. `HTTPClient` joins it to each endpoint with `appendingPathComponent`,
/// which must keep the base path and must not produce `//v1/...` from a trailing slash.
final class HTTPClientBaseURLPathTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func requestedURL(apiUrl: String, path: String = SDKEndpoints.ingest) async throws -> String {
        StubURLProtocol.stub = .status(202, body: "{}")
        let http = HTTPClient(
            config: SheepitConfig(
                apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))",
                apiUrl: apiUrl,
                retryAttempts: 1
            ),
            log: Logger(debug: false),
            urlProtocolClasses: [StubURLProtocol.self]
        )
        _ = try await http.postRaw(path: path, body: ["k": "v"])
        return try XCTUnwrap(StubURLProtocol.lastRequestURL?.absoluteString)
    }

    func testABasePathIsKept() async throws {
        let url = try await requestedURL(apiUrl: "https://stub.invalid/_sheepit")
        XCTAssertEqual(url, "https://stub.invalid/_sheepit/v1/ingest")
    }

    func testATrailingSlashOnTheBasePathDoesNotDoubleTheSlash() async throws {
        let url = try await requestedURL(apiUrl: "https://stub.invalid/_sheepit/")
        XCTAssertEqual(url, "https://stub.invalid/_sheepit/v1/ingest")
    }

    func testSeveralTrailingSlashesAreStripped() async throws {
        let url = try await requestedURL(apiUrl: "https://stub.invalid/_sheepit//")
        XCTAssertEqual(url, "https://stub.invalid/_sheepit/v1/ingest")
    }

    func testABareHostWithATrailingSlash() async throws {
        let url = try await requestedURL(apiUrl: "https://stub.invalid/")
        XCTAssertEqual(url, "https://stub.invalid/v1/ingest")
    }

    func testTheCrashEndpointUnderABasePath() async throws {
        let url = try await requestedURL(apiUrl: "https://stub.invalid/_sheepit/", path: SDKEndpoints.crashReport)
        XCTAssertEqual(url, "https://stub.invalid/_sheepit/v1/crashes/report")
    }

    func testNormalizationTrimsWhitespaceThenTrailingSlashes() {
        XCTAssertEqual(HTTPClient.normalizedBaseURLString(" https://h/_sheepit/ \n"), "https://h/_sheepit")
        XCTAssertEqual(HTTPClient.normalizedBaseURLString("https://h"), "https://h")
        XCTAssertEqual(HTTPClient.normalizedBaseURLString("https://h///"), "https://h")
    }
}
