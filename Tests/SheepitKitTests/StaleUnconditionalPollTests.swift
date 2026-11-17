import XCTest
@testable import SheepitKit

/// A7b round 4 (B1): an unconditional fetch owed since an EARLIER failed refetch must not release
/// a newer one. Through the real `ConfigSync` and `ExperimentManager`, on the scripted stub API.
final class StaleUnconditionalPollTests: XCTestCase {
    private static let configBody = #"""
    {"data":{"config_version":"7","etag":"\"v7\"","flags":{},"experiments":{
      "onboarding_test":{"variant_key":"b","payload":{},"experiment_id":"22222222-2222-4222-8222-222222222222","subject_kind":"device","bucketing_version":1,"assignment_revision":"7"}}}}
    """#

    override func setUp() {
        super.setUp()
        AttributionCaptureProtocol.reset()
    }

    override func tearDown() {
        AttributionCaptureProtocol.reset()
        super.tearDown()
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    /// 1. A refetch fails, so every later fetch goes unconditional. 2. `identify("user-b")` arms the
    /// switch. 3. Poll F starts, unconditional. 4. The bind fails without moving the label, and the
    /// settle records F. 5. The settle's refetch fails. 6. F lands under `.unknown`; F started
    /// before the settle, so it cannot end the switch. 7. Before the fix F released the flag and
    /// kept its ETag, so the next poll was a 304 that applied nothing and the switch stayed armed
    /// until relaunch. The next successful fetch must end it.
    func testAPollOwedByAnEarlierRefetchCannotReleaseTheSettlesRefetch() async {
        AttributionCaptureProtocol.serveConfig(Self.configBody)
        let manager = ExperimentManager(storage: InMemoryStorage())
        let sync = ConfigSync(
            http: HTTPClient(
                config: SheepitConfig(apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64),
                                      apiUrl: "https://stub.invalid", retryAttempts: 1),
                log: Logger(debug: false),
                urlProtocolClasses: [AttributionCaptureProtocol.self]),
            storage: InMemoryStorage(),
            refreshInterval: 3600,
            log: Logger(debug: false),
            // The bind's failure is a no-op on the label: the epoch never moves.
            identityProvider: { (.unknown, 0) },
            onConfig: { response, identity, origin in
                manager.setAssignments(response.experiments, appliedUnder: identity, origin: origin)
            }
        )

        await sync.refresh(deviceId: "device-1")
        AttributionCaptureProtocol.failNextConfigRequests(1)
        await sync.refetchUnconditionally(deviceId: "device-1")                      // 1
        let token = manager.beginIdentitySwitch(to: "user-b")                         // 2

        AttributionCaptureProtocol.scriptConfig([(Self.configBody, 0.5)])
        let pollF = Task { await sync.refresh(deviceId: "device-1") }                 // 3
        let sent = await waitUntil { AttributionCaptureProtocol.configRequestCount == 3 }
        XCTAssertTrue(sent, "precondition: poll F is on the wire")
        XCTAssertEqual(AttributionCaptureProtocol.configIfNoneMatch.last, .some(nil),
                       "precondition: F is unconditional because the earlier refetch failed")
        let settled = manager.identityBindSettledWithoutAck(token, afterFetch: sync.fetchesStarted.current)
        XCTAssertTrue(settled, "precondition: the bind settled while F was on the wire")      // 4
        AttributionCaptureProtocol.failNextConfigRequests(1)
        await sync.refetchUnconditionally(deviceId: "device-1")                      // 5
        await pollF.value                                                             // 6
        XCTAssertTrue(manager.capture().identitySwitchPending,
                      "precondition: F started before the settle, so it cannot end the switch")

        await sync.refresh(deviceId: "device-1")                                      // 7
        XCTAssertEqual(AttributionCaptureProtocol.configIfNoneMatch.count, 5)
        XCTAssertEqual(AttributionCaptureProtocol.configIfNoneMatch.last, .some(nil),
                       "F must not release the refetch the settle still owes, nor keep F's ETag")
        XCTAssertFalse(manager.capture().identitySwitchPending,
                       "the next successful fetch ends the switch")
    }
}
