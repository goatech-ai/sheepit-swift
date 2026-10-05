import XCTest
@testable import SheepitKit

/// `captureError(_:error:attributes:)` — the public handled-error API
/// (`SheepitClient+ErrorCapture.swift`). Events are observed through `config.onEvent`; the
/// clients here are constructed but never started, so nothing touches the network. Wire-level
/// and clock-driven cases live in `CaptureErrorWireTests`.
final class CaptureErrorTests: XCTestCase {
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

    private enum CheckoutError: Error {
        case declined(code: Int, reason: String)
    }

    private enum PrivateError: Error {
        case broken
    }

    private func makeClient(
        diagnostics: LockedBox<[DiagnosticEvent]>? = nil,
        onEvent: (@Sendable (String, [String: Any]?) -> Void)? = nil
    ) -> (SheepitClient, LockedBox<[Captured]>) {
        let events = LockedBox<[Captured]>([])
        var config = SheepitConfig(
            apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))",
            apiUrl: "http://127.0.0.1:1",
            // Loopback port 1 refuses at once (no DNS lookup), and one attempt skips the 1 s / 5 s
            // backoff — so the final flush `destroy()` starts settles before `tearDown` drains it.
            retryAttempts: 1,
            crashes: CrashConfig(enabled: false)
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

    private func errors(_ box: LockedBox<[Captured]>) -> [[String: Any]] {
        box.get().filter { $0.name == "$error" }.map { $0.properties ?? [:] }
    }

    private func onlyError(_ box: LockedBox<[Captured]>, file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let sent = errors(box)
        XCTAssertEqual(sent.count, 1, "exactly one $error", file: file, line: line)
        return try XCTUnwrap(sent.first, file: file, line: line)
    }

    // MARK: - Event shape

    func testCaptureErrorEmitsErrorWithEveryReservedProperty() throws {
        let (client, events) = makeClient()
        defer { client.destroy() }

        client.captureError("Payment failed", error: CheckoutError.declined(code: 51, reason: "insufficient_funds"))

        let props = try onlyError(events)
        XCTAssertEqual(props["message"] as? String, "Payment failed")
        XCTAssertEqual(props["type"] as? String, "handled")
        XCTAssertEqual(props["origin"] as? String, "app")
        XCTAssertNil(props["platform"], "the platform and OS ride the event context, not a frozen property")
        XCTAssertEqual(props["error_type"] as? String, "SheepitKitTests.CaptureErrorTests.CheckoutError")
        XCTAssertEqual(props["error_domain"] as? String, "SheepitKitTests.CaptureErrorTests.CheckoutError")
        XCTAssertEqual(props["error_code"] as? Int, 0, "the bridged code of a Swift enum is the case index")
        XCTAssertNil(props["source"], "`source` in (performance, crashes) is what the server treats as SDK-internal")
        XCTAssertNil(props["suppressed_count"])
        XCTAssertNil(props["dropped_count"])
    }

    func testASwiftEnumErrorsAssociatedValuesReachTheDescription() throws {
        let (client, events) = makeClient()
        defer { client.destroy() }

        client.captureError("Payment failed", error: CheckoutError.declined(code: 51, reason: "insufficient_funds"))

        let description = try XCTUnwrap(try onlyError(events)["error_description"] as? String)
        XCTAssertTrue(description.contains("51"), description)
        XCTAssertTrue(description.contains("insufficient_funds"), description)
        XCTAssertFalse(
            description.contains("couldn’t be completed"),
            "localizedDescription drops the associated values; describing must be used"
        )
    }

    func testAnNSErrorCarriesItsDomainAndCode() throws {
        let (client, events) = makeClient()
        defer { client.destroy() }

        client.captureError(
            "Sync failed",
            error: NSError(domain: "com.example.sync", code: 42, userInfo: [NSLocalizedDescriptionKey: "Boom"])
        )

        let props = try onlyError(events)
        XCTAssertEqual(props["error_domain"] as? String, "com.example.sync")
        XCTAssertEqual(props["error_code"] as? Int, 42)
        XCTAssertEqual(props["error_type"] as? String, "NSError")
        XCTAssertTrue((props["error_description"] as? String)?.contains("Boom") == true)
    }

    func testWithoutAnErrorNoErrorFieldsAreSent() throws {
        let (client, events) = makeClient()
        defer { client.destroy() }

        client.captureError("Cache miss on a path that should never miss")

        let props = try onlyError(events)
        XCTAssertEqual(Set(props.keys), ["message", "type", "origin"])
    }

    /// A private type prints `Module.(unknown context at $<address>).Name`, and the address moves
    /// between launches — left in, one error would become a new group on every run.
    func testAPrivateErrorTypeNameIsStableAcrossLaunches() throws {
        let (client, events) = makeClient()
        defer { client.destroy() }

        client.captureError("x", error: PrivateError.broken)

        let props = try onlyError(events)
        let type = try XCTUnwrap(props["error_type"] as? String)
        let domain = try XCTUnwrap(props["error_domain"] as? String)
        XCTAssertFalse(type.contains("unknown context"), type)
        XCTAssertFalse(domain.contains("unknown context"), domain)
        XCTAssertTrue(type.hasSuffix("PrivateError"), type)
        XCTAssertEqual(SheepitClient.stableTypeName("App.(unknown context at $10a3c47d8).Foo"), "App.Foo")
    }

    // MARK: - Bounds

    func testEveryStringIsCutTo500CharactersOnACharacterBoundary() throws {
        let (client, events) = makeClient()
        defer { client.destroy() }
        let long = String(repeating: "😀", count: 600)

        client.captureError(long, error: CheckoutError.declined(code: 1, reason: long), attributes: ["note": long])

        let props = try onlyError(events)
        for key in ["message", "error_description", "note"] {
            let value = try XCTUnwrap(props[key] as? String, key)
            XCTAssertEqual(value.count, 500, key)
            XCTAssertLessThanOrEqual(value.utf8.count, SheepitClient.errorCaptureMaxStringUTF8Bytes, key)
        }
        XCTAssertEqual(props["message"] as? String, String(repeating: "😀", count: 500))
    }

    /// The byte cap: an 18-byte family emoji fits 113 times in 2 KB, and is never split.
    func testAMultiScalarCharacterIsNeverSplitByTheByteCap() throws {
        let bounded = SheepitClient.bounded(String(repeating: "👩‍👩‍👧", count: 600))
        XCTAssertLessThanOrEqual(bounded.utf8.count, SheepitClient.errorCaptureMaxStringUTF8Bytes)
        XCTAssertEqual(bounded.count, SheepitClient.errorCaptureMaxStringUTF8Bytes / "👩‍👩‍👧".utf8.count)
        XCTAssertTrue(bounded.allSatisfy { $0 == "👩‍👩‍👧" })
    }

    /// One grapheme cluster can carry unbounded combining marks — 500 CHARACTERS is no size bound.
    func testACombiningMarkFloodIsBoundedInBytes() {
        let flood = "ok " + "e" + String(repeating: "\u{301}", count: 10_000)
        let bounded = SheepitClient.bounded(flood)
        XCTAssertEqual(bounded, "ok ", "a single cluster wider than the byte cap is dropped, not cut")
    }

    func testAtMost50AttributesAreKeptInSortedKeyOrder() throws {
        var attributes: [String: Any] = [:]
        for index in 0..<60 { attributes[String(format: "k%02d", index)] = index }

        let props = SheepitClient.errorCaptureProperties(
            reserved: SheepitClient.errorCaptureReservedProperties(message: "m", error: nil),
            attributes: attributes
        )

        let callerKeys = props.keys.filter { $0.hasPrefix("k") }.sorted()
        XCTAssertEqual(callerKeys.count, 50)
        XCTAssertEqual(callerKeys.first, "k00")
        XCTAssertEqual(callerKeys.last, "k49")
    }

    // MARK: - Attributes

    func testAttributesAreMergedAndReservedKeysAlwaysWin() throws {
        let (client, events) = makeClient()
        defer { client.destroy() }

        client.captureError(
            "Payment failed",
            attributes: ["order_id": "o-1", "retries": 3, "message": "caller", "origin": "spoofed", "source": "crashes"]
        )

        let props = try onlyError(events)
        XCTAssertEqual(props["order_id"] as? String, "o-1")
        XCTAssertEqual(props["retries"] as? Int, 3)
        XCTAssertEqual(props["message"] as? String, "Payment failed")
        XCTAssertEqual(props["origin"] as? String, "app")
        XCTAssertEqual(props["attr_message"] as? String, "caller")
        XCTAssertEqual(props["attr_origin"] as? String, "spoofed")
        XCTAssertEqual(props["attr_source"] as? String, "crashes")
        XCTAssertNil(props["source"], "a caller `source` would hide the error from host-app error counts")
    }

    func testACollidingKeyWhoseAttrNameIsAlsoTakenIsDropped() throws {
        let props = SheepitClient.errorCaptureProperties(
            reserved: SheepitClient.errorCaptureReservedProperties(message: "m", error: nil),
            attributes: ["type": "mine", "attr_type": "also mine"]
        )

        XCTAssertEqual(props["type"] as? String, "handled")
        XCTAssertEqual(props["attr_type"] as? String, "also mine", "the caller's own attr_type key is kept as given")
        XCTAssertEqual(props.values.compactMap { $0 as? String }.filter { $0 == "mine" }.count, 0,
                       "the colliding `type` value has nowhere to go and is dropped")
    }

    func testValuesJSONCannotCarryAreStringifiedNotNulled() throws {
        let date = Date(timeIntervalSince1970: 0)
        let url = try XCTUnwrap(URL(string: "https://example.com/a"))
        let uuid = UUID()
        let props = SheepitClient.errorCaptureProperties(
            reserved: [:],
            attributes: [
                "date": date, "url": url, "uuid": uuid, "float": Float(1.5), "int64": Int64(7),
                "nan": Double.nan, "inf": Double.infinity, "double": 2.5, "bool": true, "null": NSNull(),
            ]
        )

        XCTAssertEqual(props["date"] as? String, String(describing: date))
        XCTAssertEqual(props["url"] as? String, "https://example.com/a")
        XCTAssertEqual(props["uuid"] as? String, uuid.uuidString)
        XCTAssertEqual(props["float"] as? String, "1.5")
        XCTAssertEqual(props["int64"] as? String, "7")
        XCTAssertEqual(props["nan"] as? String, "nan", "a NaN would make the whole event unencodable")
        XCTAssertEqual(props["inf"] as? String, "inf")
        XCTAssertEqual(props["double"] as? Double, 2.5)
        XCTAssertEqual(props["bool"] as? Bool, true)
        XCTAssertTrue(props["null"] is NSNull)

        // And the result really encodes: what reaches the wire is never a silent null.
        let data = try JSONEncoder().encode(props.mapValues { AnyCodable($0) })
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(decoded["float"] as? String, "1.5")
        XCTAssertEqual(decoded["nan"] as? String, "nan")
    }

    func testNestedContainersKeepJSONValuesAndStringifyTheRest() throws {
        let date = Date(timeIntervalSince1970: 0)
        let props = SheepitClient.errorCaptureProperties(
            reserved: [:],
            attributes: [
                "list": [1, "two", date, Double.nan] as [Any],
                "map": ["ok": true, "when": date] as [String: Any],
                "deep": [[[["too deep"]]]] as [Any],
            ]
        )

        let list = try XCTUnwrap(props["list"] as? [Any])
        XCTAssertEqual(list[0] as? Int, 1)
        XCTAssertEqual(list[1] as? String, "two")
        XCTAssertEqual(list[2] as? String, String(describing: date))
        XCTAssertEqual(list[3] as? String, "nan")
        let map = try XCTUnwrap(props["map"] as? [String: Any])
        XCTAssertEqual(map["ok"] as? Bool, true)
        XCTAssertEqual(map["when"] as? String, String(describing: date))
        let level1 = try XCTUnwrap(props["deep"] as? [Any])
        let level2 = try XCTUnwrap(level1.first as? [Any])
        let level3 = try XCTUnwrap(level2.first as? [Any])
        XCTAssertTrue(level3.first is String, "a container below the depth limit is sent as its description")
        XCTAssertNoThrow(try JSONEncoder().encode(props.mapValues { AnyCodable($0) }))
    }

    // MARK: - Burst limiting through the client

    func testRepeatsOfTheSameErrorAreSuppressedWithOneDiagnostic() throws {
        let diagnostics = LockedBox<[DiagnosticEvent]>([])
        let (client, events) = makeClient(diagnostics: diagnostics)
        defer { client.destroy() }

        for _ in 0..<5 { client.captureError("Same", error: CheckoutError.declined(code: 1, reason: "a")) }

        XCTAssertEqual(errors(events).count, 1)
        XCTAssertEqual(diagnostics.get().filter { $0.code == "error_capture.suppressed" }.count, 1,
                       "the suppression diagnostic is itself rate-limited")
    }

    func testTheAssociatedValueIsNotPartOfTheSignature() {
        let (client, events) = makeClient()
        defer { client.destroy() }

        client.captureError("Declined", error: CheckoutError.declined(code: 1, reason: "a"))
        client.captureError("Declined", error: CheckoutError.declined(code: 2, reason: "b"))
        client.captureError("Declined", error: NSError(domain: "other", code: 0))

        XCTAssertEqual(errors(events).count, 2,
                       "signature = message + type + domain + code: same case, different payload, is a repeat")
    }

    func testConcurrentCallersShareTheGlobalCap() {
        let (client, events) = makeClient()
        defer { client.destroy() }

        DispatchQueue.concurrentPerform(iterations: 100) { index in
            client.captureError("concurrent \(index)")
        }

        XCTAssertEqual(errors(events).count, ErrorCaptureLimiter.globalCap)
    }

    // MARK: - Safety

    func testACallFromInsideOnEventIsDroppedNotRecursed() {
        let diagnostics = LockedBox<[DiagnosticEvent]>([])
        let clientBox = LockedBox<SheepitClient?>(nil)
        let (client, events) = makeClient(diagnostics: diagnostics) { name, _ in
            if name == "$error" { clientBox.get()?.captureError("nested from onEvent") }
        }
        clientBox.set(client)
        defer { clientBox.set(nil); client.destroy() }

        client.captureError("outer")

        XCTAssertEqual(errors(events).map { $0["message"] as? String }, ["outer"])
        XCTAssertEqual(diagnostics.get().filter { $0.code == "error_capture.reentrant_dropped" }.count, 1)

        // The guard is per call, not a latch: the next top-level call still goes through.
        client.captureError("second outer")
        XCTAssertEqual(errors(events).count, 2)
    }

    /// The reentrancy diagnostic's own subscriber calling `captureError` must not recurse either.
    func testADiagnosticSubscriberThatCapturesCannotRecurse() {
        let clientBox = LockedBox<SheepitClient?>(nil)
        var config = SheepitConfig(
            apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))",
            apiUrl: "http://127.0.0.1:1",
            // Loopback port 1 refuses at once (no DNS lookup), and one attempt skips the 1 s / 5 s
            // backoff — so the final flush `destroy()` starts settles before `tearDown` drains it.
            retryAttempts: 1,
            crashes: CrashConfig(enabled: false)
        )
        let count = LockedBox(0)
        config.onEvent = { @Sendable name, _ in
            if name == "$error" { count.mutate { $0 += 1 }; clientBox.get()?.captureError("from onEvent") }
        }
        config.onDiagnostic = { @Sendable event in
            if event.code.hasPrefix("error_capture.") { clientBox.get()?.captureError("from onDiagnostic") }
        }
        let client = SheepitClient.constructOnlyForTesting(config: config)
        clientBox.set(client)
        defer { clientBox.set(nil); client.destroy() }

        client.captureError("outer")

        XCTAssertEqual(count.get(), 1)
    }

    func testADestroyedClientIsANoOp() {
        let diagnostics = LockedBox<[DiagnosticEvent]>([])
        let (client, events) = makeClient(diagnostics: diagnostics)
        let crumbs = LockedBox<[SheepitBreadcrumb]>([])
        client.breadcrumbHookForTesting.value = { crumb in crumbs.mutate { $0.append(crumb) } }
        client.destroy()

        client.captureError("after destroy", error: CheckoutError.declined(code: 1, reason: "x"))

        XCTAssertTrue(errors(events).isEmpty)
        XCTAssertTrue(crumbs.get().isEmpty)
        XCTAssertTrue(diagnostics.get().filter { $0.code.hasPrefix("error_capture.") }.isEmpty)
    }

    // MARK: - Breadcrumb

    func testASentErrorLeavesAnErrorBreadcrumbCarryingTheMessage() {
        let (client, _) = makeClient()
        defer { client.destroy() }
        let crumbs = LockedBox<[SheepitBreadcrumb]>([])
        client.breadcrumbHookForTesting.value = { crumb in crumbs.mutate { $0.append(crumb) } }

        client.captureError("Payment failed")
        client.captureError("Payment failed")

        let errorCrumbs = crumbs.get().filter { $0.category == "error" }
        XCTAssertEqual(errorCrumbs.map(\.message), ["Payment failed"],
                       "one crumb per SENT error — a suppressed repeat must not flood the 32-entry ring")
    }

    func testTheBreadcrumbMessageFitsTheCrashContextBuffer() throws {
        let (client, _) = makeClient()
        defer { client.destroy() }
        let crumbs = LockedBox<[SheepitBreadcrumb]>([])
        client.breadcrumbHookForTesting.value = { crumb in crumbs.mutate { $0.append(crumb) } }

        client.captureError(String(repeating: "é", count: 400))

        let crumb = try XCTUnwrap(crumbs.get().first { $0.category == "error" })
        XCTAssertLessThanOrEqual(crumb.message.utf8.count, SDKDefaults.screenNameMaxUTF8Bytes)
        XCTAssertTrue(crumb.message.allSatisfy { $0 == "é" })
    }
}
