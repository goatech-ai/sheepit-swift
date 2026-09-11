// Admission tests for `SheepitClient.create(config:)`.
//
// Two behaviours are locked in here:
//
// 1. Audit E-002 — secret keys must never drive a client-side SDK. Historically the guard
//    was `preconditionFailure`, which aborts the process, so the rejection path could not be
//    tested at all (the old version of this file said exactly that). It now returns an inert
//    client, so every rejection path below is directly assertable.
//
// 2. The key prefix is not compiled in. Admission matches the `_`-delimited type segment, so
//    a published SPM pin keeps working when minting moves off `lp_`. A published version is
//    immutable forever, so a literal prefix here is what would make a rename expensive.

import XCTest
@testable import SheepitKit

final class SecretKeyGuardTests: XCTestCase {
    private static let hex = String(repeating: "a", count: 64)

    /// Collects diagnostics emitted during `create()` — `onDiagnostic` subscribes before the
    /// rejection is emitted, so the event is observed live rather than read back afterwards.
    private func makeConfig(
        apiKey: String,
        allowSecretKeyInClient: Bool = false,
        collecting events: EventSink? = nil,
        onEvent: (@Sendable (String, [String: Any]?) -> Void)? = nil
    ) -> SheepitConfig {
        SheepitConfig(
            apiKey: apiKey,
            // A LIVE client here starts for real. Without these, every admitted key in this
            // file installed crash-reporter signal handlers into the test process and fired
            // device-registration traffic at the production API — which crashed the suite
            // ~20-30% of runs, in whichever file happened to run next.
            apiUrl: "https://stub.invalid",
            onEvent: onEvent,
            crashes: CrashConfig(enabled: false),
            allowSecretKeyInClient: allowSecretKeyInClient,
            onDiagnostic: events.map { sink in { @Sendable event in sink.append(event) } }
        )
    }

    /// Thread-safe collector; `DiagnosticListener` is `@Sendable`.
    final class EventSink: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [DiagnosticEvent] = []

        func append(_ event: DiagnosticEvent) {
            lock.lock(); defer { lock.unlock() }
            events.append(event)
        }

        var codes: [String] {
            lock.lock(); defer { lock.unlock() }
            return events.map(\.code)
        }

        func message(for code: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            return events.first { $0.code == code }?.message
        }
    }

    // MARK: - Accepted

    func testPubKeyAccepted() {
        let sdk = SheepitClient.create(config: makeConfig(apiKey: "lp_pub_xxx_\(Self.hex)"))
        XCTAssertTrue(sdk.status().initialized)
        sdk.destroy()
    }

    func testSecKeyAcceptedWithExplicitOptIn() {
        // Tests that intentionally use sec keys (e.g. server-side fixtures) can opt out of
        // the guard. Production iOS callers MUST NOT set this flag — it would re-introduce
        // the audit-E-002 leak.
        let sdk = SheepitClient.create(
            config: makeConfig(apiKey: "lp_sec_xxx_\(Self.hex)", allowSecretKeyInClient: true)
        )
        XCTAssertTrue(sdk.status().initialized)
        sdk.destroy()
    }

    func testAllowSecretKeyInClientDefaultsFalse() {
        let cfg = SheepitConfig(apiKey: "lp_pub_xxx_\(Self.hex)")
        XCTAssertFalse(
            cfg.allowSecretKeyInClient,
            "SheepitConfig.allowSecretKeyInClient must default to false. Audit E-002."
        )
    }

    // MARK: - Rejected, without aborting the host app

    func testSecKeyWithoutOptInReturnsInertClient() {
        let sink = EventSink()
        let sdk = SheepitClient.create(
            config: makeConfig(apiKey: "lp_sec_xxx_\(Self.hex)", collecting: sink)
        )
        XCTAssertFalse(sdk.status().initialized, "A secret key must not produce a live client.")
        XCTAssertTrue(sink.codes.contains("lifecycle.api_key_rejected"))
        XCTAssertTrue(
            sink.message(for: "lifecycle.api_key_rejected")?.contains("Secret keys") == true,
            "The diagnostic must name the secret-key reason, not a generic format error."
        )
    }

    /// Regression: `lp_dev_` is a documented key type and used to hit the same
    /// `precondition` as garbage input, taking the host app down with a message that named
    /// only `pub` and `sec`. Dev keys still cannot post events — they are read-only for
    /// schemas and definitions — but they must be refused, not fatal.
    func testDevKeyIsRejectedWithItsOwnReasonAndDoesNotAbort() {
        let sink = EventSink()
        let sdk = SheepitClient.create(
            config: makeConfig(apiKey: "lp_dev_xxx_\(Self.hex)", collecting: sink)
        )
        XCTAssertFalse(sdk.status().initialized)
        XCTAssertTrue(
            sink.message(for: "lifecycle.api_key_rejected")?.contains("Developer keys") == true,
            "A dev key must report the dev-key reason, not 'Invalid API key format'."
        )
    }

    func testUnrecognizedKeyIsRejectedWithoutAborting() {
        let sink = EventSink()
        let sdk = SheepitClient.create(config: makeConfig(apiKey: "not-a-key", collecting: sink))
        XCTAssertFalse(sdk.status().initialized)
        XCTAssertTrue(
            sink.message(for: "lifecycle.api_key_rejected")?.contains("Invalid API key format")
                == true
        )
    }

    func testEmptyKeyIsRejectedWithoutAborting() {
        let sdk = SheepitClient.create(config: makeConfig(apiKey: ""))
        XCTAssertFalse(sdk.status().initialized)
    }

    /// An inert client must be a total no-op, not a half-live one: flags fall back to the
    /// caller's default and nothing is queued for the network.
    func testInertClientIsANoOp() {
        let sdk = SheepitClient.create(config: makeConfig(apiKey: "lp_dev_xxx_\(Self.hex)"))
        sdk.track("should_not_be_queued")
        XCTAssertEqual(sdk.status().queueDepth, 0)
        XCTAssertEqual(sdk.flag("anything", default: .bool(true)).boolValue, true)
        XCTAssertEqual(sdk.experiment("anything").variant, "control")
        XCTAssertTrue(sdk.knownFlagKeys().isEmpty)
        sdk.destroy()  // asserted for real in testInertClientReleasesItsNetworkMonitor
    }

    // MARK: - The prefix is not compiled in

    /// The point of the change: a future mint under a different vendor prefix must work on
    /// an SPM version pinned today. Published versions are immutable, so this is the test
    /// that keeps the prefix cheap to rename. The vendor segment is the ONLY part not
    /// validated — everything else about the shape still is.
    func testPublishableKeyUnderADifferentVendorPrefixIsAccepted() {
        for key in ["si_pub_xxx_\(Self.hex)", "sheepit_pub_xxx_\(Self.hex)"] {
            let sdk = SheepitClient.create(config: makeConfig(apiKey: key))
            XCTAssertTrue(sdk.status().initialized, "\(key) should be admitted")
            sdk.destroy()
        }
    }

    /// ...and the secret-key guard must not fail open under that same rename.
    func testSecretKeyUnderADifferentVendorPrefixIsStillRejected() {
        for key in ["si_sec_xxx_\(Self.hex)", "sheepit_sec_xxx_\(Self.hex)"] {
            let sdk = SheepitClient.create(config: makeConfig(apiKey: key))
            XCTAssertFalse(sdk.status().initialized, "\(key) must not produce a live client")
        }
    }

    /// Malformed input must be REFUSED, not admitted as a live client that silently 401s.
    /// The first matcher draft scanned for any `pub` segment anywhere, which admitted every
    /// one of these — a developer typo would have produced a client that looked alive.
    func testMalformedKeysAreRefusedRatherThanAdmitted() {
        let malformed = [
            "pub",                              // bare type segment
            "your_pub_key",                     // placeholder text
            "lp_pub_xxx_",                      // no secret
            "lp_pub_xxx_tooshort",              // secret below the minimum length
            "lp_publishable_xxx_\(Self.hex)",   // type segment not exactly a known token
            "lp_xxx_pub_\(Self.hex)",           // type token in the slug position
        ]
        for key in malformed {
            let sdk = SheepitClient.create(config: makeConfig(apiKey: key))
            XCTAssertFalse(sdk.status().initialized, "\(key) must not produce a live client")
        }
    }

    /// A whole secret key concatenated onto something publishable-looking must not be
    /// admitted just because segment 1 reads `pub`. The environment slug at index 2 is
    /// exempt from this check — an environment named "security" legitimately slugs to "sec".
    func testSecretKeyConcatenatedOntoAPublishableShapeIsRejected() {
        let sdk = SheepitClient.create(
            config: makeConfig(apiKey: "lp_pub_xxx_lp_sec_xxx_\(Self.hex)")
        )
        XCTAssertFalse(sdk.status().initialized)
    }

    /// A dev key smuggled the same way must also be refused. Dev keys are read-only, but they
    /// read /v1/flags/definitions — every flag key and targeting rule — so one must not ride
    /// into an IPA either. The concat sweep originally tested `sec` alone and admitted these.
    func testDevKeyConcatenatedOntoAPublishableShapeIsRejected() {
        for key in [
            "lp_pub_xxx_\(Self.hex)_lp_dev_xxx_\(Self.hex)",
            "lp_pub_xxx_\(Self.hex)_dev_xxx_\(Self.hex)",
        ] {
            let sdk = SheepitClient.create(config: makeConfig(apiKey: key))
            XCTAssertFalse(sdk.status().initialized, "\(key) must not produce a live client")
        }
    }

    /// ...and `allowSecretKeyInClient`, the XCTest-only opt-out, must not smuggle a dev key
    /// in with it. It exempts `sec` and nothing else.
    func testAllowSecretKeyInClientDoesNotExemptAConcatenatedDevKey() {
        let sdk = SheepitClient.create(
            config: makeConfig(
                apiKey: "lp_pub_xxx_\(Self.hex)_lp_dev_xxx_\(Self.hex)",
                allowSecretKeyInClient: true
            )
        )
        XCTAssertFalse(sdk.status().initialized)
    }

    func testEnvironmentSlugMayItselfReadAsATypeToken() {
        for key in ["lp_pub_sec_\(Self.hex)", "lp_pub_dev_\(Self.hex)"] {
            let sdk = SheepitClient.create(config: makeConfig(apiKey: key))
            XCTAssertTrue(sdk.status().initialized, "\(key) is a valid pub key; slug is not a type")
            sdk.destroy()
        }
    }

    // MARK: - An inert client must not brick the SDK or leak resources

    /// Regression: `initialize()` cached the inert client as the singleton, and `destroy()`
    /// early-returns on it (the latch is already set), so the singleton could never be
    /// cleared — `shared` and every later `initialize()` returned the dead client for the
    /// process lifetime. A transient bad key permanently disabled the SDK, silently. This
    /// test fails against that version.
    func testARejectedKeyDoesNotBrickTheSingleton() {
        SheepitClient.shared?.destroy()
        let inert = SheepitClient.initialize(config: makeConfig(apiKey: "lp_sec_xxx_\(Self.hex)"))
        XCTAssertFalse(inert.status().initialized)
        XCTAssertNil(SheepitClient.shared, "An inert client must never be cached as the singleton.")

        let recovered = SheepitClient.initialize(config: makeConfig(apiKey: "lp_pub_xxx_\(Self.hex)"))
        XCTAssertTrue(
            recovered.status().initialized,
            "A corrected key must produce a live client, not the cached dead one."
        )
        recovered.destroy()
    }

    /// Regression, corrected 2026-09: the original version of this test asserted
    /// `inert.connectivity.isMonitoring == false` as proof `releaseSelfStartingComponents()`
    /// ran. Mutation-tested: deleting that function's body did NOT fail the assertion,
    /// because post-#972 `ConnectivityMonitor`'s `NWPathMonitor` only starts in `.start()`,
    /// which an inert client never reaches — `isMonitoring` was already false either way.
    /// Neither component `releaseSelfStartingComponents()` releases currently starts
    /// anything in its own initializer (see that function's doc), so this counts the call
    /// directly instead of inferring it through a component that was never started.
    func testInertClientCallsReleaseSelfStartingComponentsExactlyOnce() {
        let inert = SheepitClient.create(config: makeConfig(apiKey: "lp_dev_xxx_\(Self.hex)"))
        XCTAssertEqual(
            inert.releaseSelfStartingComponentsCallCount, 1,
            "A rejected-key/apiUrl client must release its self-starting components, once, during init."
        )
        XCTAssertFalse(inert.connectivity.isMonitoring)

        let live = SheepitClient.create(config: makeConfig(apiKey: "lp_pub_xxx_\(Self.hex)"))
        XCTAssertEqual(
            live.releaseSelfStartingComponentsCallCount, 0,
            "A live client must not release these until destroy()."
        )
        XCTAssertTrue(live.connectivity.isMonitoring, "A live client still needs its monitor.")
        live.destroy()
        XCTAssertEqual(live.releaseSelfStartingComponentsCallCount, 1)
        XCTAssertFalse(live.connectivity.isMonitoring)
    }

    /// Regression: `overrideFlag`/`getOverrides` were unguarded, and `setOverridesAllowed`
    /// ran before the inert branch — so an inert client built with `debug: true` wrote flag
    /// overrides into the shared `UserDefaults.standard`, where a later healthy client in
    /// the same process would pick them up.
    ///
    /// Mutation-tested 2026-09: the `overrideFlag()`/`getOverrides()` assertions below alone
    /// do NOT catch a reverted `if inertReason == nil` gate on `setOverridesAllowed`, because
    /// `overrideFlag()` has its OWN `guard !destroyedFlag.value` at the `SheepitClient` layer
    /// (an inert client is destroyed-flagged at construction) that blocks the write before
    /// it ever reaches `FlagManager`. `overridesAllowedForTests` reads the FlagManager-level
    /// gate directly, bypassing that guard, so it actually exercises the fix.
    func testInertClientDoesNotWriteFlagOverrides() {
        let inert = SheepitClient.create(
            config: SheepitConfig(
                apiKey: "lp_sec_xxx_\(Self.hex)",
                apiUrl: "https://stub.invalid",
                debug: true,
                crashes: CrashConfig(enabled: false)
            )
        )
        XCTAssertFalse(
            inert.flagManager.overridesAllowedForTests,
            "An inert client's FlagManager must never have overrides enabled, regardless of debug."
        )
        inert.overrideFlag("leaked_override", value: .bool(true))
        XCTAssertTrue(inert.getOverrides().isEmpty)

        let live = SheepitClient.create(
            config: SheepitConfig(
                apiKey: "lp_pub_xxx_\(Self.hex)",
                apiUrl: "https://stub.invalid",
                debug: true,
                crashes: CrashConfig(enabled: false)
            )
        )
        XCTAssertNil(
            live.getOverrides()["leaked_override"],
            "An override written by an inert client must not reach a later healthy client."
        )
        live.clearOverrides()
        live.destroy()
    }

    /// The type segment precedes the environment slug, so a key whose slug happens to read
    /// `dev` is still admitted as publishable.
    func testTypeSegmentWinsOverAnAmbiguousEnvironmentSlug() {
        let sdk = SheepitClient.create(config: makeConfig(apiKey: "lp_pub_dev_\(Self.hex)"))
        XCTAssertTrue(sdk.status().initialized)
        sdk.destroy()
    }

    // MARK: - E-002 fail-open on a multi-token vendor prefix (2026-09 follow-up)

    /// THE bug: `dropFirst(3)` exempted index 2 as "the slug", but a two-token vendor prefix
    /// slides the real type segment INTO that exempt slot. `segments[1]` still reads "pub",
    /// the true "sec" at index 2 was skipped as if it were an env slug, and the secret at
    /// index 4 is long enough to pass — so this secret key was ADMITTED by the pre-fix
    /// matcher. Requiring exactly 4 segments kills it structurally: this key has 5.
    func testTwoTokenVendorPrefixCannotSlideASecretTypeIntoTheSlugSlot() {
        let sdk = SheepitClient.create(config: makeConfig(apiKey: "my_pub_sec_abc_\(Self.hex)"))
        XCTAssertFalse(
            sdk.status().initialized,
            "A 5-segment key must be refused outright, not parsed as if segment 2 were a slug."
        )
    }

    /// The same shape with `dev` in the slid slot must also be refused — the fix is
    /// structural (segment count), not specific to which type token got smuggled.
    func testTwoTokenVendorPrefixCannotSlideADevTypeIntoTheSlugSlot() {
        let sdk = SheepitClient.create(config: makeConfig(apiKey: "my_pub_dev_abc_\(Self.hex)"))
        XCTAssertFalse(sdk.status().initialized)
    }

    // MARK: - Malformed shapes that used to collapse into a well-formed-looking count

    /// A double underscore used to collapse (`omittingEmptySubsequences: true`) into a
    /// clean-looking 4-segment key. Splitting with `omittingEmptySubsequences: false` and
    /// rejecting any empty segment catches it instead.
    func testDoubleUnderscoreIsRejectedRatherThanCollapsed() {
        // An env slug ("abc") must be present for this to actually distinguish old from new
        // behavior: `"lp__pub_abc_<hex>".split(separator: "_")` (the default,
        // omittingEmptySubsequences: true) collapses the doubled underscore's empty
        // component away, leaving exactly 4 well-formed-looking segments — which the
        // pre-fix matcher admitted. Without the slug segment, the collapsed count is only 3
        // either way and this would pass for the wrong reason (still <4, coincidentally).
        let sdk = SheepitClient.create(config: makeConfig(apiKey: "lp__pub_abc_\(Self.hex)"))
        XCTAssertFalse(sdk.status().initialized)
    }

    /// A leading underscore used to collapse the same way.
    func testLeadingUnderscoreIsRejectedRatherThanCollapsed() {
        let sdk = SheepitClient.create(config: makeConfig(apiKey: "_lp_pub_abc_\(Self.hex)"))
        XCTAssertFalse(sdk.status().initialized)
    }

    /// A trailing underscore used to collapse into a 4-segment key too — this is the exact
    /// shape named in the audit as silently admitted.
    func testTrailingUnderscoreIsRejectedRatherThanCollapsed() {
        let sdk = SheepitClient.create(config: makeConfig(apiKey: "lp_pub_abc_\(Self.hex)_"))
        XCTAssertFalse(sdk.status().initialized)
    }

    // MARK: - A key with control characters must be trimmed/rejected, not admitted verbatim

    /// A trailing newline (the common terminal/`.env`/plist copy-paste artifact) must still
    /// be admitted — `create()` trims before judging — but the corresponding
    /// `HTTPClientAuthHeaderTests` prove the WIRE value is the trimmed one, since an
    /// untrimmed key here would otherwise make Foundation silently drop the entire
    /// `Authorization` header.
    func testKeyWithTrailingNewlineIsStillAdmitted() {
        let sdk = SheepitClient.create(config: makeConfig(apiKey: "lp_pub_xxx_\(Self.hex)\n"))
        XCTAssertTrue(sdk.status().initialized)
        sdk.destroy()
    }

    /// An embedded NUL byte in the middle of the secret can't be trimmed away — it must be
    /// refused outright by the printable-ASCII constraint on the secret segment.
    func testKeyWithEmbeddedNulInSecretIsRejected() {
        let dirty = "lp_pub_xxx_\(Self.hex.dropLast())\u{0}"
        let sdk = SheepitClient.create(config: makeConfig(apiKey: dirty))
        XCTAssertFalse(sdk.status().initialized)
    }

    // MARK: - M3 (2026-09 security follow-up, round 2): the printable-ASCII check must cover
    // the WHOLE key, not just the secret segment

    /// Regression: the printable-ASCII guard applied to `segments[secretSegmentIndex]` only.
    /// A CR/LF embedded in the SLUG (segment 2) was admitted — trimming only strips the
    /// ends, so a mid-string control character survives — and then Foundation silently drops
    /// the entire `Authorization` header on every request built from it, same E-004 failure
    /// mode as a dirty secret.
    func testKeyWithLineFeedInSlugIsRejected() {
        let dirty = "lp_pub_a\u{0A}c_\(Self.hex)"
        let sdk = SheepitClient.create(config: makeConfig(apiKey: dirty))
        XCTAssertFalse(sdk.status().initialized, "A CR/LF in the slug segment must be refused.")
    }

    /// Same failure mode, in the VENDOR segment.
    func testKeyWithLineFeedInVendorPrefixIsRejected() {
        let dirty = "l\u{0A}p_pub_abc_\(Self.hex)"
        let sdk = SheepitClient.create(config: makeConfig(apiKey: dirty))
        XCTAssertFalse(sdk.status().initialized, "A CR/LF in the vendor segment must be refused.")
    }

    /// A carriage return (as opposed to line feed) must be caught the same way.
    func testKeyWithCarriageReturnInSlugIsRejected() {
        let dirty = "lp_pub_a\u{0D}c_\(Self.hex)"
        let sdk = SheepitClient.create(config: makeConfig(apiKey: dirty))
        XCTAssertFalse(sdk.status().initialized)
    }

    /// A legitimate key with an all-ASCII vendor and slug must still be admitted — the
    /// widened check must not reject anything it used to accept.
    func testLegitimateKeyWithOrdinaryVendorAndSlugIsStillAccepted() {
        let sdk = SheepitClient.create(config: makeConfig(apiKey: "lp_pub_prod_\(Self.hex)"))
        XCTAssertTrue(sdk.status().initialized)
        sdk.destroy()
    }

    // MARK: - Small fix: a malformed apiUrl's rejection message must not leak userinfo

    /// Regression: `apiURLRejectionReason` interpolated the raw `apiUrl` verbatim into a
    /// message that reaches THREE places — `log.error`, the `lifecycle.api_key_rejected`
    /// diagnostic, and the PUBLIC `status().rejectionReason` — so a copy-pasted gateway URL
    /// with embedded basic-auth credentials leaked its password into logs, the diagnostic
    /// bus, and a value a host app might display or forward.
    func testMalformedApiUrlRejectionMessageRedactsEmbeddedCredentials() {
        let sink = EventSink()
        // `URL(string:)` parses this as scheme "user", host nil — no "https://" prefix, so
        // it fails the existing `url.host != nil` guard and actually reaches the rejection
        // path. (A copy-paste missing its scheme is the realistic version of this mistake.)
        let dirtyUrl = "user:sup3rs3cret@api.example.com"
        let sdk = SheepitClient.create(
            config: SheepitConfig(
                apiKey: "lp_pub_xxx_\(Self.hex)",
                apiUrl: dirtyUrl,
                crashes: CrashConfig(enabled: false),
                onDiagnostic: { @Sendable event in sink.append(event) }
            )
        )
        XCTAssertFalse(sdk.status().initialized)
        let reason = sdk.status().rejectionReason ?? ""
        XCTAssertFalse(
            reason.contains("sup3rs3cret"),
            "status().rejectionReason must not leak the apiUrl's embedded password."
        )
        XCTAssertFalse(
            sink.message(for: "lifecycle.api_key_rejected")?.contains("sup3rs3cret") ?? false,
            "the diagnostic message must not leak the apiUrl's embedded password either."
        )
    }

    // MARK: - A malformed apiUrl must not abort the host app either

    /// `HTTPClient` used to force-unwrap `URL(string: config.apiUrl)!` — an empty apiUrl
    /// (the common BYOC case: an unset env var interpolated into the config) traps the host
    /// process in a release build. This proves the SAME inert-client path a rejected key
    /// takes now catches it instead.
    func testEmptyApiUrlProducesAnInertClientRatherThanAborting() {
        let sink = EventSink()
        let sdk = SheepitClient.create(
            config: SheepitConfig(
                apiKey: "lp_pub_xxx_\(Self.hex)",
                apiUrl: "",
                crashes: CrashConfig(enabled: false),
                onDiagnostic: { @Sendable event in sink.append(event) }
            )
        )
        XCTAssertFalse(sdk.status().initialized)
        XCTAssertTrue(sink.codes.contains("lifecycle.api_key_rejected"))
    }

    /// A non-empty but schemeless/hostless apiUrl (e.g. a copy-paste that dropped
    /// `https://`) must be caught the same way, not produce a client that looks alive and
    /// then fails every request.
    func testMalformedApiUrlProducesAnInertClientRatherThanAborting() {
        for badUrl in ["not-a-url", "api.sheepit.ai", "   "] {
            let sdk = SheepitClient.create(
                config: SheepitConfig(
                    apiKey: "lp_pub_xxx_\(Self.hex)",
                    apiUrl: badUrl,
                    crashes: CrashConfig(enabled: false)
                )
            )
            XCTAssertFalse(sdk.status().initialized, "apiUrl \(badUrl.debugDescription) must not admit a client")
        }
    }

    // MARK: - An inert client makes zero writes to persistent storage (FIX 2)

    /// Regression: `StorageMigration.run` and `ContextManager`'s identity-persist step ran
    /// unconditionally, BEFORE the key/apiUrl was judged — so constructing a client with a
    /// bad key rotated the device/session ids the NEXT, correctly-keyed client would read.
    /// This snapshots every key the SDK is known to touch before and after constructing an
    /// inert client and asserts none of them changed.
    /// Must exercise `SheepitClient.init`'s REAL gate, not just re-demonstrate that
    /// `ContextManager(persistOnInit: false)` is a no-op in isolation — that alone would
    /// pass whether or not `init` actually calls it with `false` for an inert client. The
    /// production suite name is hardcoded (not injectable — a separate, deliberately
    /// untouched decision, see FIX 2's note), so this reads the REAL suite `SheepitClient`
    /// uses, snapshotting only the identity keys `ContextManager.persistIds()` writes,
    /// immediately before and after a single synchronous `create()` call with no
    /// suspension point in between.
    /// 🔴 2026-09 security follow-up (round 2), finding S2: this test was VACUOUS. Reverting
    /// the E-001 fix (`persistOnInit: true` unconditionally + ungated `StorageMigration.run`)
    /// left it GREEN, because `ContextManager.init` restores ids from storage and
    /// `persistIds()` writes back IDENTICAL values when the stored session is still live —
    /// the before/after snapshot matched either way. Rotation — the actual mutation E-001
    /// exists to prevent — only happens when the stored session has aged out, which the
    /// original version never set up. Seeding an EXPIRED session below forces a reverted
    /// `ContextManager` to mint and persist a NEW session id, which only the fixed code (an
    /// inert client's `ContextManager(persistOnInit: false)`) avoids doing.
    func testInertClientMakesNoPersistentWrites() {
        let defaults = UserDefaults(suiteName: "ai.goatech.sdk")!
        func snapshot() -> [String?] {
            [
                defaults.string(forKey: StorageKeys.deviceId),
                defaults.string(forKey: StorageKeys.sessionId),
                defaults.string(forKey: StorageKeys.sessionLastSeen),
                defaults.string(forKey: StorageKeys.anonymousId),
            ]
        }

        // This is the REAL, hardcoded `ai.goatech.sdk` suite every live client in this test
        // target shares — save and restore whatever session state was already there so this
        // test doesn't leak a fixed session id into unrelated tests.
        let originalSessionId = defaults.string(forKey: StorageKeys.sessionId)
        let originalLastSeen = defaults.string(forKey: StorageKeys.sessionLastSeen)
        defer {
            defaults.set(originalSessionId, forKey: StorageKeys.sessionId)
            defaults.set(originalLastSeen, forKey: StorageKeys.sessionLastSeen)
        }

        // Seed a session that is aged out (`sessionLastSeen` is a Unix-epoch-seconds string;
        // `SDKDefaults.sessionTimeoutSeconds` is 30 minutes, so 1_000_000 is expired many
        // times over) so `ContextManager.init`'s own expiry check mints a fresh session id —
        // the mutation this test needs to be able to observe.
        defaults.set("session-fixed", forKey: StorageKeys.sessionId)
        defaults.set("1000000.0", forKey: StorageKeys.sessionLastSeen)

        let before = snapshot()
        let inert = SheepitClient.create(config: makeConfig(apiKey: "lp_sec_xxx_\(Self.hex)"))
        let after = snapshot()

        XCTAssertFalse(inert.status().initialized)
        XCTAssertEqual(
            before, after,
            "An inert client must not touch deviceId/sessionId/sessionLastSeen/anonymousId — " +
            "constructing one used to rotate the ids the NEXT, correctly-keyed client reads."
        )
    }

    /// Regression coverage for the intersection with #973's auto-emitted `$session_start`:
    /// that event now fires from `start()` on every LIVE client's first launch, and an inert
    /// (rejected-key/apiUrl) client must never reach `start()` at all. `emitSessionStartIfOwed()`
    /// calls `track()`, which is guarded on `destroyedFlag` — already latched for an inert
    /// client before this assertion runs — so this proves the guard actually composes with
    /// the new auto-emit rather than merely re-asserting each half in isolation.
    func testInertClientEmitsNoEventsIncludingSessionStart() {
        final class Recorder: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var names: [String] = []
            func record(_ name: String) { lock.lock(); names.append(name); lock.unlock() }
        }
        let recorder = Recorder()

        let inert = SheepitClient.create(config: makeConfig(
            apiKey: "lp_sec_xxx_\(Self.hex)",
            onEvent: { name, _ in recorder.record(name) }
        ))

        XCTAssertFalse(inert.status().initialized)
        XCTAssertTrue(
            recorder.names.isEmpty,
            "An inert client must emit ZERO events — including `$session_start` — " +
            "but recorded \(recorder.names)."
        )
    }

    // MARK: - MF-5 (2026-09 security follow-up round 3): empty scheme/host must be refused

    /// Regression: `url.host != nil` passed for `"https://user:sup3rs3cret@"`, because
    /// Foundation parses a missing host as an EMPTY STRING, not `nil` — verified via
    /// `URL(string: "https://user:sup3rs3cret@")!.host == ""`. The old guard admitted it.
    func testApiUrlWithAnEmptyHostIsRejected() {
        let sdk = SheepitClient.create(
            config: makeConfig(apiKey: "lp_pub_xxx_\(Self.hex)").withApiUrl("https://user:sup3rs3cret@")
        )
        XCTAssertFalse(
            sdk.status().initialized,
            "An apiUrl with an empty (non-nil) host must be refused, not admitted."
        )
    }

    /// Regression: `url.scheme != nil` passed for `"://user:pass@host"`, because Foundation
    /// parses a missing scheme as an EMPTY STRING too — verified via
    /// `URL(string: "://user:pass@host")!.scheme == ""`.
    func testApiUrlWithAnEmptySchemeIsRejected() {
        let sdk = SheepitClient.create(
            config: makeConfig(apiKey: "lp_pub_xxx_\(Self.hex)").withApiUrl("://user:pass@host")
        )
        XCTAssertFalse(sdk.status().initialized, "An apiUrl with an empty scheme must be refused.")
    }

    /// A non-empty but non-http(s) scheme has no legitimate use for a REST API gateway URL.
    func testApiUrlWithANonHttpSchemeIsRejected() {
        let sdk = SheepitClient.create(
            config: makeConfig(apiKey: "lp_pub_xxx_\(Self.hex)").withApiUrl("foo://host")
        )
        XCTAssertFalse(sdk.status().initialized, "A non-http(s) scheme must be refused.")
    }

    /// http (not just https) must still be admitted — e.g. a local BYOC gateway without TLS.
    func testApiUrlWithPlainHttpSchemeIsStillAccepted() {
        let sdk = SheepitClient.create(
            config: makeConfig(apiKey: "lp_pub_xxx_\(Self.hex)").withApiUrl("http://stub.invalid")
        )
        XCTAssertTrue(sdk.status().initialized)
        sdk.destroy()
    }

    // MARK: - SF-1 (2026-09 security follow-up round 3): userinfo redaction gaps

    /// Regression: the redaction regex required a colon (`user:pass@`), so a BARE token with
    /// no `user:pass` shape leaked verbatim into `status().rejectionReason` and the
    /// diagnostic message.
    func testRejectionMessageRedactsABareTokenWithNoColon() {
        let sink = EventSink()
        let sdk = SheepitClient.create(
            config: SheepitConfig(
                apiKey: "lp_pub_xxx_\(Self.hex)",
                apiUrl: "sup3rs3cret@api.example.com",
                crashes: CrashConfig(enabled: false),
                onDiagnostic: { @Sendable event in sink.append(event) }
            )
        )
        XCTAssertFalse(sdk.status().initialized)
        XCTAssertFalse(
            (sdk.status().rejectionReason ?? "").contains("sup3rs3cret"),
            "A bare token before '@' (no colon) must still be redacted."
        )
        XCTAssertFalse(
            sink.message(for: "lifecycle.api_key_rejected")?.contains("sup3rs3cret") ?? false
        )
    }

    /// Regression: the character class excluded `@`, so a password that itself CONTAINS an
    /// `@` matched only up to the FIRST `@`, under-redacting `"https://user:p@ss@host"` to
    /// `"ss@host"` — the tail of the secret survived.
    func testRejectionMessageFullyRedactsAPasswordContainingAnAtSign() {
        let sink = EventSink()
        let sdk = SheepitClient.create(
            config: SheepitConfig(
                apiKey: "lp_pub_xxx_\(Self.hex)",
                apiUrl: "https://user:p@ss@nonexistent-host-for-mf5-test.invalid:not-a-port",
                crashes: CrashConfig(enabled: false),
                onDiagnostic: { @Sendable event in sink.append(event) }
            )
        )
        XCTAssertFalse(sdk.status().initialized)
        let reason = sdk.status().rejectionReason ?? ""
        XCTAssertFalse(reason.contains("p@ss"), "the under-redaction must not survive: got \(reason.debugDescription)")
        XCTAssertFalse(reason.contains("ss@"), "no fragment of the password may leak either: got \(reason.debugDescription)")
    }

    // MARK: - SF-2 (2026-09 security follow-up round 3): a dirty environment must not silently

    /// drop the X-Environment header
    ///
    /// Regression: `config.environment` was sent verbatim as the `X-Environment` header.
    /// Foundation's `URLRequest` silently DROPS a header whose value contains a control
    /// character rather than refusing the request — so a value like
    /// `"staging\nX-Injected: 1"` isn't an injection (no header is added), it's a client that
    /// looks alive and tags every event with NO environment attribution at all.
    func testEnvironmentWithAnEmbeddedNewlineIsRejected() {
        let sink = EventSink()
        let sdk = SheepitClient.create(
            config: SheepitConfig(
                apiKey: "lp_pub_xxx_\(Self.hex)",
                environment: "staging\nX-Injected: 1",
                apiUrl: "https://stub.invalid",
                crashes: CrashConfig(enabled: false),
                onDiagnostic: { @Sendable event in sink.append(event) }
            )
        )
        XCTAssertFalse(
            sdk.status().initialized,
            "A control character in `environment` must produce an inert client, not one that " +
            "silently drops its X-Environment header on every request."
        )
        XCTAssertTrue(sink.codes.contains("lifecycle.api_key_rejected"))
    }

    func testEnvironmentWithAnEmbeddedCarriageReturnIsRejected() {
        let sdk = SheepitClient.create(
            config: SheepitConfig(
                apiKey: "lp_pub_xxx_\(Self.hex)",
                environment: "staging\r\nX-Injected: 1",
                apiUrl: "https://stub.invalid",
                crashes: CrashConfig(enabled: false)
            )
        )
        XCTAssertFalse(sdk.status().initialized)
    }

    func testEmptyEnvironmentIsRejected() {
        let sdk = SheepitClient.create(
            config: SheepitConfig(
                apiKey: "lp_pub_xxx_\(Self.hex)",
                environment: "",
                apiUrl: "https://stub.invalid",
                crashes: CrashConfig(enabled: false)
            )
        )
        XCTAssertFalse(sdk.status().initialized)
    }

    /// Ordinary environment names must still be admitted — the widened check must not reject
    /// anything it used to accept.
    func testOrdinaryEnvironmentNamesAreStillAccepted() {
        for env in ["production", "staging", "development", "qa-2"] {
            let sdk = SheepitClient.create(
                config: SheepitConfig(
                    apiKey: "lp_pub_xxx_\(Self.hex)",
                    environment: env,
                    apiUrl: "https://stub.invalid",
                    crashes: CrashConfig(enabled: false)
                )
            )
            XCTAssertTrue(sdk.status().initialized, "environment \(env.debugDescription) should be admitted")
            sdk.destroy()
        }
    }
}

private extension SheepitConfig {
    func withApiUrl(_ url: String) -> SheepitConfig {
        var copy = self
        copy.apiUrl = url
        return copy
    }
}
