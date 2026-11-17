import XCTest
import SheepitCrashHandler
@testable import SheepitKit

/// Identity transitions publish synchronously through the real client, without a session rollover.
final class CrashIdentityPublicationTests: XCTestCase {
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
    func testIdentifyRefreshesTheCrashUserWithoutChangingDeviceOrSession() async throws {
        let dir = CrashFixtures.tempDirectory("identity-publication")
        let client = try await makeOwnedCrashClient(in: self, directory: dir)
        client.reset()
        let context = try XCTUnwrap(sheepit_get_crash_context())
        let device = CrashText.string(context.pointee.device_id)
        let session = CrashText.string(context.pointee.session_id)
        client.identify(userId: "identity-B")
        XCTAssertEqual(CrashText.string(context.pointee.user_id), "identity-B")
        XCTAssertEqual(CrashText.string(context.pointee.device_id), device)
        XCTAssertEqual(CrashText.string(context.pointee.session_id), session)
    }
}
