// Regression for audit E-002 (Swift SDK accepted lp_sec_* keys silently):
// `Sheepit.create(config:)` now reject secret keys via `preconditionFailure`
// unless the caller opts in with `allowSecretKeyInClient = true` (XCTest only).
//
// `preconditionFailure` aborts the process, so we can't directly test the
// rejection path here without a 3rd-party test helper (e.g. Nimble's
// `expect { ... }.to(throwAssertion())`). What we CAN test:
//
// 1. Pub keys instantiate with no opt-out (the common path).
// 2. Sec keys instantiate ONLY when `allowSecretKeyInClient = true`.
// 3. Misuse of the opt-out is opt-in by the caller — defaults guard.

import XCTest
@testable import SheepitSDK

final class SecretKeyGuardTests: XCTestCase {
    func testPubKeyAccepted() {
        let cfg = SheepitConfig(apiKey: "lp_pub_xxx_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        let sdk = Sheepit.create(config: cfg)
        XCTAssertNotNil(sdk)
        sdk.destroy()
    }

    func testSecKeyAcceptedWithExplicitOptIn() {
        // Tests that intentionally use sec keys (e.g. server-side fixtures)
        // can opt out of the guard. Production iOS callers MUST NOT set this
        // flag — it would re-introduce the audit-E-002 leak.
        let cfg = SheepitConfig(
            apiKey: "lp_sec_xxx_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            allowSecretKeyInClient: true
        )
        let sdk = Sheepit.create(config: cfg)
        XCTAssertNotNil(sdk)
        sdk.destroy()
    }

    func testAllowSecretKeyInClientDefaultsFalse() {
        let cfg = SheepitConfig(apiKey: "lp_pub_xxx_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
        XCTAssertFalse(
            cfg.allowSecretKeyInClient,
            "SheepitConfig.allowSecretKeyInClient must default to false. Audit E-002."
        )
    }
}
