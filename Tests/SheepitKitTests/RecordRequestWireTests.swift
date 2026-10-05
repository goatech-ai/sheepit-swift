import XCTest
@testable import SheepitKit

/// `recordRequest` through a STARTED client: what the encoded ingest body carries, that the SDK's
/// own failing ingest is never fed back as `$http_error` even when its host is allowlisted, and
/// the burst limiter aged on its injected monotonic clock. The network is
/// `AttributionCaptureProtocol` / `StubURLProtocol`, never the real one.
final class RecordRequestWireTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SharedSDKStorage.clear()
        AttributionCaptureProtocol.reset()
        StubURLProtocol.reset()
        TeardownFlushes.install()
    }

    /// Awaits every destroyed client's fire-and-forget final flush before the shared stub and
    /// storage are reset, so it cannot land in the next test (`TeardownFlushes`).
    override func tearDown() async throws {
        await TeardownFlushes.drain(context: name)
        SharedSDKStorage.clear()
        AttributionCaptureProtocol.reset()
        StubURLProtocol.reset()
        try await super.tearDown()
    }

    private func makeClient(
        protocolClass: AnyClass,
        hosts: [String] = ["api.example.com"],
        uptime: LockedBox<TimeInterval> = LockedBox(0),
        onEvent: (@Sendable (String, [String: Any]?) -> Void)? = nil
    ) -> SheepitClient {
        SheepitClient.createForTesting(
            config: SheepitConfig(
                apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64),
                apiUrl: "https://stub.invalid",
                flushInterval: 3600,
                flushSize: 1000,
                configRefreshInterval: 3600,
                retryAttempts: 1,
                onEvent: onEvent,
                // Its own failing uploads would emit SDK-internal `$error`s and blur the count.
                performance: PerformanceConfig(enabled: false),
                // 🔴 Real signal handlers in the test process kill whichever test runs next.
                crashes: CrashConfig(enabled: false),
                requestTelemetryHosts: hosts
            ),
            now: { Date() },
            urlProtocolClasses: [protocolClass],
            errorCaptureUptime: { uptime.get() }
        )
    }

    private func url(_ string: String) -> URL { URL(string: string)! }

    func testTheIngestBodyCarriesThePropertiesAndTheSameIdentityAsAPrecedingTrack() async throws {
        let client = makeClient(protocolClass: AttributionCaptureProtocol.self)
        defer { client.destroy() }

        client.track("record_request_wire_probe")
        client.recordRequest(
            method: "delete",
            url: url("https://api.example.com/v1/carts/7?session=xyz#top"),
            status: 409,
            durationMs: 87.4,
            responseBytes: 64
        )
        await client.flush()

        let event = try XCTUnwrap(AttributionCaptureProtocol.event(named: "$http_error"), "$http_error was never sent")
        let probe = try XCTUnwrap(AttributionCaptureProtocol.event(named: "record_request_wire_probe"))
        let props = try XCTUnwrap(event["properties"] as? [String: Any])
        XCTAssertEqual(props as NSDictionary, [
            "url": "https://api.example.com/v1/carts/7",
            "host": "api.example.com",
            "path": "/v1/carts/7",
            "method": "DELETE",
            "status": 409,
            "latency_ms": 87,
            "kind": "http_error",
            "origin": "app",
            "response_bytes": 64,
        ] as NSDictionary)

        let context = try XCTUnwrap(event["context"] as? [String: Any])
        let probeContext = try XCTUnwrap(probe["context"] as? [String: Any])
        let session = (context["session"] as? [String: Any])?["id"] as? String
        let device = (context["device"] as? [String: Any])?["id"] as? String
        XCTAssertNotNil(session)
        XCTAssertNotNil(device)
        XCTAssertEqual(session, (probeContext["session"] as? [String: Any])?["id"] as? String)
        XCTAssertEqual(device, (probeContext["device"] as? [String: Any])?["id"] as? String)
    }

    /// Even with the SDK's own host allowlisted, a host-side interceptor that reports the SDK's
    /// failed ingest back through `recordRequest` produces no event — no feedback loop.
    func testTheSDKsOwnFailingIngestReportedBackProducesNoHTTPError() async throws {
        StubURLProtocol.stub = .status(500, body: #"{"error":{"code":"INTERNAL","message":"stub"}}"#)
        let names = LockedBox<[String]>([])
        let client = makeClient(protocolClass: StubURLProtocol.self, hosts: ["stub.invalid", "api.example.com"]) { name, _ in
            names.mutate { $0.append(name) }
        }
        defer { client.destroy() }

        client.track("something")
        await client.flush()
        let ingest = try XCTUnwrap(StubURLProtocol.requestPaths.first { $0.hasSuffix(SDKEndpoints.ingest) },
                                   "precondition: the ingest request was made and failed")
        client.recordRequest(method: "POST", url: url("https://stub.invalid" + ingest), status: 500, durationMs: 3)
        await client.flush()

        XCTAssertFalse(names.get().contains("$http_error"))
    }

    func testARepeatAfterTheWindowCarriesSuppressedCountOnTheLimiterClock() {
        let uptime = LockedBox<TimeInterval>(0)
        let sent = LockedBox<[[String: Any]]>([])
        let client = makeClient(protocolClass: AttributionCaptureProtocol.self, uptime: uptime) { name, props in
            if name == "$http_error" { sent.mutate { $0.append(props ?? [:]) } }
        }
        defer { client.destroy() }

        // The query is not part of the signature: these are one failure, three times.
        for page in 0..<3 {
            client.recordRequest(method: "GET", url: url("https://api.example.com/v1/feed?page=\(page)"), status: 503, durationMs: 1)
        }
        client.recordRequest(method: "GET", url: url("https://api.example.com/v1/feed"), status: 500, durationMs: 1)
        uptime.mutate { $0 += ErrorCaptureLimiter.window }
        client.recordRequest(method: "GET", url: url("https://api.example.com/v1/feed"), status: 503, durationMs: 1)

        XCTAssertEqual(sent.get().compactMap { $0["status"] as? Int }, [503, 500, 503], "a different status is a different signature")
        XCTAssertNil(sent.get().first?["suppressed_count"])
        XCTAssertEqual(sent.get().last?["suppressed_count"] as? Int, 2)
    }

    func testCallsOverTheGlobalCapAreCountedOnTheNextSentFailure() {
        let uptime = LockedBox<TimeInterval>(0)
        let sent = LockedBox<[[String: Any]]>([])
        let client = makeClient(protocolClass: AttributionCaptureProtocol.self, uptime: uptime) { name, props in
            if name == "$http_error" { sent.mutate { $0.append(props ?? [:]) } }
        }
        defer { client.destroy() }

        for index in 0..<(ErrorCaptureLimiter.globalCap + 5) {
            client.recordRequest(method: "GET", url: url("https://api.example.com/items/\(index)"), status: 404, durationMs: 1)
        }
        XCTAssertEqual(sent.get().count, ErrorCaptureLimiter.globalCap)

        uptime.mutate { $0 += ErrorCaptureLimiter.window }
        client.recordRequest(method: "GET", url: url("https://api.example.com/after"), status: 404, durationMs: 1)

        XCTAssertEqual(sent.get().last?["path"] as? String, "/after")
        XCTAssertEqual(sent.get().last?["dropped_count"] as? Int, 5)
    }
}
