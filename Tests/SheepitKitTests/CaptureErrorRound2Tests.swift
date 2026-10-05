import XCTest
@testable import SheepitKit

/// PR #1173 review round 2 for `captureError`: the host-app crash on a cyclic `NSError`, the
/// unbounded total size, unbounded keys, and the async re-entry bound. Each test names the
/// finding it fences.
final class CaptureErrorRound2Tests: XCTestCase {
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
        case nested(inner: [String: Int], retry: Int?, tags: [String])
    }

    /// `@unchecked`: `Error` implies `Sendable`, and the payload is a mutable Foundation object on
    /// purpose — that is the shape that crashed.
    private enum ContextError: Error, @unchecked Sendable {
        case withContext(NSMutableDictionary)
    }

    private struct Failure: Error {
        let field: Int
        let name: String
    }

    private final class ClassError: Error {
        let detail = "x"
    }

    private struct DescribedError: Error, CustomStringConvertible {
        var description: String { "described by the host" }
    }

    private final class Opaque: NSObject {}

    private struct Holder {
        let context: NSMutableDictionary
    }

    /// The reviewer's exact vector: a dictionary that contains itself, in `userInfo`.
    private func cyclicDictionary() -> NSMutableDictionary {
        let dictionary = NSMutableDictionary()
        dictionary["self"] = dictionary
        return dictionary
    }

    /// Round 3: the cycle sits under a key Foundation actually READS when composing
    /// `localizedDescription`. Round 2's fixture used an arbitrary `"ctx"` key, which nothing
    /// consults — so it passed against code that still called `localizedDescription`.
    private func cyclicNSError() -> NSError {
        NSError(domain: "com.example", code: 1, userInfo: [NSLocalizedFailureReasonErrorKey: cyclicDictionary()])
    }

    private func makeClient(
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
        return (SheepitClient.constructOnlyForTesting(config: config), events)
    }

    private func errors(_ box: LockedBox<[Captured]>) -> [[String: Any]] {
        box.get().filter { $0.name == "$error" }.map { $0.properties ?? [:] }
    }

    private func props(_ attributes: [String: Any]) -> [String: Any] {
        SheepitClient.errorCaptureProperties(
            reserved: SheepitClient.errorCaptureReservedProperties(message: "m", error: nil),
            attributes: attributes
        )
    }

    /// The full wire event, encoded the way `Transport` encodes it.
    private func encodedEventBytes(_ properties: [String: Any]) throws -> Int {
        let event = EnrichedEvent(
            eventId: UUID().uuidString,
            eventName: "$error",
            eventProperties: properties.mapValues { AnyCodable($0) },
            deviceId: UUID().uuidString,
            anonymousId: UUID().uuidString,
            sessionId: UUID().uuidString,
            userId: String(repeating: "u", count: SDKDefaults.userIdMaxLength),
            platform: "ios",
            sdkVersion: SDKDefaults.sdkVersion,
            locale: "en_US",
            timezone: "America/Argentina/Buenos_Aires",
            timestamp: SheepitClient.formatEventTimestamp(Date()),
            snapshot: TrackSnapshot.capture(appVersion: String(repeating: "9", count: SDKDefaults.appVersionMaxLength))
        )
        return try JSONEncoder().encode(Transport.wireEvent(event)).count
    }

    // MARK: - MF1: a cyclic NSError must not crash the host app

    func testACyclicNSErrorIsDescribedWithoutTouchingUserInfo() throws {
        let reserved = SheepitClient.errorCaptureReservedProperties(message: "boom", error: cyclicNSError())

        let description = try XCTUnwrap(reserved["error_description"] as? String)
        XCTAssertEqual(description, "com.example 1", "a non-string failure reason is not text; userInfo is never described")
        XCTAssertEqual(reserved["error_domain"] as? String, "com.example")
        XCTAssertEqual(reserved["error_code"] as? Int, 1)
    }

    func testACyclicNSErrorThroughThePublicAPIIsSent() throws {
        let (client, events) = makeClient()
        defer { client.destroy() }

        client.captureError("boom", error: cyclicNSError())

        let sent = try XCTUnwrap(errors(events).first)
        XCTAssertEqual(sent["error_description"] as? String, "com.example 1")
    }

    func testAnNSErrorDescriptionHasDomainCodeAndItsDescriptionString() {
        let error = NSError(domain: "com.example.sync", code: 42, userInfo: [NSLocalizedDescriptionKey: "Boom"])
        XCTAssertEqual(BoundedDescription.of(error: error), "com.example.sync 42: Boom")
    }

    /// Erased to `Error`, Foundation's error structs have dynamic type `NSError`, so the plain
    /// metatype check covers them (no underscored-protocol clause). Off that path they would reach
    /// the self-describing branch — `NSError` describes itself — and print `userInfo`.
    func testFoundationBridgedErrorStructsTakeTheNSErrorPath() throws {
        XCTAssertTrue(BoundedDescription.isNSErrorBacked(URLError(.timedOut)))
        XCTAssertTrue(BoundedDescription.isNSErrorBacked(CocoaError(.fileNoSuchFile)))
        // Empty userInfo: Foundation's own text follows (round 4).
        XCTAssertTrue(BoundedDescription.of(error: URLError(.timedOut)).hasPrefix("NSURLErrorDomain -1001: "))
        XCTAssertTrue(BoundedDescription.of(error: CocoaError(.fileNoSuchFile)).hasPrefix("NSCocoaErrorDomain 4: "))
    }

    /// `type(of:) is NSError.Type` must be false for a Swift error that is merely bridgeable.
    func testTheNSErrorPredicateRejectsBridgedSwiftErrors() {
        XCTAssertTrue(BoundedDescription.isNSErrorBacked(NSError(domain: "a", code: 1)))
        XCTAssertFalse(BoundedDescription.isNSErrorBacked(CheckoutError.declined(code: 1, reason: "x")))
        XCTAssertFalse(BoundedDescription.isNSErrorBacked(Failure(field: 1, name: "x")))
        XCTAssertFalse(BoundedDescription.isNSErrorBacked(ClassError()))
    }

    func testASwiftEnumErrorKeepsSwiftsDefaultShapeWithItsValues() {
        XCTAssertEqual(
            BoundedDescription.of(error: CheckoutError.declined(code: 51, reason: "insufficient_funds")),
            #"declined(code: 51, reason: "insufficient_funds")"#
        )
        XCTAssertEqual(
            BoundedDescription.of(error: CheckoutError.nested(inner: ["a": 1], retry: 5, tags: ["t"])),
            #"nested(inner: ["a": 1], retry: 5, tags: ["t"])"#,
            "Optional unwrapped; Swift collections walked"
        )
    }

    /// Proves the enum takes the bounded walk, not `String(describing:)`: the cyclic payload prints
    /// as a placeholder (and `describing` would have overflowed the stack).
    func testAnEnumCarryingACyclicDictionaryPrintsAPlaceholder() {
        let description = BoundedDescription.of(error: ContextError.withContext(cyclicDictionary()))
        XCTAssertTrue(description.hasPrefix("withContext(<"), description)
        XCTAssertTrue(description.hasSuffix(">)"), description)
    }

    func testStructClassAndSelfDescribingErrors() {
        XCTAssertEqual(BoundedDescription.of(error: Failure(field: 1, name: "x")), #"Failure(field: 1, name: "x")"#)
        XCTAssertTrue(BoundedDescription.of(error: ClassError()).hasSuffix("ClassError"))
        XCTAssertEqual(BoundedDescription.of(error: DescribedError()), "described by the host")
    }

    // MARK: - MF1: cyclic and opaque attribute values

    func testACyclicDictionaryAttributeAtTheTopLevelIsBoundedByDepth() throws {
        let result = props(["ctx": cyclicDictionary()])

        let level0 = try XCTUnwrap(result["ctx"] as? [String: Any])
        let level1 = try XCTUnwrap(level0["self"] as? [String: Any])
        let level2 = try XCTUnwrap(level1["self"] as? [String: Any])
        XCTAssertEqual(level2["self"] as? String, "<dictionary of 1>")
        XCTAssertNoThrow(try JSONEncoder().encode(result.mapValues { AnyCodable($0) }))
    }

    func testACyclicDictionaryAtTheDepthCapIsAPlaceholderNotADescription() throws {
        let result = props(["deep": [[[cyclicDictionary()]]] as [Any]])

        let level0 = try XCTUnwrap(result["deep"] as? [Any])
        let level1 = try XCTUnwrap(level0.first as? [Any])
        let level2 = try XCTUnwrap(level1.first as? [Any])
        XCTAssertEqual(level2.first as? String, "<dictionary of 1>")
        XCTAssertEqual(props(["deep": [[[[1, 2, 3]]]] as [Any]]).description.contains("<array of 3>"), true)
    }

    func testOpaqueObjectsAndStructsHoldingThemArePlaceholders() throws {
        let result = props([
            "object": Opaque(),
            "keyed": NSDictionary(dictionary: [1: "x"]),
            "holder": Holder(context: cyclicDictionary()),
            "maybe": Optional<String>.some("unwrapped") as Any,
            "none": Optional<String>.none as Any,
        ])

        XCTAssertEqual((result["object"] as? String)?.hasSuffix("Opaque>"), true)
        XCTAssertEqual((result["keyed"] as? String)?.hasPrefix("<"), true)
        let holder = try XCTUnwrap(result["holder"] as? String)
        XCTAssertTrue(holder.hasPrefix("Holder(context: <"), holder)
        XCTAssertEqual(result["maybe"] as? String, "unwrapped")
        XCTAssertTrue(result["none"] is NSNull)
    }

    // MARK: - MF2: a global size budget

    /// The reviewer's vector: 50×50×50 strings of 500 characters, each within every per-value cap,
    /// encoded to 62.8 MB before the budget.
    func testTheCubeVectorStaysUnderTheBudget() throws {
        let leaf = String(repeating: "x", count: 500)
        let cube = Array(repeating: Array(repeating: Array(repeating: leaf, count: 50), count: 50), count: 50)

        let result = props(["payload": cube, "z_after": "dropped too"])

        XCTAssertNil(result["payload"], "an attribute that does not fit is dropped whole")
        XCTAssertNil(result["z_after"], "and so is everything after it")
        XCTAssertEqual(result["attributes_truncated"] as? Bool, true)
        let bytes = try encodedEventBytes(result)
        print("captureError cube-vector full event: \(bytes) bytes")
        XCTAssertLessThan(bytes, 32 * 1024)
    }

    /// Every reserved string at its cap in control characters (6 bytes each once JSON-escaped),
    /// plus both counters at `Int.max`, merged with `attributes`.
    private func worstCase(attributes: [String: Any]) -> [String: Any] {
        let control = String(repeating: "\u{1}", count: 600)
        let error = NSError(domain: control, code: Int.min, userInfo: [NSLocalizedDescriptionKey: control])
        var result = SheepitClient.errorCaptureProperties(
            reserved: SheepitClient.errorCaptureReservedProperties(message: control, error: error),
            attributes: attributes
        )
        result["suppressed_count"] = Int.max
        result["dropped_count"] = Int.max
        return result
    }

    /// Flat worst case: 60 attributes, 64-character control-character keys and values.
    func testTheFlatWorstCaseFullEventFitsTheServersPerEventCap() throws {
        let control = String(repeating: "\u{1}", count: 600)
        var attributes: [String: Any] = [:]
        for index in 0..<60 {
            attributes[String(format: "%02d", index) + control] = control
        }
        let result = worstCase(attributes: attributes)

        let bytes = try encodedEventBytes(result)
        print("captureError worst-case full event: \(bytes) bytes")

        XCTAssertEqual(result["attributes_truncated"] as? Bool, true)
        XCTAssertLessThan(bytes, 32 * 1024, "the server rejects an event over 32 KB")
        XCTAssertLessThan(bytes, 24 * 1024, "headroom for experiment assignments in the context")
    }

    /// Nested worst case: many small nested attributes (`/` costs 2 bytes escaped), sized so the
    /// byte budget, not the leaf budget, is what fills — plus the worst-case reserved strings.
    func testTheNestedWorstCaseFullEventFitsTheServersPerEventCap() throws {
        let slashes = String(repeating: "/", count: 40)
        var attributes: [String: Any] = [:]
        for index in 0..<50 {
            attributes[String(format: "k%02d", index)] = [[slashes, slashes], ["n": [slashes, slashes]]] as [Any]
        }

        let result = worstCase(attributes: attributes)
        let bytes = try encodedEventBytes(result)
        print("captureError nested worst-case full event: \(bytes) bytes")

        XCTAssertEqual(result["attributes_truncated"] as? Bool, true, "precondition: the budget filled")
        XCTAssertLessThan(bytes, 32 * 1024)
        XCTAssertLessThan(bytes, 24 * 1024, "headroom for experiment assignments in the context")
    }

    func testTheLeafBudgetBoundsManySmallValues() throws {
        var attributes: [String: Any] = [:]
        for index in 0..<10 { attributes["k\(index)"] = Array(0..<50) }

        let result = props(attributes)

        let kept = result.keys.filter { $0.hasPrefix("k") }.count
        XCTAssertEqual(kept, ErrorAttributeSanitizer.maxLeaves / 50, "200 leaves: four 50-element arrays")
        XCTAssertEqual(result["attributes_truncated"] as? Bool, true)
    }

    func testAttributesWithinTheBudgetAreNotMarkedTruncated() {
        let result = props(["a": 1, "b": "two"])
        XCTAssertNil(result["attributes_truncated"])
        XCTAssertEqual(result["a"] as? Int, 1)
    }

    func testDroppingAttributesPastThe50CapSetsTruncated() {
        var attributes: [String: Any] = [:]
        for index in 0..<51 { attributes[String(format: "k%02d", index)] = index }
        XCTAssertEqual(props(attributes)["attributes_truncated"] as? Bool, true)
    }

    func testACallerCannotSetAttributesTruncatedItself() {
        let result = props(["attributes_truncated": false])
        XCTAssertNil(result["attributes_truncated"])
        XCTAssertEqual(result["attr_attributes_truncated"] as? Bool, false)
    }

    // MARK: - MF3: keys are bounded

    func testAHugeKeyIsCutTo64Characters() throws {
        let key = String(repeating: "k", count: 100_000)

        let result = props([key: "v"])

        let kept = try XCTUnwrap(result.keys.first { $0.hasPrefix("k") })
        XCTAssertEqual(kept.count, ErrorAttributeSanitizer.maxKeyLength)
        XCTAssertEqual(result[kept] as? String, "v")
    }

    func testKeysThatCollideAfterTruncationKeepTheFirstInSortedOrder() {
        let stem = String(repeating: "k", count: 64)

        let result = props([stem + "b": "second", stem + "a": "first"])

        XCTAssertEqual(result[stem] as? String, "first")
        XCTAssertEqual(result.keys.filter { $0.hasPrefix("k") }.count, 1)
    }

    func testEveryKeyStaysWithinTheBoundIncludingRenamedAndNestedOnes() {
        let long = String(repeating: "n", count: 500)
        let result = props(["message": "renamed", long: [long: 1]])

        XCTAssertEqual(result["attr_message"] as? String, "renamed")
        for key in result.keys { XCTAssertLessThanOrEqual(key.count, ErrorAttributeSanitizer.maxKeyLength) }
        let nested = result.values.compactMap { $0 as? [String: Any] }.first
        XCTAssertEqual(nested?.keys.first?.count, ErrorAttributeSanitizer.maxKeyLength)
    }

    // MARK: - SF7: an async hop through onEvent is bounded by the global cap

    func testAnAsyncHopFromOnEventIsBoundedByTheGlobalCap() async {
        let clientBox = LockedBox<SheepitClient?>(nil)
        let (client, events) = makeClient { name, _ in
            guard name == "$error" else { return }
            // A unique message every hop, so only the global cap — not the dedup window — can stop it.
            DispatchQueue.global().async { clientBox.get()?.captureError("hop \(UUID().uuidString)") }
        }
        clientBox.set(client)
        defer { clientBox.set(nil); client.destroy() }

        client.captureError("hop 0")

        // The chain ends itself once the cap stops sending: no send, no onEvent, no next hop.
        var stableFor = 0
        var last = -1
        while stableFor < 20 {
            try? await Task.sleep(for: .milliseconds(10))
            let now = errors(events).count
            stableFor = now == last ? stableFor + 1 : 0
            last = now
        }
        XCTAssertEqual(errors(events).count, ErrorCaptureLimiter.globalCap)
    }
}
