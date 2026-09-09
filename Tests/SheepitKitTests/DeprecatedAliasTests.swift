import XCTest

// Deliberately NOT `@testable`. The shims exist for EXTERNAL consumers, and
// `@testable import` grants access to internal declarations that a real
// consumer never has — an earlier version of this file used it and passed
// while `LPBreadcrumb(timestamp:category:message:)` did not actually
// compile outside the module (`SheepitBreadcrumb`'s memberwise init was
// internal). A plain import is what makes these assertions mean anything.
import SheepitKit

/// The `LP*` typealiases must keep compiling for code written against the
/// old names — that is their entire job. These tests fail to BUILD, not to
/// assert, if a shim regresses.
///
/// `GoaTechPrefixAliasTests` does the same for the `GoaTech*` / `GT*` wave.
///
/// `PublicSurfaceConstructibilityTests` below extends the same plain-import
/// discipline to the rest of the public API.
@available(*, deprecated)
final class DeprecatedAliasTests: XCTestCase {
    func testLPSpanIsConstructibleAndReadableByAnExternalConsumer() {
        let started = Date()
        let span = LPSpan(name: "checkout", startTime: started, attributes: ["step": "1"])

        XCTAssertEqual(span.name, "checkout")
        XCTAssertEqual(span.startTime, started)
        XCTAssertEqual(span.attributes["step"], "1")
        XCTAssertNil(span.endTime)
    }

    func testLPBreadcrumbIsConstructibleAndReadableByAnExternalConsumer() {
        let now = Date()
        let crumb = LPBreadcrumb(timestamp: now, category: "nav", message: "opened checkout")

        XCTAssertEqual(crumb.timestamp, now)
        XCTAssertEqual(crumb.category, "nav")
        XCTAssertEqual(crumb.message, "opened checkout")
    }

    /// The alias must be interchangeable with the new name, not merely
    /// coexist with it.
    func testAliasesAreInterchangeableWithTheNewNames() {
        let viaOldName: LPSpan = SheepitSpan(name: "a")
        let viaNewName: SheepitSpan = LPSpan(name: "a")
        XCTAssertEqual(viaOldName.name, viaNewName.name)

        let crumbViaOldName: LPBreadcrumb = SheepitBreadcrumb(
            timestamp: Date(), category: "c", message: "m"
        )
        let crumbViaNewName: SheepitBreadcrumb = LPBreadcrumb(
            timestamp: Date(), category: "c", message: "m"
        )
        XCTAssertEqual(crumbViaOldName.category, crumbViaNewName.category)
    }
}

/// Every public type a customer might need to CONSTRUCT — to fixture a
/// value in their own tests, or to build a stub — must have a public
/// initializer.
///
/// Swift synthesises only an INTERNAL memberwise init for a struct that
/// declares none, and public stored properties do not change that. The
/// result compiles fine inside the module and inside `@testable` tests, so
/// it is invisible until a customer hits it. Three types in this SDK had
/// exactly that defect (`SheepitBreadcrumb`, `SDKStatus`,
/// `SheepitPerformanceSummary`); this suite exists so a fourth cannot appear
/// unnoticed. Like the tests above, it asserts at COMPILE time — the plain
/// `import SheepitKit` at the top of this file is the whole mechanism.
final class PublicSurfaceConstructibilityTests: XCTestCase {
    func testStatusIsConstructibleByAConsumer() {
        let status = SDKStatus(
            initialized: true,
            online: false,
            queueDepth: 3,
            offlineQueueDepth: 1,
            lastFlushAt: nil,
            deviceId: "device-1",
            userId: nil,
            flagCount: 2,
            experimentCount: 1,
            sdkVersion: "0.2.0"
        )
        XCTAssertEqual(status.queueDepth, 3)
        XCTAssertEqual(status.sdkVersion, "0.2.0")
    }

    func testPerformanceSummaryIsConstructibleByAConsumer() {
        let summary = SheepitPerformanceSummary(
            coldStartMs: 120,
            warmStartMs: nil,
            slowFrameCount: 0,
            frozenFrameCount: 0,
            totalFrameCount: 60,
            memoryPeakMb: 42,
            anrCount: 0
        )
        XCTAssertEqual(summary.coldStartMs, 120)
        XCTAssertEqual(summary.totalFrameCount, 60)
    }

    func testExperimentResultAndFlagValueAreConstructibleByAConsumer() {
        let result = SheepitExperimentResult(variant: "variant_b")
        XCTAssertEqual(result.variant, "variant_b")

        let flag = FlagValue.json(AnyCodable(["accent": "purple"] as [String: Any]))
        XCTAssertEqual(flag.jsonObject?["accent"] as? String, "purple")
    }
}

/// The `GoaTech*` / `GT*` → `Sheepit*` prefix unification (0.2.0).
///
/// Same contract as `DeprecatedAliasTests` above and the same plain
/// `import SheepitKit` — these assertions are meaningless under
/// `@testable import`, which grants internal access no customer has.
///
/// Note what is being asserted: not that the old names *exist*, but that
/// they name the *same type*. A typealias and an accidental second
/// declaration both make `GoaTechConfig(...)` compile; only the alias makes
/// a `SheepitConfig` assignable to a `GoaTechConfig` binding. The
/// cross-assignments below are the part that would fail if someone
/// "restored compatibility" by duplicating a type instead of aliasing it.
@available(*, deprecated)
final class GoaTechPrefixAliasTests: XCTestCase {
    func testGoaTechNamesTheSameClassAsSheepitClient() {
        XCTAssertTrue(GoaTech.self === SheepitClient.self)
    }

    func testGoaTechConfigIsConstructibleAndInterchangeable() {
        let viaOldName = GoaTechConfig(apiKey: "lp_pub_abc_0123456789")
        XCTAssertEqual(viaOldName.apiKey, "lp_pub_abc_0123456789")

        // The assignments are the assertion: they only compile if the two
        // names resolve to one type.
        let asNew: SheepitConfig = viaOldName
        let backToOld: GoaTechConfig = asNew
        XCTAssertEqual(backToOld.apiKey, viaOldName.apiKey)
    }

    func testGTExperimentResultIsConstructibleAndInterchangeable() {
        let viaOldName = GTExperimentResult(variant: "variant_b")
        XCTAssertEqual(viaOldName.variant, "variant_b")

        let asNew: SheepitExperimentResult = viaOldName
        let backToOld: GTExperimentResult = asNew
        XCTAssertEqual(backToOld.variant, "variant_b")
    }

    func testGTPerformanceSummaryIsConstructibleAndInterchangeable() {
        let viaOldName = GTPerformanceSummary(
            coldStartMs: 120,
            warmStartMs: nil,
            slowFrameCount: 0,
            frozenFrameCount: 0,
            totalFrameCount: 60,
            memoryPeakMb: 42,
            anrCount: 0
        )
        XCTAssertEqual(viaOldName.coldStartMs, 120)

        let asNew: SheepitPerformanceSummary = viaOldName
        let backToOld: GTPerformanceSummary = asNew
        XCTAssertEqual(backToOld.totalFrameCount, 60)
    }

    /// The static factory is what a legacy consumer actually calls through
    /// the alias, and the other tests here only prove type identity. Swift
    /// guarantees typealias transparency for static members, so this is a
    /// low-risk gap — but "low-risk" is not "covered".
    func testTheStaticFactorySurfaceWorksThroughTheAlias() {
        let sdk = GoaTech.create(config: GoaTechConfig(apiKey: "lp_pub_xxx_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
        XCTAssertNotNil(sdk)

        // `shared` is nil for create(); initialize() is the singleton path.
        XCTAssertTrue(type(of: sdk) === SheepitClient.self)
        sdk.destroy()
    }
}
