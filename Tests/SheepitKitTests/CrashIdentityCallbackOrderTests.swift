import XCTest
@testable import SheepitKit

/// New publication diagnostics run after all outer identity/reset mutations and bind scheduling.
final class CrashIdentityCallbackOrderTests: XCTestCase {
    override func setUp() {
        SharedSDKStorage.clear()
        AttributionCaptureProtocol.reset()
        TeardownFlushes.install()
    }
    override func tearDown() async throws {
        await TeardownFlushes.drain(context: name)
        SharedSDKStorage.clear()
        AttributionCaptureProtocol.reset()
    }

    @MainActor
    func testDiagnosticFlagReadIsNotForgottenByTheOuterIdentify() async throws {
        SharedSDKStorage.markRegistered()
        AttributionCaptureProtocol.setIdentifyReply(.hold, for: "callback-user")
        defer { AttributionCaptureProtocol.releaseHeldIdentify() }
        let holder = LockedBox<SheepitClient?>(nil)
        let exposures = LockedBox(0)
        let client = try await makeOwnedCrashClient(in: self, directory: CrashFixtures.tempDirectory("identity-callback-flag"),
            onDiagnostic: { event in
                guard event.code == "identity.crash_cohort", let client = holder.get() else { return }
                _ = client.flag("callback_flag")
            }, onEvent: { event, _ in
                if event == "$flag_exposure" { exposures.mutate { $0 += 1 } }
            })
        holder.set(client)
        defer { holder.set(nil) }
        client.applyConfigForTesting(flags: ["callback_flag": AnyCodable(true)], assignments: [:], appliedUnder: .fetchedUnder(nil))
        client.identify(userId: "callback-user")
        XCTAssertEqual(client.flag("callback_flag"), .bool(true))
        XCTAssertEqual(exposures.get(), 1, "the listener's decision must not be forgotten after it returns")
    }

    @MainActor
    func testResetDiagnosticCannotBeFollowedByTheOuterConfigClear() async throws {
        SharedSDKStorage.markRegistered()
        AttributionCaptureProtocol.setIdentifyReply(.hold, for: "new-user-after-reset")
        defer { AttributionCaptureProtocol.releaseHeldIdentify() }
        let holder = LockedBox<SheepitClient?>(nil)
        let fired = LockedBox(false)
        let client = try await makeOwnedCrashClient(in: self, directory: CrashFixtures.tempDirectory("reset-callback-identity"),
            onDiagnostic: { event in
                guard event.code == "identity.crash_cohort", let client = holder.get(), !fired.get() else { return }
                fired.set(true)
                client.identify(userId: "new-user-after-reset")
                client.applyConfigForTesting(flags: ["after_reset": AnyCodable(true)], assignments: [:],
                    appliedUnder: .fetchedUnder("new-user-after-reset"))
            })
        holder.set(client)
        defer { holder.set(nil) }
        client.reset()
        XCTAssertTrue(fired.get())
        XCTAssertEqual(client.context.userId, "new-user-after-reset")
        XCTAssertEqual(client.flag("after_reset"), .bool(true), "outer reset must have finished its clears before invoking host code")
    }
}
