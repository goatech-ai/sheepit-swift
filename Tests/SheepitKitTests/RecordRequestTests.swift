import XCTest
@testable import SheepitKit

/// `recordRequest(method:url:status:durationMs:responseBytes:error:)` — failed first-party HTTP
/// requests as `$http_error` (`SheepitClient+RequestTelemetry.swift`). Events are observed through
/// `config.onEvent`; the clients are constructed but never started, so nothing touches the
/// network. Wire-level and limiter-clock cases live in `RecordRequestWireTests`; the allowlist
/// matcher on its own in `RequestTelemetryPolicyTests`.
final class RecordRequestTests: XCTestCase {
    override func setUp() {
        super.setUp()
        SharedSDKStorage.clear()
        TeardownFlushes.install()
    }

    /// Awaits every destroyed client's fire-and-forget final flush first: it otherwise fails
    /// later, in another suite, and writes an offline backlog into the shared storage.
    override func tearDown() async throws {
        await TeardownFlushes.drain(context: name)
        SharedSDKStorage.clear()
        try await super.tearDown()
    }

    private typealias Captured = (name: String, properties: [String: Any]?)

    private func makeClient(
        hosts: [String] = ["api.example.com"],
        apiUrl: String = "http://127.0.0.1:1",
        diagnostics: LockedBox<[DiagnosticEvent]>? = nil,
        onEvent: (@Sendable (String, [String: Any]?) -> Void)? = nil
    ) -> (SheepitClient, LockedBox<[Captured]>) {
        let events = LockedBox<[Captured]>([])
        var config = SheepitConfig(
            apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))",
            apiUrl: apiUrl,
            // Loopback port 1 refuses at once (no DNS lookup), and one attempt skips the 1 s / 5 s
            // backoff — so the final flush `destroy()` starts settles before `tearDown` drains it.
            retryAttempts: 1,
            crashes: CrashConfig(enabled: false),
            requestTelemetryHosts: hosts
        )
        config.onEvent = { @Sendable name, properties in
            events.mutate { $0.append((name, properties)) }
            onEvent?(name, properties)
        }
        if let diagnostics {
            config.onDiagnostic = { @Sendable event in diagnostics.mutate { $0.append(event) } }
        }
        return (SheepitClient.constructOnlyForTesting(config: config), events)
    }

    private func httpErrors(_ box: LockedBox<[Captured]>) -> [[String: Any]] {
        box.get().filter { $0.name == "$http_error" }.map { $0.properties ?? [:] }
    }

    private func onlyHTTPError(_ box: LockedBox<[Captured]>, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let sent = httpErrors(box)
        XCTAssertEqual(sent.count, 1, "exactly one $http_error", file: file, line: line)
        return try XCTUnwrap(sent.first, file: file, line: line)
    }

    private func url(_ string: String) -> URL { URL(string: string)! }

    private func cyclicDictionary() -> NSMutableDictionary {
        let dictionary = NSMutableDictionary()
        dictionary["self"] = dictionary
        return dictionary
    }

    // MARK: - What is recorded at all

    func testANonAllowlistedHostIsNotRecorded() {
        let (client, events) = makeClient()
        defer { client.destroy() }

        client.recordRequest(method: "GET", url: url("https://other.example.com/v1/items"), status: 500, durationMs: 10)
        client.recordRequest(method: "GET", url: url("https://example.com/v1/items"), status: 500, durationMs: 10)
        client.recordRequest(method: "GET", url: url("https://evil-api.example.com.attacker.net/x"), status: 500, durationMs: 10)

        XCTAssertTrue(httpErrors(events).isEmpty)
    }

    func testTheDefaultEmptyAllowlistRecordsNothing() {
        let (client, events) = makeClient(hosts: [])
        defer { client.destroy() }

        client.recordRequest(method: "GET", url: url("https://api.example.com/v1/items"), status: 500, durationMs: 10)
        client.recordRequest(method: "GET", url: url("https://api.example.com/v1/items"), status: nil, durationMs: 10, error: URLError(.timedOut))

        XCTAssertTrue(httpErrors(events).isEmpty)
        XCTAssertEqual(SheepitConfig(apiKey: "k").requestTelemetryHosts, [], "opt-in: the default is empty")
    }

    func testSuccessAndRedirectStatusesAreNotRecorded() {
        let (client, events) = makeClient()
        defer { client.destroy() }

        for status in [1, 100, 200, 204, 301, 304, 399] {
            client.recordRequest(method: "GET", url: url("https://api.example.com/v1/items"), status: status, durationMs: 10)
        }

        XCTAssertTrue(events.get().isEmpty, "a status under 400 sends nothing at all")
    }

    // MARK: - Event shape

    func testA400IsRecordedWithExactlyTheseProperties() throws {
        let (client, events) = makeClient()
        defer { client.destroy() }

        client.recordRequest(
            method: "post",
            url: url("https://api.example.com/v1/orders/42"),
            status: 400,
            durationMs: 123.6,
            responseBytes: 512
        )

        let props = try onlyHTTPError(events)
        XCTAssertEqual(props as NSDictionary, [
            "url": "https://api.example.com/v1/orders/42",
            "host": "api.example.com",
            "path": "/v1/orders/42",
            "method": "POST",
            "status": 400,
            "latency_ms": 124,
            "kind": "http_error",
            "origin": "app",
            "response_bytes": 512,
        ] as NSDictionary)
    }

    func testTheQueryFragmentAndUserinfoAreNeverSent() throws {
        let (client, events) = makeClient()
        defer { client.destroy() }

        client.recordRequest(
            method: "GET",
            url: url("https://alice:s3cret@API.Example.COM/v1/search?token=abc123&q=me#section-2"),
            status: 503,
            durationMs: 5
        )

        let props = try onlyHTTPError(events)
        XCTAssertEqual(props["url"] as? String, "https://api.example.com/v1/search")
        XCTAssertEqual(props["host"] as? String, "api.example.com")
        XCTAssertEqual(props["path"] as? String, "/v1/search")
        let everything = props.values.map { String(describing: $0) }.joined(separator: " ")
        for leaked in ["token", "abc123", "q=me", "section-2", "alice", "s3cret", "?", "#", "@"] {
            XCTAssertFalse(everything.contains(leaked), "\(leaked) leaked: \(everything)")
        }
    }

    func testANonDefaultPortIsKeptAndADefaultOneDropped() throws {
        let (client, events) = makeClient()
        defer { client.destroy() }

        client.recordRequest(method: "GET", url: url("https://api.example.com:8443/a"), status: 500, durationMs: 1)
        client.recordRequest(method: "GET", url: url("https://api.example.com:443/b"), status: 500, durationMs: 1)
        client.recordRequest(method: "GET", url: url("http://api.example.com:80/c"), status: 500, durationMs: 1)
        client.recordRequest(method: "GET", url: url("https://api.example.com"), status: 500, durationMs: 1)

        XCTAssertEqual(httpErrors(events).compactMap { $0["url"] as? String }, [
            "https://api.example.com:8443/a",
            "https://api.example.com/b",
            "http://api.example.com/c",
            "https://api.example.com/",
        ])
        XCTAssertEqual(httpErrors(events).last?["path"] as? String, "/", "an empty path is sent as /")
    }

    func testThePathIsSentVerbatimIncludingPercentEncoding() throws {
        let (client, events) = makeClient()
        defer { client.destroy() }

        client.recordRequest(method: "GET", url: url("https://api.example.com/files/a%2Fb/Report%20Q3;v=2"), status: 404, durationMs: 1)

        XCTAssertEqual(try onlyHTTPError(events)["path"] as? String, "/files/a%2Fb/Report%20Q3;v=2")
    }

    func testATransportFailureIsANetworkFailureWithStatusZeroLikeSdkJs() throws {
        let (client, events) = makeClient()
        defer { client.destroy() }

        client.recordRequest(
            method: "GET",
            url: url("https://api.example.com/v1/feed"),
            status: nil,
            durationMs: 30_000,
            error: URLError(.timedOut)
        )

        let props = try onlyHTTPError(events)
        XCTAssertEqual(props["kind"] as? String, "network_failure")
        XCTAssertEqual(props["status"] as? Int, 0)
        XCTAssertEqual(props["latency_ms"] as? Int, 30_000)
        XCTAssertEqual(props["error_name"] as? String, "NSError")
        XCTAssertEqual(props["error_domain"] as? String, NSURLErrorDomain)
        XCTAssertEqual(props["error_code"] as? Int, NSURLErrorTimedOut)
        XCTAssertEqual(props["aborted"] as? Bool, false)
        let message = try XCTUnwrap(props["error_message"] as? String)
        XCTAssertTrue(message.hasPrefix("\(NSURLErrorDomain) \(NSURLErrorTimedOut)"), message)
        XCTAssertNil(props["response_bytes"])
    }

    /// 0 is what the wire carries for a transport failure (and what sdk-js passes); a negative
    /// value is typically a `URLError` code passed as the status. Neither may be dropped.
    func testAZeroOrNegativeStatusIsATransportFailure() throws {
        let (client, events) = makeClient()
        defer { client.destroy() }

        client.recordRequest(method: "GET", url: url("https://api.example.com/zero"), status: 0, durationMs: 1, error: URLError(.notConnectedToInternet))
        client.recordRequest(method: "GET", url: url("https://api.example.com/negative"), status: NSURLErrorTimedOut, durationMs: 1)

        let sent = httpErrors(events)
        XCTAssertEqual(sent.compactMap { $0["path"] as? String }, ["/zero", "/negative"])
        XCTAssertEqual(sent.compactMap { $0["status"] as? Int }, [0, 0])
        XCTAssertEqual(sent.compactMap { $0["kind"] as? String }, ["network_failure", "network_failure"])
        XCTAssertEqual(sent.first?["aborted"] as? Bool, false)
    }

    func testACancelledRequestIsMarkedAborted() throws {
        let (client, events) = makeClient()
        defer { client.destroy() }

        client.recordRequest(method: "GET", url: url("https://api.example.com/x"), status: nil, durationMs: 1, error: URLError(.cancelled))

        XCTAssertEqual(try onlyHTTPError(events)["aborted"] as? Bool, true)
    }

    func testATransportFailureWithoutAnErrorStillRecordsTheRequest() throws {
        let (client, events) = makeClient()
        defer { client.destroy() }

        client.recordRequest(method: "GET", url: url("https://api.example.com/x"), status: nil, durationMs: 1)

        let props = try onlyHTTPError(events)
        XCTAssertEqual(props["kind"] as? String, "network_failure")
        XCTAssertNil(props["error_name"])
        XCTAssertNil(props["aborted"])
    }

    func testAnErrorOnAnHTTPFailureIsDescribedButNotMarkedAborted() throws {
        let (client, events) = makeClient()
        defer { client.destroy() }

        client.recordRequest(
            method: "GET", url: url("https://api.example.com/x"), status: 500, durationMs: 1,
            error: NSError(domain: "com.example.api", code: 9, userInfo: [NSLocalizedDescriptionKey: "Upstream down"])
        )

        let props = try onlyHTTPError(events)
        XCTAssertEqual(props["kind"] as? String, "http_error")
        XCTAssertEqual(props["error_message"] as? String, "com.example.api 9: Upstream down")
        XCTAssertNil(props["aborted"], "aborted is a transport-failure field, as in sdk-js")
    }

    func testANegativeResponseSizeIsNotSent() throws {
        let (client, events) = makeClient()
        defer { client.destroy() }

        client.recordRequest(method: "GET", url: url("https://api.example.com/x"), status: 500, durationMs: 1, responseBytes: -1)

        XCTAssertNil(try onlyHTTPError(events)["response_bytes"], "URLResponse.expectedContentLength is -1 when unknown")
    }

    // MARK: - Hostile input never crashes the host

    /// `captureError`'s hazard vectors (PR #1173 rounds 3–4): each crashes `localizedDescription`.
    /// A crash here is the regression.
    func testHostileErrorsDoNotCrashAndKeepOnlyTheSafeText() throws {
        let (client, events) = makeClient()
        defer { client.destroy() }
        var nonStringKey: [AnyHashable: Any] = [NSNumber(value: 1): "x"]
        nonStringKey[NSLocalizedDescriptionKey] = "Visible"
        let hazards: [Error] = [
            NSError(domain: "d", code: 1, userInfo: [NSLocalizedFailureReasonErrorKey: cyclicDictionary()]),
            NSError(domain: "d", code: 2, userInfo: [NSLocalizedDescriptionKey: NSNumber(value: 7)]),
            URLError(.badURL, userInfo: [NSLocalizedFailureReasonErrorKey: cyclicDictionary()]),
            CFErrorCreate(kCFAllocatorDefault, "d" as CFString, 3, NSDictionary(dictionary: nonStringKey) as CFDictionary)!,
        ]

        for (index, error) in hazards.enumerated() {
            client.recordRequest(method: "GET", url: url("https://api.example.com/h/\(index)"), status: nil, durationMs: 1, error: error)
        }

        let messages = httpErrors(events).compactMap { $0["error_message"] as? String }
        XCTAssertEqual(messages, ["d 1", "d 2", "\(NSURLErrorDomain) \(NSURLErrorBadURL)", "d 3: Visible"])
    }

    func testNonFiniteAndHugeDurationsDoNotTrap() {
        let (client, events) = makeClient()
        defer { client.destroy() }

        for (index, duration) in [Double.nan, .infinity, -.infinity, -5, 1e300, Double(Int.max)].enumerated() {
            client.recordRequest(method: "GET", url: url("https://api.example.com/d/\(index)"), status: 500, durationMs: duration)
        }

        XCTAssertEqual(httpErrors(events).compactMap { $0["latency_ms"] as? Int },
                       [0, 0, 0, 0, Int(Int32.max), Int(Int32.max)])
    }

    func testTheMethodIsUppercasedTrimmedBoundedAndDefaultsToGet() {
        let (client, events) = makeClient()
        defer { client.destroy() }

        client.recordRequest(method: " patch\n", url: url("https://api.example.com/m/1"), status: 500, durationMs: 1)
        client.recordRequest(method: "", url: url("https://api.example.com/m/2"), status: 500, durationMs: 1)
        client.recordRequest(method: String(repeating: "x", count: 100_000), url: url("https://api.example.com/m/3"), status: 500, durationMs: 1)

        XCTAssertEqual(httpErrors(events).compactMap { $0["method"] as? String },
                       ["PATCH", "GET", String(repeating: "X", count: SheepitClient.requestTelemetryMaxMethodLength)])
    }

    func testALongPathIsCutTo500Characters() throws {
        let (client, events) = makeClient()
        defer { client.destroy() }

        client.recordRequest(method: "GET", url: url("https://api.example.com/" + String(repeating: "a", count: 5_000)), status: 500, durationMs: 1)

        let props = try onlyHTTPError(events)
        XCTAssertEqual((props["path"] as? String)?.count, SheepitClient.errorCaptureMaxStringLength)
        XCTAssertEqual((props["url"] as? String)?.count, SheepitClient.errorCaptureMaxStringLength)
    }

    // MARK: - The SDK's own API is never recorded

    func testTheSDKsOwnAPIHostIsNeverRecordedEvenWhenAllowlisted() {
        let (client, events) = makeClient(hosts: ["127.0.0.1", "api.example.com"])
        defer { client.destroy() }

        client.recordRequest(method: "POST", url: url("http://127.0.0.1:1/v1/ingest"), status: 500, durationMs: 1)
        client.recordRequest(method: "GET", url: url("https://127.0.0.1/v1/config"), status: nil, durationMs: 1, error: URLError(.cannotConnectToHost))
        client.recordRequest(method: "GET", url: url("http://127.0.0.1:1/"), status: 502, durationMs: 1)

        XCTAssertTrue(httpErrors(events).isEmpty, "a host-wide interceptor feeding the SDK's own failures back must not loop")
    }

    func testAnAPIURLWithAPathExcludesOnlyThatPathAndBelow() {
        let (client, events) = makeClient(hosts: ["127.0.0.1"], apiUrl: "http://127.0.0.1:1/_sheepit/")
        defer { client.destroy() }

        client.recordRequest(method: "POST", url: url("http://127.0.0.1:1/_sheepit/v1/ingest"), status: 500, durationMs: 1)
        client.recordRequest(method: "POST", url: url("http://127.0.0.1:1/_sheepit"), status: 500, durationMs: 1)
        client.recordRequest(method: "GET", url: url("http://127.0.0.1:1/_sheepitx/a"), status: 500, durationMs: 1)
        client.recordRequest(method: "GET", url: url("http://127.0.0.1:1/api/orders"), status: 500, durationMs: 1)

        XCTAssertEqual(httpErrors(events).compactMap { $0["path"] as? String }, ["/_sheepitx/a", "/api/orders"])
    }

    func testAnAPIURLWithNoPathOnAnAllowlistedHostIsReportedOnce() {
        let diagnostics = LockedBox<[DiagnosticEvent]>([])
        let (client, events) = makeClient(hosts: ["127.0.0.1"], apiUrl: "http://127.0.0.1:1/", diagnostics: diagnostics)
        defer { client.destroy() }

        client.recordRequest(method: "GET", url: url("http://127.0.0.1:1/api/orders"), status: 500, durationMs: 1)

        XCTAssertTrue(httpErrors(events).isEmpty, "the exclusion stays: it is what prevents a feedback loop")
        let reported = diagnostics.get().filter { $0.code == "request_telemetry.api_host_excluded" }
        XCTAssertEqual(reported.count, 1)
        XCTAssertTrue(reported.first?.message.contains("/_sheepit") == true, reported.first?.message ?? "")
    }

    func testNoAPIHostDiagnosticWhenAPIURLHasAPathOrItsHostIsNotAllowlisted() {
        let diagnostics = LockedBox<[DiagnosticEvent]>([])
        let (withPath, _) = makeClient(hosts: ["127.0.0.1"], apiUrl: "http://127.0.0.1:1/_sheepit", diagnostics: diagnostics)
        let (otherHost, _) = makeClient(hosts: ["api.example.com"], diagnostics: diagnostics)
        defer { withPath.destroy(); otherHost.destroy() }

        XCTAssertTrue(diagnostics.get().filter { $0.code == "request_telemetry.api_host_excluded" }.isEmpty)
    }

    // MARK: - Reentrancy, teardown, breadcrumb, diagnostics

    func testACallFromInsideOnEventIsDroppedNotRecursed() {
        let clientBox = LockedBox<SheepitClient?>(nil)
        let diagnostics = LockedBox<[DiagnosticEvent]>([])
        let (client, events) = makeClient(diagnostics: diagnostics) { name, _ in
            if name == "$http_error" {
                clientBox.get()?.recordRequest(method: "GET", url: URL(string: "https://api.example.com/nested")!, status: 500, durationMs: 1)
            }
        }
        clientBox.set(client)
        defer { client.destroy(); clientBox.set(nil) }

        client.recordRequest(method: "GET", url: url("https://api.example.com/outer"), status: 500, durationMs: 1)

        XCTAssertEqual(httpErrors(events).compactMap { $0["path"] as? String }, ["/outer"])
        XCTAssertEqual(diagnostics.get().filter { $0.code == "request_telemetry.reentrant_dropped" }.count, 1)

        client.recordRequest(method: "GET", url: url("https://api.example.com/second"), status: 500, durationMs: 1)
        XCTAssertEqual(httpErrors(events).count, 2, "the guard is per call, not a latch")
    }

    /// One key per API: a `captureError` from `onEvent` during a `recordRequest` still runs, once.
    func testCaptureErrorFromInsideRecordRequestsOnEventStillRunsOnce() {
        let clientBox = LockedBox<SheepitClient?>(nil)
        let (client, events) = makeClient { name, _ in
            if name == "$http_error" { clientBox.get()?.captureError("request failed") }
            if name == "$error" {
                clientBox.get()?.recordRequest(method: "GET", url: URL(string: "https://api.example.com/loop")!, status: 500, durationMs: 1)
            }
        }
        clientBox.set(client)
        defer { client.destroy(); clientBox.set(nil) }

        client.recordRequest(method: "GET", url: url("https://api.example.com/outer"), status: 500, durationMs: 1)

        XCTAssertEqual(events.get().map(\.name).filter { $0 != "$session_start" }, ["$http_error", "$error"])
    }

    func testADestroyedClientRecordsNothing() {
        let diagnostics = LockedBox<[DiagnosticEvent]>([])
        let (client, events) = makeClient(diagnostics: diagnostics)
        let crumbs = LockedBox<[SheepitBreadcrumb]>([])
        client.breadcrumbHookForTesting.value = { crumb in crumbs.mutate { $0.append(crumb) } }
        client.destroy()

        client.recordRequest(method: "GET", url: url("https://api.example.com/x"), status: 500, durationMs: 1)

        XCTAssertTrue(httpErrors(events).isEmpty)
        XCTAssertTrue(crumbs.get().isEmpty)
        XCTAssertTrue(diagnostics.get().filter { $0.code.hasPrefix("request_telemetry.") }.isEmpty)
    }

    func testARecordedFailureLeavesOneHTTPBreadcrumb() {
        let (client, _) = makeClient()
        defer { client.destroy() }
        let crumbs = LockedBox<[SheepitBreadcrumb]>([])
        client.breadcrumbHookForTesting.value = { crumb in crumbs.mutate { $0.append(crumb) } }

        client.recordRequest(method: "get", url: url("https://api.example.com/v1/feed?page=2"), status: 502, durationMs: 1)
        client.recordRequest(method: "get", url: url("https://api.example.com/v1/feed?page=3"), status: 502, durationMs: 1)
        client.recordRequest(method: "GET", url: url("https://api.example.com/v1/x"), status: nil, durationMs: 1)
        client.recordRequest(method: "GET", url: url("https://api.example.com/v1/ok"), status: 200, durationMs: 1)
        client.recordRequest(method: "GET", url: url("https://elsewhere.example.org/v1/x"), status: 500, durationMs: 1)

        XCTAssertEqual(crumbs.get().filter { $0.category == "http" }.map(\.message), [
            "GET api.example.com/v1/feed 502",
            "GET api.example.com/v1/x network_failure",
        ], "one crumb per SENT failure: a suppressed repeat, a success or a non-allowlisted host leaves none")
    }

    func testTheBreadcrumbFitsTheCrashContextBuffer() throws {
        let (client, _) = makeClient()
        defer { client.destroy() }
        let crumbs = LockedBox<[SheepitBreadcrumb]>([])
        client.breadcrumbHookForTesting.value = { crumb in crumbs.mutate { $0.append(crumb) } }

        client.recordRequest(method: "GET", url: url("https://api.example.com/" + String(repeating: "a", count: 5_000)), status: 500, durationMs: 1)

        let crumb = try XCTUnwrap(crumbs.get().first { $0.category == "http" })
        XCTAssertLessThanOrEqual(crumb.message.utf8.count, SDKDefaults.screenNameMaxUTF8Bytes)
    }

    func testUnusableAllowlistEntriesAreReportedOnce() {
        let diagnostics = LockedBox<[DiagnosticEvent]>([])
        let (client, events) = makeClient(
            hosts: ["https://api.example.com", "api.example.com:8443", "api.example.com/v1", "*", "", "*.com", "good.example.com"],
            diagnostics: diagnostics
        )
        defer { client.destroy() }

        let reported = diagnostics.get().filter { $0.code == "request_telemetry.invalid_host" }
        XCTAssertEqual(reported.count, 1)
        XCTAssertTrue(reported.first?.message.hasPrefix("6 ") == true, reported.first?.message ?? "")

        client.recordRequest(method: "GET", url: url("https://good.example.com/x"), status: 500, durationMs: 1)
        client.recordRequest(method: "GET", url: url("https://api.example.com/x"), status: 500, durationMs: 1)
        XCTAssertEqual(httpErrors(events).compactMap { $0["host"] as? String }, ["good.example.com"])
    }

    /// The limiter runs before the error text is built: a repeat suppressed in a tight loop never
    /// describes its error. `SelfDescribingFailure.description` is what `BoundedDescription` calls.
    func testASuppressedRepeatNeverDescribesItsError() {
        let (client, events) = makeClient()
        defer { client.destroy() }
        let described = LockedBox(0)
        let error = SelfDescribingFailure(described: described)

        for _ in 0..<20 {
            client.recordRequest(method: "GET", url: url("https://api.example.com/loop"), status: nil, durationMs: 1, error: error)
        }

        XCTAssertEqual(httpErrors(events).count, 1)
        XCTAssertEqual(described.get(), 1, "only the one event that was sent built its error text")
    }

    // MARK: - Separate limiter from captureError

    func testRequestFailuresCannotStarveCaptureErrorNorTheReverse() {
        let (client, events) = makeClient()
        defer { client.destroy() }

        for index in 0..<(ErrorCaptureLimiter.globalCap + 5) {
            client.recordRequest(method: "GET", url: url("https://api.example.com/r/\(index)"), status: 500, durationMs: 1)
        }
        client.captureError("still reported")

        XCTAssertEqual(httpErrors(events).count, ErrorCaptureLimiter.globalCap)
        XCTAssertEqual(events.get().filter { $0.name == "$error" }.count, 1)

        let (other, otherEvents) = makeClient()
        defer { other.destroy() }
        for index in 0..<(ErrorCaptureLimiter.globalCap + 5) { other.captureError("distinct \(index)") }
        other.recordRequest(method: "GET", url: url("https://api.example.com/after"), status: 500, durationMs: 1)

        XCTAssertEqual(httpErrors(otherEvents).count, 1)
    }
}

private struct SelfDescribingFailure: Error, CustomStringConvertible {
    let described: LockedBox<Int>
    var description: String {
        described.mutate { $0 += 1 }
        return "loop failure"
    }
}
