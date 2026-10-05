import XCTest
@testable import SheepitKit

/// PR #1173 review round 3: `localizedDescription` itself crashed the host — a cyclic dictionary
/// under `NSLocalizedFailureReasonErrorKey` (stack overflow) and a non-string under
/// `NSLocalizedDescriptionKey` (uncaught `NSInvalidArgumentException`, `-length` sent to a
/// non-string). Every fixture here puts its hazard under a key Foundation actually reads, and each
/// test was confirmed to crash or fail with the `localizedDescription` call restored (PR body,
/// "Round 3"). A crash in these tests is the regression, not flakiness.
final class CaptureErrorRound3Tests: XCTestCase {
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

    private func cyclicDictionary() -> NSMutableDictionary {
        let dictionary = NSMutableDictionary()
        dictionary["self"] = dictionary
        return dictionary
    }

    private func description(_ userInfo: [String: Any], domain: String = "d", code: Int = 1) -> String {
        BoundedDescription.of(error: NSError(domain: domain, code: code, userInfo: userInfo))
    }

    private func makeClient() -> (SheepitClient, LockedBox<[[String: Any]]>) {
        let sent = LockedBox<[[String: Any]]>([])
        var config = SheepitConfig(
            apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))",
            apiUrl: "http://127.0.0.1:1",
            // Loopback port 1 refuses at once (no DNS lookup), and one attempt skips the 1 s / 5 s
            // backoff — so the final flush `destroy()` starts settles before `tearDown` drains it.
            retryAttempts: 1,
            crashes: CrashConfig(enabled: false)
        )
        config.onEvent = { @Sendable name, properties in
            if name == "$error" { sent.mutate { $0.append(properties ?? [:]) } }
        }
        return (SheepitClient.constructOnlyForTesting(config: config), sent)
    }

    // MARK: - Cycles under the keys Foundation composes from

    func testACyclicFailureReasonDoesNotOverflowTheStack() {
        XCTAssertEqual(description([NSLocalizedFailureReasonErrorKey: cyclicDictionary()]), "d 1")
    }

    func testACyclicDescriptionValueDoesNotOverflowTheStack() {
        XCTAssertEqual(description([NSLocalizedDescriptionKey: cyclicDictionary()]), "d 1")
    }

    // MARK: - Non-strings under NSLocalizedDescriptionKey (no cycle needed)

    func testANumberUnderTheDescriptionKeyDoesNotRaise() {
        XCTAssertEqual(description([NSLocalizedDescriptionKey: NSNumber(value: 7)]), "d 1")
    }

    func testAnArrayUnderTheDescriptionKeyDoesNotRaise() {
        XCTAssertEqual(description([NSLocalizedDescriptionKey: ["a", "b"]]), "d 1")
    }

    func testADictionaryUnderTheDescriptionKeyDoesNotRaise() {
        XCTAssertEqual(description([NSLocalizedDescriptionKey: ["k": "v"]]), "d 1")
    }

    // MARK: - The same hazards through Foundation's bridged error structs

    func testAURLErrorWithACyclicFailureReasonDoesNotOverflowTheStack() {
        let error = URLError(.notConnectedToInternet, userInfo: [NSLocalizedFailureReasonErrorKey: cyclicDictionary()])
        XCTAssertEqual(BoundedDescription.of(error: error), "NSURLErrorDomain -1009")
    }

    func testAURLErrorWithANumberDescriptionDoesNotRaise() {
        let error = URLError(.notConnectedToInternet, userInfo: [NSLocalizedDescriptionKey: NSNumber(value: 7)])
        XCTAssertEqual(BoundedDescription.of(error: error), "NSURLErrorDomain -1009")
    }

    func testEveryHazardThroughThePublicAPI() {
        let (client, sent) = makeClient()
        defer { client.destroy() }

        client.captureError("a", error: NSError(domain: "d", code: 1, userInfo: [NSLocalizedFailureReasonErrorKey: cyclicDictionary()]))
        client.captureError("b", error: NSError(domain: "d", code: 1, userInfo: [NSLocalizedDescriptionKey: NSNumber(value: 7)]))
        client.captureError("c", error: URLError(.badURL, userInfo: [NSLocalizedFailureReasonErrorKey: cyclicDictionary()]))

        XCTAssertEqual(sent.get().compactMap { $0["error_description"] as? String }, ["d 1", "d 1", "NSURLErrorDomain -1000"])
    }

    // MARK: - userInfo is read by key, never described

    func testANonCyclicDictionaryFailureReasonNeverAppears() {
        let text = description([NSLocalizedFailureReasonErrorKey: ["token": "secret-value-123"]])
        XCTAssertEqual(text, "d 1")
        XCTAssertFalse(text.contains("secret-value-123"))
    }

    func testOtherUserInfoKeysNeverAppear() {
        let text = description([
            NSLocalizedDescriptionKey: "Upload failed",
            NSURLErrorFailingURLStringErrorKey: "https://example.com/upload?token=secret-value-123",
            NSUnderlyingErrorKey: NSError(domain: "inner", code: 2),
        ])
        XCTAssertEqual(text, "d 1: Upload failed")
    }

    func testTheDescriptionStringWinsOverTheFailureReason() {
        XCTAssertEqual(
            description([NSLocalizedDescriptionKey: "Boom", NSLocalizedFailureReasonErrorKey: "Because"]),
            "d 1: Boom"
        )
    }

    func testAFailureReasonStringIsTheFallback() {
        XCTAssertEqual(description([NSLocalizedFailureReasonErrorKey: "Because"]), "d 1: Because")
        XCTAssertEqual(
            description([NSLocalizedDescriptionKey: NSNumber(value: 7), NSLocalizedFailureReasonErrorKey: "Because"]),
            "d 1: Because",
            "a non-string description is skipped, not stringified"
        )
    }

    /// Round 4 (founder decision 2026-10-02): an EMPTY `userInfo` gets Foundation's text back —
    /// with nothing in `userInfo`, `localizedDescription` has nothing to trip on.
    func testARealNotConnectedURLErrorCarriesFoundationsText() {
        let error = URLError(.notConnectedToInternet)
        let text = BoundedDescription.of(error: error)
        XCTAssertTrue(text.hasPrefix("NSURLErrorDomain -1009: "), text)
        XCTAssertGreaterThan(text.count, "NSURLErrorDomain -1009: ".count)
        let reserved = SheepitClient.errorCaptureReservedProperties(message: "offline", error: error)
        XCTAssertEqual(reserved["error_domain"] as? String, "NSURLErrorDomain")
        XCTAssertEqual(reserved["error_code"] as? Int, -1009)
    }

    func testEachTextPartIsBounded() {
        let long = String(repeating: "x", count: 5_000)
        let text = description([NSLocalizedDescriptionKey: long], domain: long)
        XCTAssertEqual(text.count, SheepitClient.errorCaptureMaxStringLength)
    }

    // MARK: - LOW-1: bound before the regex

    /// Round 4: cut to 4 KB, strip, THEN cut to 500 — a name whose address straddles the
    /// 500-character mark loses the whole address instead of keeping half of it.
    func testTheDomainIsStrippedBeforeItIsCutToLength() throws {
        let domain = String(repeating: "a", count: 490) + "(unknown context at $10a3c47d8).Name"
        let reserved = SheepitClient.errorCaptureReservedProperties(message: "m", error: NSError(domain: domain, code: 1))

        let kept = try XCTUnwrap(reserved["error_domain"] as? String)
        XCTAssertEqual(kept, String(repeating: "a", count: 490) + "Name")
        XCTAssertFalse(kept.contains("unknown context"))
    }

    func testAHugeDomainIsStillBoundedCheaply() throws {
        let domain = String(repeating: "d", count: 5_000_000)
        let reserved = SheepitClient.errorCaptureReservedProperties(message: "m", error: NSError(domain: domain, code: 1))
        XCTAssertEqual((reserved["error_domain"] as? String)?.count, SheepitClient.errorCaptureMaxStringLength)
    }

    // MARK: - mobile-reviewer SF-1: the self-describing check is a metatype check

    private struct Described: Error, CustomStringConvertible { var description: String { "described" } }
    private struct DebugDescribed: Error, CustomDebugStringConvertible { var debugDescription: String { "debug-described" } }
    private enum Plain: Error { case broken(code: Int) }
    private struct PlainStruct: Error { let code: Int }
    private final class PlainClass: Error {}

    func testSelfDescribingErrorsUseTheirOwnDescriptionVerbatim() {
        XCTAssertEqual(BoundedDescription.of(error: Described()), "described")
        XCTAssertEqual(BoundedDescription.of(error: DebugDescribed()), "debug-described")
    }

    func testPlainSwiftErrorsTakeTheBoundedWalk() {
        XCTAssertEqual(BoundedDescription.of(error: Plain.broken(code: 3)), "broken(code: 3)")
        XCTAssertEqual(BoundedDescription.of(error: PlainStruct(code: 3)), "PlainStruct(code: 3)")
        XCTAssertTrue(BoundedDescription.of(error: PlainClass()).hasSuffix("PlainClass"))
    }

    // MARK: - sdk-auditor MF-A: no frozen `platform` property

    /// SheepitKit also runs on macOS, tvOS and watchOS; a hard-coded `platform: "ios"` would be
    /// wrong there forever. The platform and OS come from the event context instead.
    func testACapturedErrorCarriesNoPlatformProperty() throws {
        let (client, sent) = makeClient()
        defer { client.destroy() }

        client.captureError("no platform", error: NSError(domain: "d", code: 1))

        let props = try XCTUnwrap(sent.get().first)
        XCTAssertNil(props["platform"])
    }

    func testACallerSuppliedPlatformPassesThroughUnrenamed() {
        let result = SheepitClient.errorCaptureProperties(
            reserved: SheepitClient.errorCaptureReservedProperties(message: "m", error: nil),
            attributes: ["platform": "visionos"]
        )
        XCTAssertEqual(result["platform"] as? String, "visionos")
        XCTAssertNil(result["attr_platform"])
    }

    // MARK: - SF-1: work is independent of container size

    /// Round 4: an oversized nested dictionary keeps its 50 smallest keys (round 3 replaced it
    /// with a placeholder).
    func testAnOversizedNestedDictionaryKeepsIts50SmallestKeysAndMarksTruncation() throws {
        var big: [String: Int] = [:]
        for index in 0..<10_000 { big["k\(index)"] = index }

        let result = SheepitClient.errorCaptureProperties(reserved: [:], attributes: ["big": big, "small": ["a": 1]])

        let kept = try XCTUnwrap(result["big"] as? [String: Any])
        XCTAssertEqual(kept.keys.sorted(), Array(big.keys.sorted().prefix(50)))
        XCTAssertEqual(kept["k0"] as? Int, 0)
        XCTAssertEqual((result["small"] as? [String: Any])?["a"] as? Int, 1)
        XCTAssertEqual(result["attributes_truncated"] as? Bool, true)
    }

    func testAnOversizedNestedArrayKeepsItsFirst50AndMarksTruncation() throws {
        let result = SheepitClient.errorCaptureProperties(reserved: [:], attributes: ["list": Array(0..<10_000)])

        let list = try XCTUnwrap(result["list"] as? [Any])
        XCTAssertEqual(list.count, ErrorAttributeSanitizer.maxNestedElements)
        XCTAssertEqual(list.last as? Int, 49)
        XCTAssertEqual(result["attributes_truncated"] as? Bool, true)
    }

    func testFoundationCollectionsAreReadWithoutBridgingCopies() throws {
        let array = NSMutableArray(array: Array(0..<100))
        let dictionary = NSMutableDictionary(dictionary: ["a": 1])
        let result = SheepitClient.errorCaptureProperties(reserved: [:], attributes: ["array": array, "dict": dictionary])

        XCTAssertEqual((result["array"] as? [Any])?.count, 50)
        XCTAssertEqual((result["dict"] as? [String: Any])?["a"] as? Int, 1)
    }

    /// `as Bool` claims every `NSNumber` that is 0 or 1; a JSON-decoded `1` must stay a number.
    func testFoundationNumbersKeepTheirKind() throws {
        let decoded = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(#"{"one":1,"zero":0,"flag":true,"half":0.5,"big":18446744073709551615}"#.utf8))
                as? [String: Any]
        )
        let result = SheepitClient.errorCaptureProperties(reserved: [:], attributes: ["json": decoded])

        let json = try XCTUnwrap(result["json"] as? [String: Any])
        XCTAssertEqual(json["one"] as? Int, 1)
        XCTAssertFalse(json["one"] is Bool)
        XCTAssertEqual(json["zero"] as? Int, 0)
        XCTAssertEqual(json["flag"] as? Bool, true)
        XCTAssertEqual(json["half"] as? Double, 0.5)
        XCTAssertEqual(json["big"] as? String, "18446744073709551615")
    }

    /// The single-pass selection must pick exactly what a full sort would.
    func testSmallestKeysMatchesAFullSort() {
        var generator = SystemRandomNumberGenerator()
        for size in [0, 1, 49, 50, 51, 500] {
            let keys = (0..<size).map { _ in String(UInt64.random(in: 0...UInt64.max, using: &generator), radix: 36) }
            XCTAssertEqual(
                ErrorAttributeSanitizer.smallestKeys(Set(keys), limit: 50),
                Array(Set(keys).sorted().prefix(50)),
                "size \(size)"
            )
        }
        let descending = (0..<200).map { String(format: "k%03d", 199 - $0) }
        XCTAssertEqual(ErrorAttributeSanitizer.smallestKeys(descending, limit: 50), Array(descending.sorted().prefix(50)))
    }
}
