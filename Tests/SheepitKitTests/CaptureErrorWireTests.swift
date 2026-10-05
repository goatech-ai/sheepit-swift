import XCTest
@testable import SheepitKit

/// `captureError` through a STARTED client: what the encoded ingest body carries, that a failing
/// ingest produces no further `$error`, and the burst limiter aged on its injected monotonic
/// clock. The network is `AttributionCaptureProtocol` / `StubURLProtocol`, never the real one.
final class CaptureErrorWireTests: XCTestCase {
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
                crashes: CrashConfig(enabled: false)
            ),
            now: { Date() },
            urlProtocolClasses: [protocolClass],
            errorCaptureUptime: { uptime.get() }
        )
    }

    func testTheIngestBodyCarriesThePropertiesAndTheSameIdentityAsAPrecedingTrack() async throws {
        let client = makeClient(protocolClass: AttributionCaptureProtocol.self)
        defer { client.destroy() }
        let message = "wire probe \(UUID().uuidString.prefix(8))"

        client.track("capture_error_wire_probe")
        client.captureError(
            message,
            error: NSError(domain: "com.example.checkout", code: 7),
            attributes: ["order_id": "o-1", "when": Date(timeIntervalSince1970: 0)]
        )
        await client.flush()

        let error = try XCTUnwrap(AttributionCaptureProtocol.event(named: "$error"), "$error was never sent")
        let probe = try XCTUnwrap(AttributionCaptureProtocol.event(named: "capture_error_wire_probe"))
        let props = try XCTUnwrap(error["properties"] as? [String: Any])
        XCTAssertEqual(props["message"] as? String, message)
        XCTAssertEqual(props["type"] as? String, "handled")
        XCTAssertEqual(props["origin"] as? String, "app")
        XCTAssertNil(props["platform"])
        let device = try XCTUnwrap((error["context"] as? [String: Any])?["device"] as? [String: Any])
        XCTAssertNotNil(device["platform"], "the platform comes from the event context")
        XCTAssertEqual(props["error_type"] as? String, "NSError")
        XCTAssertEqual(props["error_domain"] as? String, "com.example.checkout")
        XCTAssertEqual(props["error_code"] as? Int, 7)
        XCTAssertNotNil(props["error_description"] as? String)
        XCTAssertEqual(props["order_id"] as? String, "o-1")
        XCTAssertEqual(props["when"] as? String, String(describing: Date(timeIntervalSince1970: 0)),
                       "a Date must arrive as text, not as JSON null")

        let errorContext = try XCTUnwrap(error["context"] as? [String: Any])
        let probeContext = try XCTUnwrap(probe["context"] as? [String: Any])
        let errorSession = (errorContext["session"] as? [String: Any])?["id"] as? String
        let errorDevice = (errorContext["device"] as? [String: Any])?["id"] as? String
        XCTAssertNotNil(errorSession)
        XCTAssertNotNil(errorDevice)
        XCTAssertEqual(errorSession, (probeContext["session"] as? [String: Any])?["id"] as? String)
        XCTAssertEqual(errorDevice, (probeContext["device"] as? [String: Any])?["id"] as? String)
    }

    /// A send failure goes to the `DiagnosticBus`, never back into `$error` — so a failing ingest
    /// cannot feed itself.
    func testAFailingIngestProducesNoFurtherError() async throws {
        StubURLProtocol.stub = .status(500, body: #"{"error":{"code":"INTERNAL","message":"stub"}}"#)
        let names = LockedBox<[String]>([])
        let client = makeClient(protocolClass: StubURLProtocol.self) { name, _ in
            names.mutate { $0.append(name) }
        }
        defer { client.destroy() }

        client.captureError("ingest will fail")
        await client.flush()
        await client.flush()

        XCTAssertTrue(StubURLProtocol.requestPaths.contains { $0.hasSuffix(SDKEndpoints.ingest) },
                      "precondition: the ingest request was made and failed")
        XCTAssertEqual(names.get().filter { $0 == "$error" }.count, 1)
    }

    func testTheNextErrorAfterTheWindowCarriesSuppressedCountOnTheLimiterClock() throws {
        let uptime = LockedBox<TimeInterval>(0)
        let sent = LockedBox<[[String: Any]]>([])
        let client = makeClient(protocolClass: AttributionCaptureProtocol.self, uptime: uptime) { name, props in
            if name == "$error" { sent.mutate { $0.append(props ?? [:]) } }
        }
        defer { client.destroy() }

        for _ in 0..<3 { client.captureError("Flaky endpoint") }
        uptime.mutate { $0 += ErrorCaptureLimiter.window }
        client.captureError("Flaky endpoint")

        XCTAssertEqual(sent.get().count, 2)
        XCTAssertNil(sent.get().first?["suppressed_count"])
        XCTAssertEqual(sent.get().last?["suppressed_count"] as? Int, 2)
    }

    func testCallsOverTheGlobalCapAreCountedOnTheNextSentError() throws {
        let uptime = LockedBox<TimeInterval>(0)
        let sent = LockedBox<[[String: Any]]>([])
        let client = makeClient(protocolClass: AttributionCaptureProtocol.self, uptime: uptime) { name, props in
            if name == "$error" { sent.mutate { $0.append(props ?? [:]) } }
        }
        defer { client.destroy() }

        for index in 0..<(ErrorCaptureLimiter.globalCap + 5) { client.captureError("distinct \(index)") }
        XCTAssertEqual(sent.get().count, ErrorCaptureLimiter.globalCap)

        uptime.mutate { $0 += ErrorCaptureLimiter.window }
        client.captureError("after the window")

        XCTAssertEqual(sent.get().last?["message"] as? String, "after the window")
        XCTAssertEqual(sent.get().last?["dropped_count"] as? Int, 5)
    }
}
