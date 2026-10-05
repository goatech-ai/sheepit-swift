import XCTest
@testable import SheepitKit

/// PR #1173 review round 5: the empty-`userInfo` branch still reached host code. A
/// `NSError.setUserInfoValueProvider(forDomain:)` provider's values are NOT in the CF `userInfo`
/// count, and `localizedDescription` calls it; an `NSError` subclass can override
/// `localizedDescription` itself. Foundation is now asked only when the count is 0, the class
/// overrides neither `localizedDescription` nor `localizedFailureReason` relative to `NSError`,
/// and the domain is one of Foundation's own or has no provider registered.
///
/// 🔴 Provider registration is PROCESS-GLOBAL: every test uses its own domain and unregisters it
/// in a `defer`. A crash here is the regression (mutation evidence: PR body, "Round 5").
final class CaptureErrorProviderGuardTests: XCTestCase {
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

    private func uniqueDomain() -> String { "ai.sheepit.tests.provider-guard.\(UUID().uuidString)" }

    private func cyclicDictionary() -> NSMutableDictionary {
        let dictionary = NSMutableDictionary()
        dictionary["self"] = dictionary
        return dictionary
    }

    private func withProvider(
        _ provider: @escaping (Error, String) -> Any?,
        _ body: (String) -> Void
    ) {
        let domain = uniqueDomain()
        NSError.setUserInfoValueProvider(forDomain: domain, provider: provider)
        defer { NSError.setUserInfoValueProvider(forDomain: domain, provider: nil) }
        body(domain)
    }

    // MARK: - Guard (c): a custom domain's provider is never reached

    func testAProviderReturningANumberIsNeverReached() {
        let calls = LockedBox(0)
        withProvider({ _, key in
            calls.mutate { $0 += 1 }
            return key == NSLocalizedDescriptionKey ? NSNumber(value: 7) : nil
        }) { domain in
            XCTAssertEqual(BoundedDescription.of(error: NSError(domain: domain, code: 1)), "\(domain) 1")
        }
        XCTAssertEqual(calls.get(), 0)
    }

    func testAProviderReturningACyclicDictionaryIsNeverReached() {
        let calls = LockedBox(0)
        let cycle = cyclicDictionary()
        withProvider({ _, key in
            calls.mutate { $0 += 1 }
            return key == NSLocalizedFailureReasonErrorKey ? cycle : nil
        }) { domain in
            XCTAssertEqual(BoundedDescription.of(error: NSError(domain: domain, code: 1)), "\(domain) 1")
        }
        XCTAssertEqual(calls.get(), 0)
    }

    /// The provider raises on any call; the assertion is the call counter, not the crash.
    func testARaisingProviderIsNeverCalled() {
        let calls = LockedBox(0)
        withProvider({ _, _ in
            calls.mutate { $0 += 1 }
            NSException(name: .invalidArgumentException, reason: "provider raised", userInfo: nil).raise()
            return nil
        }) { domain in
            XCTAssertEqual(BoundedDescription.of(error: NSError(domain: domain, code: 1)), "\(domain) 1")
        }
        XCTAssertEqual(calls.get(), 0)
    }

    /// Accepted loss: a provider's well-formed text is not shown either.
    func testAProviderReturningARealStringStillGetsTheSafeFallback() {
        let calls = LockedBox(0)
        withProvider({ _, key in
            calls.mutate { $0 += 1 }
            return key == NSLocalizedDescriptionKey ? "provider text" : nil
        }) { domain in
            XCTAssertEqual(BoundedDescription.of(error: NSError(domain: domain, code: 1)), "\(domain) 1")
        }
        XCTAssertEqual(calls.get(), 0)
    }

    func testThroughThePublicAPI() throws {
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
        let client = SheepitClient.constructOnlyForTesting(config: config)
        defer { client.destroy() }

        withProvider({ _, key in key == NSLocalizedDescriptionKey ? NSNumber(value: 7) : nil }) { domain in
            client.captureError("provider", error: NSError(domain: domain, code: 3))
            XCTAssertEqual(sent.get().first?["error_description"] as? String, "\(domain) 3")
        }
    }

    // MARK: - Guard (b): no override of localizedDescription / localizedFailureReason

    private final class RecursiveDescriptionError: NSError, @unchecked Sendable {
        override var localizedDescription: String { recurse() }
        private func recurse() -> String { localizedDescription }
    }

    private final class RecursiveFailureReasonError: NSError, @unchecked Sendable {
        override var localizedFailureReason: String? { recurse() }
        private func recurse() -> String? { localizedFailureReason }
    }

    func testARecursiveLocalizedDescriptionOverrideIsNeverCalled() {
        let domain = uniqueDomain()
        XCTAssertEqual(BoundedDescription.of(error: RecursiveDescriptionError(domain: domain, code: 1)), "\(domain) 1")
    }

    func testARecursiveLocalizedFailureReasonOverrideIsNeverCalled() {
        let domain = uniqueDomain()
        XCTAssertEqual(BoundedDescription.of(error: RecursiveFailureReasonError(domain: domain, code: 1)), "\(domain) 1")
    }

    /// The toll-free CF class must not count as an override, or no `CFError` would get text.
    func testACFErrorPassesTheOverrideCheck() throws {
        let domain = uniqueDomain()
        let error = try XCTUnwrap(CFErrorCreate(kCFAllocatorDefault, domain as CFString, 5, nil))
        let text = BoundedDescription.of(error: error)
        XCTAssertTrue(text.hasPrefix("\(domain) 5: "), text)
    }

    // MARK: - Round 6: only NSCocoaErrorDomain is trusted with a provider registered

    /// Founder decision in practice, unarmed: Cocoa and URL carry Foundation's text, POSIX
    /// carries `strerror_r`'s, OSStatus/Mach (Foundation-registered provider, not trusted) none.
    func testWhatFoundationsOwnDomainsCarryUnarmed() {
        XCTAssertTrue(BoundedDescription.of(error: CocoaError(.fileNoSuchFile)).hasPrefix("NSCocoaErrorDomain 4: "))
        XCTAssertTrue(BoundedDescription.of(error: CocoaError(.fileReadNoPermission)).hasPrefix("NSCocoaErrorDomain 257: "))
        XCTAssertEqual(BoundedDescription.of(error: POSIXError(.ENOENT)), "NSPOSIXErrorDomain 2: No such file or directory")
        XCTAssertTrue(BoundedDescription.of(error: URLError(.notConnectedToInternet)).hasPrefix("NSURLErrorDomain -1009: "))
        XCTAssertEqual(BoundedDescription.of(error: NSError(domain: NSOSStatusErrorDomain, code: -50)), "NSOSStatusErrorDomain -50")
        XCTAssertEqual(BoundedDescription.of(error: NSError(domain: NSMachErrorDomain, code: 5)), "NSMachErrorDomain 5")
    }

    /// Arms a provider on one of Foundation's own domains and puts the original back (Foundation
    /// registers its own on POSIX, OSStatus and Mach; none on URL or CFNetwork). Cocoa refuses a
    /// replacement, so it cannot be armed and is not tested here.
    private func armed(_ domain: String, _ body: () -> Void) -> Int {
        let original = NSError.userInfoValueProvider(forDomain: domain)
        let calls = LockedBox(0)
        NSError.setUserInfoValueProvider(forDomain: domain) { _, key in
            calls.mutate { $0 += 1 }
            return key == NSLocalizedDescriptionKey ? NSNumber(value: 7) : nil
        }
        defer { NSError.setUserInfoValueProvider(forDomain: domain, provider: original) }
        body()
        return calls.get()
    }

    func testAnArmedURLDomainProviderIsNeverCalled() {
        let calls = armed(NSURLErrorDomain) {
            XCTAssertEqual(BoundedDescription.of(error: URLError(.notConnectedToInternet)), "NSURLErrorDomain -1009")
        }
        XCTAssertEqual(calls, 0)
    }

    func testAnArmedPOSIXDomainProviderIsNeverCalled() {
        let calls = armed(NSPOSIXErrorDomain) {
            XCTAssertEqual(BoundedDescription.of(error: POSIXError(.ENOENT)), "NSPOSIXErrorDomain 2: No such file or directory")
        }
        XCTAssertEqual(calls, 0)
    }

    func testAnArmedOSStatusDomainProviderIsNeverCalled() {
        let calls = armed(NSOSStatusErrorDomain) {
            XCTAssertEqual(BoundedDescription.of(error: NSError(domain: NSOSStatusErrorDomain, code: -50)), "NSOSStatusErrorDomain -50")
        }
        XCTAssertEqual(calls, 0)
    }

    func testAnArmedMachDomainProviderIsNeverCalled() {
        let calls = armed(NSMachErrorDomain) {
            XCTAssertEqual(BoundedDescription.of(error: NSError(domain: NSMachErrorDomain, code: 5)), "NSMachErrorDomain 5")
        }
        XCTAssertEqual(calls, 0)
    }

    func testAnArmedCFNetworkDomainProviderIsNeverCalled() {
        let domain = kCFErrorDomainCFNetwork as String
        let calls = armed(domain) {
            XCTAssertEqual(BoundedDescription.of(error: NSError(domain: domain, code: 1)), "\(domain) 1")
        }
        XCTAssertEqual(calls, 0)
    }

    func testPOSIXTextIsBoundedToValidCodes() {
        XCTAssertNil(BoundedDescription.posixText(0))
        XCTAssertNil(BoundedDescription.posixText(-1))
        XCTAssertNil(BoundedDescription.posixText(Int(Int32.max) + 1))
        XCTAssertEqual(BoundedDescription.posixText(2), "No such file or directory")
    }

    // MARK: - NSObject-rooted error classes never describe themselves (round 6)

    private final class ListError: NSMutableArray, Error, @unchecked Sendable {}
    private final class TextError: NSString, Error, @unchecked Sendable {}
    private final class DataError: NSData, Error, @unchecked Sendable {}
    private final class ValueError: NSValue, Error, @unchecked Sendable {}
    private final class DateError: NSDate, Error, @unchecked Sendable {}
    private final class IndexError: NSIndexSet, Error, @unchecked Sendable {}

    /// Foundation's `description` for an abstract class-cluster subclass raises "only defined for
    /// abstract class", and `NSIndexSet`'s prints an address. Every one reports its type name.
    func testFoundationSubclassErrorsReportTheirTypeName() {
        let cases: [(Error, String)] = [
            (ListError(), "ListError"), (TextError(), "TextError"), (DataError(), "DataError"),
            (ValueError(), "ValueError"), (DateError(), "DateError"), (IndexError(), "IndexError"),
        ]
        for (error, name) in cases {
            let text = BoundedDescription.of(error: error)
            XCTAssertTrue(text.hasSuffix(name), text)
            XCTAssertFalse(text.contains("0x"), text)
        }
    }
}
