import XCTest
@testable import SheepitKit

/// `FlagManager`-level tests for `inspect`, `knownFlagKeys`, per-key
/// `clearOverride`, honest override gating, and `flagChanges()`
/// notification. Public-API-level coverage (the `Sheepit` surface,
/// `SheepitConfig.allowFlagOverrides`, and the "inspect never fires
/// exposure" sweep) lives in `FlagInspectionPublicAPITests.swift`, which
/// deliberately avoids `@testable import` per the SDK's public-API test
/// convention.
final class FlagInspectionManagerTests: XCTestCase {
    // Raw UserDefaults.standard key FlagManager persists overrides
    // under — see `FlagValueJSONTests` for the same pattern.
    private static let overridesKey = "lp_debug_overrides"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.overridesKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.overridesKey)
        super.tearDown()
    }

    // MARK: - inspect() precedence

    func testInspectReportsFallbackForAnUnknownKey() {
        let manager = FlagManager()
        let inspection = manager.inspect(flagKey: "missing", defaultValue: .bool(true))

        XCTAssertEqual(inspection.key, "missing")
        XCTAssertNil(inspection.remoteValue)
        XCTAssertNil(inspection.overrideValue)
        XCTAssertEqual(inspection.effectiveValue, .bool(true))
        XCTAssertEqual(inspection.source, .fallback)
    }

    func testInspectReportsRemoteWhenNoOverride() {
        let manager = FlagManager()
        manager.setEvaluatedFlags(["show_banner": AnyCodable(false)])

        let inspection = manager.inspect(flagKey: "show_banner", defaultValue: .bool(true))
        XCTAssertEqual(inspection.remoteValue, .bool(false))
        XCTAssertNil(inspection.overrideValue)
        XCTAssertEqual(inspection.effectiveValue, .bool(false))
        XCTAssertEqual(inspection.source, .remote)
    }

    func testInspectSurfacesOverrideAboveRemote() {
        // The scenario from the spec's rationale: "server: off -> forced: on".
        let manager = FlagManager()
        manager.setOverridesAllowed(true)
        manager.setEvaluatedFlags(["show_banner": AnyCodable(false)])
        manager.overrideFlag("show_banner", value: .bool(true))

        let inspection = manager.inspect(flagKey: "show_banner", defaultValue: .bool(false))
        XCTAssertEqual(inspection.remoteValue, .bool(false), "server value must still be visible")
        XCTAssertEqual(inspection.overrideValue, .bool(true))
        XCTAssertEqual(inspection.effectiveValue, .bool(true), "matches what flag() returns now")
        XCTAssertEqual(inspection.source, .override)
    }

    func testInspectIgnoresAnOverrideWhenOverridesAreDisabled() {
        let manager = FlagManager()
        manager.setOverridesAllowed(true)
        manager.setEvaluatedFlags(["show_banner": AnyCodable(false)])
        manager.overrideFlag("show_banner", value: .bool(true))
        manager.setOverridesAllowed(false)

        let inspection = manager.inspect(flagKey: "show_banner", defaultValue: .bool(false))
        XCTAssertNil(inspection.overrideValue)
        XCTAssertEqual(inspection.effectiveValue, .bool(false))
        XCTAssertEqual(inspection.source, .remote)
    }

    func testInspectDoesNotConsumeFirstExposure() {
        // inspect() has no onExposure parameter at all — structurally it
        // cannot fire exposure. This proves it doesn't touch `exposed`
        // either: evaluate() must still see the first read as first.
        let manager = FlagManager()
        manager.setEvaluatedFlags(["show_banner": AnyCodable(true)])

        _ = manager.inspect(flagKey: "show_banner", defaultValue: .bool(false))
        _ = manager.inspect(flagKey: "show_banner", defaultValue: .bool(false))

        var exposureCount = 0
        _ = manager.evaluate(flagKey: "show_banner", defaultValue: .bool(false)) { _, _ in exposureCount += 1 }
        XCTAssertEqual(exposureCount, 1, "evaluate() must still treat this as the first exposure")
    }

    // MARK: - knownFlagKeys()

    func testKnownFlagKeysUnionsRemoteAndOverrideSorted() {
        let manager = FlagManager()
        manager.setOverridesAllowed(true)
        manager.setEvaluatedFlags(["z_remote": AnyCodable(true), "shared": AnyCodable(false)])
        manager.overrideFlag("a_override", value: .bool(true))
        manager.overrideFlag("shared", value: .bool(true))

        XCTAssertEqual(manager.knownFlagKeys(), ["a_override", "shared", "z_remote"])
    }

    func testKnownFlagKeysExcludesOverrideOnlyKeysWhenDisabled() {
        let manager = FlagManager()
        manager.setEvaluatedFlags(["remote_only": AnyCodable(true)])
        manager.overrideFlag("would_be_override", value: .bool(true)) // no-op, overrides disabled

        XCTAssertEqual(manager.knownFlagKeys(), ["remote_only"])
    }

    // MARK: - Honest gating

    /// Fix 1 (post-review, pre-1.0.0 freeze): gating WRITES is the security
    /// property; gating DELETES buys nothing and creates unreachable state —
    /// a build that once ran with debug:true writes an override to disk,
    /// ships to production, and nothing could purge it. Clearing must
    /// ALWAYS work, regardless of `overridesAllowed`.
    func testClearOverridePurgesDiskEvenWhenOverridesAreDisabled() {
        let writer = FlagManager()
        writer.setOverridesAllowed(true)
        writer.overrideFlag("stale_flag", value: .bool(true))

        // A separate "production" instance: overrides disabled by default.
        let productionInstance = FlagManager()
        productionInstance.clearOverride("stale_flag")

        // Re-enable to prove the ON-DISK state was actually purged, not
        // merely hidden behind the read-side gate.
        let verifier = FlagManager()
        verifier.setOverridesAllowed(true)
        XCTAssertNil(
            verifier.getOverrides()["stale_flag"],
            "clearOverride must purge on-disk state even when overrides are currently disabled"
        )
    }

    func testClearOverridesPurgesDiskEvenWhenOverridesAreDisabled() {
        let writer = FlagManager()
        writer.setOverridesAllowed(true)
        writer.overrideFlag("a", value: .bool(true))
        writer.overrideFlag("b", value: .bool(true))

        let productionInstance = FlagManager()
        productionInstance.clearOverrides()

        let verifier = FlagManager()
        verifier.setOverridesAllowed(true)
        XCTAssertTrue(
            verifier.getOverrides().isEmpty,
            "clearOverrides must purge on-disk state even when overrides are currently disabled"
        )
    }

    func testOverrideFlagDoesNotPersistWhenDisabled() {
        let manager = FlagManager()
        manager.overrideFlag("k", value: .bool(true))

        XCTAssertTrue(manager.getOverrides().isEmpty)
        XCTAssertNil(
            UserDefaults.standard.data(forKey: Self.overridesKey),
            "must not write to disk when overrides are disabled"
        )
    }

    func testGetOverridesEmptyWhenDisabledEvenIfPreviouslySet() {
        let manager = FlagManager()
        manager.setOverridesAllowed(true)
        manager.overrideFlag("k", value: .bool(true))
        manager.setOverridesAllowed(false)

        XCTAssertTrue(manager.getOverrides().isEmpty)
    }

    func testClearOverrideRemovesOnlyTargetedKey() {
        let manager = FlagManager()
        manager.setOverridesAllowed(true)
        manager.overrideFlag("a", value: .bool(true))
        manager.overrideFlag("b", value: .bool(true))

        manager.clearOverride("a")

        let remaining = manager.getOverrides()
        XCTAssertNil(remaining["a"])
        XCTAssertEqual(remaining["b"], .bool(true))
    }

    // Superseded by Fix 1 (post-review, pre-1.0.0 freeze): clearing used to
    // no-op while overrides were disabled — these two now pin the OPPOSITE
    // contract, exercised on the SAME instance (in-memory `debugOverrides`
    // was already populated by an earlier `setOverridesAllowed(true)`
    // before being disabled). Cross-instance disk-purge coverage —
    // the case where `debugOverrides` was NEVER loaded into memory — is
    // `testClearOverride(s)PurgesDiskEvenWhenOverridesAreDisabled` below.

    func testClearOverrideStillWorksWhenDisabled() {
        let manager = FlagManager()
        manager.setOverridesAllowed(true)
        manager.overrideFlag("a", value: .bool(true))
        manager.setOverridesAllowed(false)

        manager.clearOverride("a") // must still clear — deletes are never gated
        manager.setOverridesAllowed(true) // re-enable to inspect persisted state
        XCTAssertNil(manager.getOverrides()["a"], "clearOverride must purge regardless of the gate")
    }

    func testClearOverridesStillWorksWhenDisabled() {
        let manager = FlagManager()
        manager.setOverridesAllowed(true)
        manager.overrideFlag("a", value: .bool(true))
        manager.setOverridesAllowed(false)

        manager.clearOverrides() // must still clear — deletes are never gated
        manager.setOverridesAllowed(true)
        XCTAssertTrue(manager.getOverrides().isEmpty)
    }

    // MARK: - flagChanges()

    func testChangesFireOnConfigApply() async {
        let manager = FlagManager()
        var iterator = manager.changes().makeAsyncIterator()

        manager.setEvaluatedFlags(["a": AnyCodable(true)])
        let received: Void? = await iterator.next()
        XCTAssertNotNil(received)
    }

    func testChangesFireOnOverrideSetAndClear() async {
        let manager = FlagManager()
        manager.setOverridesAllowed(true)
        var iterator = manager.changes().makeAsyncIterator()

        manager.overrideFlag("a", value: .bool(true))
        let afterSet: Void? = await iterator.next()
        XCTAssertNotNil(afterSet)

        manager.clearOverride("a")
        let afterClear: Void? = await iterator.next()
        XCTAssertNotNil(afterClear)
    }

    func testChangesIsMultiSubscriber() async {
        let manager = FlagManager()
        var iteratorA = manager.changes().makeAsyncIterator()
        var iteratorB = manager.changes().makeAsyncIterator()

        manager.setEvaluatedFlags(["a": AnyCodable(true)])

        let receivedA: Void? = await iteratorA.next()
        let receivedB: Void? = await iteratorB.next()
        XCTAssertNotNil(receivedA, "first subscriber must see the change")
        XCTAssertNotNil(receivedB, "second subscriber must independently see the same change")
    }
}
