// Public-API tests for the dev-menu flag-inspection surface: `inspect`,
// `knownFlagKeys`, `clearOverride`, `flagChanges`, and the honest
// `SheepitConfig.allowFlagOverrides` gating. Deliberately does NOT
// `@testable import` — a public-API test that reaches internals would
// hide a missing `public` annotation. FlagManager-level precedence
// coverage lives in FlagInspectionManagerTests.swift.
import XCTest
import SheepitKit

final class FlagInspectionPublicAPITests: XCTestCase {
    // Raw UserDefaults.standard key the SDK persists debug overrides
    // under (see packages/sdk-swift/Sources/SheepitKit/Flags/FlagManager.swift).
    private static let overridesKey = "lp_debug_overrides"
    private static let apiKey = "lp_pub_xxx_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.overridesKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.overridesKey)
        super.tearDown()
    }

    /// Crash capture is ON by default SDK-wide, but installs a
    /// process-global signal handler — repeatedly installing/tearing it
    /// down across many `SheepitClient.create()` calls in one test process is
    /// unrelated to what these tests exercise, so it stays off here.
    private static func makeConfig(
        debug: Bool,
        allowFlagOverrides: Bool? = nil,
        onEvent: (@Sendable (String, [String: Any]?) -> Void)? = nil
    ) -> SheepitConfig {
        SheepitConfig(
            apiKey: Self.apiKey,
            debug: debug,
            onEvent: onEvent,
            crashes: CrashConfig(enabled: false),
            allowFlagOverrides: allowFlagOverrides
        )
    }

    // MARK: - inspect() never fires exposure

    func testInspectSweepFiresNoExposureEvents() {
        let log = EventNameLog()
        let sdk = SheepitClient.create(config: Self.makeConfig(
            debug: true,
            onEvent: { name, _ in log.record(name) }
        ))
        defer { sdk.destroy() }

        sdk.overrideFlag("flag_a", value: .bool(true))
        sdk.overrideFlag("flag_b", value: .string("x"))
        sdk.overrideFlag("flag_c", value: .int(3))

        let keys = sdk.knownFlagKeys()
        XCTAssertEqual(keys, ["flag_a", "flag_b", "flag_c"])

        for key in keys {
            _ = sdk.inspect(key, default: .bool(false))
        }

        XCTAssertFalse(
            log.names.contains("$flag_exposure"),
            "inspect() must never fire exposure — a dev-menu sweep would otherwise pollute exposure data"
        )

        // Prove the onEvent-capturing harness itself works, so the
        // assertion above isn't vacuously true because nothing was ever
        // being observed. (flag() on an overridden key is not a useful
        // counter-example here: an override short-circuits evaluate()
        // before the exposure check by design, same as production.)
        sdk.track("harness_check")
        XCTAssertTrue(log.names.contains("harness_check"), "onEvent must fire for a real track() call")
    }

    // MARK: - inspect() fallback

    func testInspectReportsFallbackWhenOverridesAreDisabled() {
        let sdk = SheepitClient.create(config: Self.makeConfig(debug: false))
        defer { sdk.destroy() }

        let inspection = sdk.inspect("unknown_flag", default: .bool(true))
        XCTAssertNil(inspection.remoteValue)
        XCTAssertNil(inspection.overrideValue)
        XCTAssertEqual(inspection.effectiveValue, .bool(true))
        XCTAssertEqual(inspection.source, .fallback)
    }

    // MARK: - Honest gating (SheepitConfig.allowFlagOverrides)

    func testAllowFlagOverridesDefaultsToNil() {
        let cfg = SheepitConfig(apiKey: Self.apiKey)
        XCTAssertNil(cfg.allowFlagOverrides, "nil == follow debug")
    }

    func testOverridesDisabledWhenDebugFalseAndAllowFlagOverridesUnset() {
        let sdk = SheepitClient.create(config: Self.makeConfig(debug: false))
        defer { sdk.destroy() }

        sdk.overrideFlag("k", value: .bool(true))

        XCTAssertTrue(sdk.getOverrides().isEmpty)
        XCTAssertNil(
            UserDefaults.standard.data(forKey: Self.overridesKey),
            "must not persist an override when disabled"
        )
        XCTAssertEqual(
            sdk.flag("k", default: .bool(false)),
            .bool(false),
            "an override that never took effect must not be applied"
        )
    }

    func testAllowFlagOverridesTrueEnablesOverridesEvenWithDebugFalse() {
        // The Sermo scenario: a dev menu in an internal/TestFlight build
        // WITHOUT shipping verbose SDK logging.
        let sdk = SheepitClient.create(config: Self.makeConfig(debug: false, allowFlagOverrides: true))
        defer { sdk.destroy() }

        sdk.overrideFlag("k", value: .bool(true))

        XCTAssertEqual(sdk.getOverrides()["k"], .bool(true))
        XCTAssertEqual(sdk.flag("k", default: .bool(false)), .bool(true))
    }

    func testAllowFlagOverridesFalseDisablesOverridesEvenWithDebugTrue() {
        let sdk = SheepitClient.create(config: Self.makeConfig(debug: true, allowFlagOverrides: false))
        defer { sdk.destroy() }

        sdk.overrideFlag("k", value: .bool(true))

        XCTAssertTrue(sdk.getOverrides().isEmpty)
    }

    // MARK: - clearOverride (per-key)

    func testClearOverridePublicAPIRemovesOnlyThatKey() {
        let sdk = SheepitClient.create(config: Self.makeConfig(debug: true))
        defer { sdk.destroy() }

        sdk.overrideFlag("a", value: .bool(true))
        sdk.overrideFlag("b", value: .bool(true))

        sdk.clearOverride("a")

        let remaining = sdk.getOverrides()
        XCTAssertNil(remaining["a"])
        XCTAssertEqual(remaining["b"], .bool(true))
    }

    // MARK: - flagChanges()

    func testFlagChangesFiresOnOverrideSet() async {
        let sdk = SheepitClient.create(config: Self.makeConfig(debug: true))
        defer { sdk.destroy() }

        var iterator = sdk.flagChanges().makeAsyncIterator()
        sdk.overrideFlag("a", value: .bool(true))

        let received: Void? = await iterator.next()
        XCTAssertNotNil(received)
    }

    /// Fix 3 (post-review, pre-1.0.0 freeze): a consumer whose lifetime
    /// isn't tied to a cancellable scope must see the stream COMPLETE on
    /// `destroy()`, not hang forever. Timeout-guarded so a regression
    /// fails the test instead of hanging the suite.
    func testDestroyFinishesOutstandingFlagChangesStream() async {
        let sdk = SheepitClient.create(config: Self.makeConfig(debug: true))
        let stream = sdk.flagChanges()

        let consumerFinished = Task<Bool, Never> {
            for await _ in stream {}
            return true // the loop only exits once the stream finishes
        }

        sdk.destroy()

        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await consumerFinished.value }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }

        XCTAssertTrue(finished, "flagChanges() stream must finish after destroy(), not hang")
    }

    // MARK: - Fix 4: post-destroy() inertness

    func testFlagChangesAfterDestroyReturnsAnAlreadyFinishedStream() async {
        let sdk = SheepitClient.create(config: Self.makeConfig(debug: true))
        sdk.destroy()

        var iterator = sdk.flagChanges().makeAsyncIterator()
        let received: Void? = await iterator.next()
        XCTAssertNil(received, "a stream obtained after destroy() must already be finished")
    }

    func testInspectAfterDestroyReturnsFallback() {
        let sdk = SheepitClient.create(config: Self.makeConfig(debug: false))
        sdk.destroy()

        let inspection = sdk.inspect("any_key", default: .bool(true))
        XCTAssertEqual(inspection, SheepitFlagInspection(
            key: "any_key",
            remoteValue: nil,
            overrideValue: nil,
            effectiveValue: .bool(true),
            source: .fallback
        ))
    }

    func testKnownFlagKeysAfterDestroyReturnsEmpty() {
        let sdk = SheepitClient.create(config: Self.makeConfig(debug: true))
        sdk.overrideFlag("a", value: .bool(true))
        sdk.destroy()

        XCTAssertEqual(sdk.knownFlagKeys(), [])
    }

    /// Regression, corrected 2026-09: this test used to assert the OPPOSITE — that
    /// `clearOverride` was a no-op after `destroy()`. That directly contradicted
    /// `clearOverrides()`'s own doc comment ("gating deletes would buy nothing and could
    /// leave a build ... unable to purge an override it wrote to disk"): a debug build that
    /// calls `destroy()` as part of its own teardown/reset flow, then wants to clean up an
    /// override it wrote earlier in the session, could no longer do so. Deletes are never
    /// gated — not by `allowFlagOverrides`, and not by `destroy()` either; only WRITES
    /// (`overrideFlag`) are.
    func testClearOverrideAfterDestroyStillPurgesTheOnDiskOverride() {
        let sdk = SheepitClient.create(config: Self.makeConfig(debug: true))
        sdk.overrideFlag("a", value: .bool(true))
        sdk.destroy()

        sdk.clearOverride("a")

        XCTAssertNil(
            sdk.getOverrides()["a"],
            "clearOverride must still purge an on-disk override even after destroy()"
        )
    }

    /// Same rationale, `clearOverrides()` (plural).
    func testClearOverridesAfterDestroyStillPurgesTheOnDiskOverrides() {
        let sdk = SheepitClient.create(config: Self.makeConfig(debug: true))
        sdk.overrideFlag("a", value: .bool(true))
        sdk.destroy()

        sdk.clearOverrides()

        XCTAssertTrue(
            sdk.getOverrides().isEmpty,
            "clearOverrides must still purge on-disk overrides even after destroy()"
        )
    }

    // MARK: - Fix S1 (2026-09 security follow-up, round 2): an INERT client — a rejected
    // key/apiUrl, documented to make zero writes to persistent storage — must not purge an
    // override a DIFFERENT, live client in the same process wrote to the shared, global
    // `lp_debug_overrides` blob. `clearOverrides()`/`clearOverride(_:)` carried no guard at
    // all before this fix, not even on `inertReason` (the destroy()-after-purge tests above
    // prove only that `destroyedFlag` must not gate deletes — a separate property).

    private static let rejectedKey = "lp_sec_xxx_" + String(repeating: "a", count: 64)

    private static func makeInertConfig() -> SheepitConfig {
        SheepitConfig(
            apiKey: Self.rejectedKey,
            crashes: CrashConfig(enabled: false),
            allowFlagOverrides: true
        )
    }

    func testInertClientClearOverridesDoesNotPurgeAnotherClientsOnDiskOverride() {
        let live = SheepitClient.create(config: Self.makeConfig(debug: true))
        live.overrideFlag("a", value: .bool(true))
        XCTAssertNotNil(
            UserDefaults.standard.data(forKey: Self.overridesKey),
            "harness check: the override must actually be on disk before this test proves anything"
        )
        live.destroy()

        let inert = SheepitClient.create(config: Self.makeInertConfig())
        XCTAssertFalse(inert.status().initialized)
        inert.clearOverrides()

        XCTAssertNotNil(
            UserDefaults.standard.data(forKey: Self.overridesKey),
            "An inert client must not purge an override a different, live client wrote."
        )
        let after = SheepitClient.create(config: Self.makeConfig(debug: true))
        XCTAssertEqual(
            after.getOverrides()["a"], .bool(true),
            "The override must survive an inert client's clearOverrides() call."
        )
        after.clearOverrides()
        after.destroy()
    }

    func testInertClientClearOverrideDoesNotPurgeAnotherClientsOnDiskOverride() {
        let live = SheepitClient.create(config: Self.makeConfig(debug: true))
        live.overrideFlag("a", value: .bool(true))
        live.destroy()

        let inert = SheepitClient.create(config: Self.makeInertConfig())
        XCTAssertFalse(inert.status().initialized)
        inert.clearOverride("a")

        let after = SheepitClient.create(config: Self.makeConfig(debug: true))
        XCTAssertEqual(
            after.getOverrides()["a"], .bool(true),
            "clearOverride(_:) on an inert client must not purge an override a live client wrote."
        )
        after.clearOverrides()
        after.destroy()
    }
}

private final class EventNameLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _names: [String] = []

    func record(_ name: String) {
        lock.lock()
        _names.append(name)
        lock.unlock()
    }

    var names: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _names
    }
}
