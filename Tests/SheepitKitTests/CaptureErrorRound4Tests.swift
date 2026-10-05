import XCTest
@testable import SheepitKit

/// PR #1173 review round 4: reading `NSError.userInfo` from Swift aborts on a non-string KEY, an
/// `NSObject`-rooted error class printed `<Type: 0x…>` through `NSObject.description`, and the
/// founder decision to restore Foundation's text when `userInfo` is empty. A crash in these tests
/// is the regression, not flakiness (mutation evidence: PR body, "Round 4").
final class CaptureErrorRound4Tests: XCTestCase {
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

    /// A `CFError` is toll-free bridged to `NSError`, and CoreFoundation accepts any key — this is
    /// how a non-string key reaches a host's error without any private API.
    private func errorWithNumberKey(description: String? = "Boom") -> Error {
        var info: [AnyHashable: Any] = [NSNumber(value: 1): "x"]
        if let description { info[NSLocalizedDescriptionKey] = description }
        return CFErrorCreate(kCFAllocatorDefault, "d" as CFString, 1, NSDictionary(dictionary: info) as CFDictionary)!
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

    private func cyclicDictionary() -> NSMutableDictionary {
        let dictionary = NSMutableDictionary()
        dictionary["self"] = dictionary
        return dictionary
    }

    // MARK: - MF-1: a non-string userInfo key must not abort the process

    func testANonStringUserInfoKeyIsReadThroughCoreFoundation() {
        XCTAssertEqual(BoundedDescription.of(error: errorWithNumberKey()), "d 1: Boom")
    }

    func testANonStringKeyWithNoDescriptionStillTakesTheSafePath() {
        XCTAssertEqual(BoundedDescription.of(error: errorWithNumberKey(description: nil)), "d 1")
    }

    func testANonStringUserInfoKeyThroughThePublicAPI() throws {
        let (client, sent) = makeClient()
        defer { client.destroy() }

        client.captureError("number key", error: errorWithNumberKey())

        let props = try XCTUnwrap(sent.get().first)
        XCTAssertEqual(props["error_description"] as? String, "d 1: Boom")
        XCTAssertEqual(props["error_domain"] as? String, "d")
        XCTAssertEqual(props["error_code"] as? Int, 1)
    }

    // MARK: - MF-2: NSObject-rooted error classes

    private final class PlainObjectError: NSObject, Error {}

    private final class DescribedObjectError: NSObject, Error {
        override var description: String { "described object" }
    }

    private final class DebugDescribedObjectError: NSObject, Error {
        override var debugDescription: String { "debug-described object" }
    }

    private class DescribedBase: NSObject, Error {
        override var description: String { "from the base" }
    }

    private final class InheritsDescription: DescribedBase {}

    private final class SwiftDescribedError: Error, CustomStringConvertible {
        var description: String { "swift-described class" }
    }

    private final class SwiftPlainError: Error {}

    func testAnNSObjectErrorWithoutAnOverrideIsItsTypeNameWithNoAddress() {
        let text = BoundedDescription.of(error: PlainObjectError())
        XCTAssertTrue(text.hasSuffix("PlainObjectError"), text)
        XCTAssertFalse(text.contains("0x"), "NSObject's inherited description carries a per-launch address")
        XCTAssertFalse(text.contains("unknown context"))
    }

    /// Round 6: an `NSObject`-rooted error never describes itself, override or not — the override
    /// detection could not cover every Foundation base (NSData / NSNumber / NSValue / NSDate raise,
    /// NSIndexSet prints an address), and an override can recurse.
    func testAnNSObjectErrorNeverDescribesItselfEvenWithAnOverride() {
        XCTAssertTrue(BoundedDescription.of(error: DescribedObjectError()).hasSuffix("DescribedObjectError"))
        XCTAssertTrue(BoundedDescription.of(error: DebugDescribedObjectError()).hasSuffix("DebugDescribedObjectError"))
        XCTAssertTrue(BoundedDescription.of(error: InheritsDescription()).hasSuffix("InheritsDescription"))
    }

    func testPureSwiftClassErrors() {
        XCTAssertEqual(BoundedDescription.of(error: SwiftDescribedError()), "swift-described class")
        XCTAssertTrue(BoundedDescription.of(error: SwiftPlainError()).hasSuffix("SwiftPlainError"))
    }

    // MARK: - Founder decision: Foundation's text when userInfo is empty

    private func assertCarriesFoundationText(_ error: Error, head: String, file: StaticString = #filePath, line: UInt = #line) {
        let text = BoundedDescription.of(error: error)
        XCTAssertTrue(text.hasPrefix(head + ": "), text, file: file, line: line)
        XCTAssertNotEqual(text, head, file: file, line: line)
        XCTAssertGreaterThan(text.count, head.count + 2, file: file, line: line)
    }

    /// Foundation registers its OWN `userInfo` value provider for `NSCocoaErrorDomain` (and
    /// `NSPOSIXErrorDomain`) — measured — and that provider is where this text comes from, so
    /// Foundation's own domains are trusted by the round-5 provider guard.
    func testCocoaErrorCarriesFoundationsText() {
        XCTAssertNotNil(NSError.userInfoValueProvider(forDomain: NSCocoaErrorDomain), "precondition: measured")
        assertCarriesFoundationText(CocoaError(.fileNoSuchFile), head: "NSCocoaErrorDomain 4")
        assertCarriesFoundationText(CocoaError(.fileReadNoPermission), head: "NSCocoaErrorDomain 257")
    }

    func testURLErrorCarriesFoundationsText() {
        assertCarriesFoundationText(URLError(.notConnectedToInternet), head: "NSURLErrorDomain -1009")
    }

    /// Round 6: POSIX text comes from `strerror_r`, never from Foundation.
    func testPOSIXErrorCarriesItsText() {
        XCTAssertEqual(BoundedDescription.of(error: POSIXError(.ENOENT)), "NSPOSIXErrorDomain 2: No such file or directory")
    }

    func testAPlainNSErrorWithNoUserInfoCarriesFoundationsText() {
        assertCarriesFoundationText(NSError(domain: "com.example", code: 7), head: "com.example 7")
    }

    /// Non-empty `userInfo` never reaches Foundation, whatever the URLError's code.
    func testNonEmptyUserInfoStillTakesTheSafePath() {
        XCTAssertEqual(
            BoundedDescription.of(error: URLError(.notConnectedToInternet, userInfo: [NSLocalizedFailureReasonErrorKey: cyclicDictionary()])),
            "NSURLErrorDomain -1009"
        )
        XCTAssertEqual(
            BoundedDescription.of(error: NSError(domain: "d", code: 1, userInfo: ["unrelated": 1])),
            "d 1",
            "any userInfo at all keeps Foundation out — even keys it would not read"
        )
    }

    // MARK: - SF: Optional-wrapped NSNumber; number widening

    func testAnOptionalWrappedNSNumberKeepsItsKind() throws {
        let one: NSNumber? = NSNumber(value: 1)
        let result = SheepitClient.errorCaptureProperties(reserved: [:], attributes: ["one": one as Any])
        XCTAssertEqual(result["one"] as? Int, 1)
        XCTAssertFalse(result["one"] is Bool)
    }

    func testFloatsAndDecimalsAreSentAsTheirOwnText() {
        let result = SheepitClient.errorCaptureProperties(reserved: [:], attributes: [
            "float": NSNumber(value: Float(1.1)),
            "price": NSDecimalNumber(string: "19.99"),
            "double": NSNumber(value: 1.1),
        ])
        XCTAssertEqual(result["float"] as? String, "1.1", "no widening artifact (1.100000023841858)")
        XCTAssertEqual(result["price"] as? String, "19.99", "money never goes through binary floating point")
        XCTAssertEqual(result["double"] as? Double, 1.1)
    }

    // MARK: - NICE: nested dictionaries keep their 50 smallest keys, any element type

    func testANarrowNestedDictionaryKeepsIts50SmallestKeys() throws {
        var big: [String: Int] = [:]
        for index in 0..<1_000 { big[String(format: "k%04d", index)] = index }
        let foundation = NSMutableDictionary(dictionary: big)

        let result = SheepitClient.errorCaptureProperties(reserved: [:], attributes: ["a": big, "b": foundation])

        let expected = (0..<50).map { String(format: "k%04d", $0) }
        XCTAssertEqual((result["a"] as? [String: Any])?.keys.sorted(), expected)
        XCTAssertEqual((result["b"] as? [String: Any])?.keys.sorted(), expected)
        XCTAssertEqual(result["attributes_truncated"] as? Bool, true)
    }

    func testAFoundationDictionaryWithANonStringKeyKeepsItsStringKeys() throws {
        let mixed = NSDictionary(dictionary: [NSNumber(value: 1): "number key", "name": "kept"] as [AnyHashable: Any])
        let result = SheepitClient.errorCaptureProperties(reserved: [:], attributes: ["mixed": mixed])
        XCTAssertEqual((result["mixed"] as? [String: Any])?["name"] as? String, "kept")
        XCTAssertEqual((result["mixed"] as? [String: Any])?.count, 1)
    }
}
