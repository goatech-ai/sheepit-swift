import XCTest
@testable import SheepitKit

/// `RegistrationPolicy` + `RegistrationBackoff` + `DeviceManager.classify` on their own:
/// `Docs/Technical/SDK_DEVICE_REGISTRATION_CONTRACT.md` § 1 and § 3, acceptance tests 5
/// (escalation across launches) and 7 (one atomic record; a failed write is logged).
final class RegistrationPolicyTests: XCTestCase {
    /// Records every write, and can refuse to keep one key.
    private final class RecordingStorage: StorageProvider, @unchecked Sendable {
        private let lock = NSLock()
        private var store: [String: Any] = [:]
        private(set) var writes: [String] = []
        var dropWritesTo: String?

        func string(forKey key: String) -> String? { lock.lock(); defer { lock.unlock() }; return store[key] as? String }
        func data(forKey key: String) -> Data? { lock.lock(); defer { lock.unlock() }; return store[key] as? Data }
        func set(_ value: String?, forKey key: String) { put(value, key) }
        func set(_ value: Data?, forKey key: String) { put(value, key) }
        func removeObject(forKey key: String) { lock.lock(); store.removeValue(forKey: key); lock.unlock() }
        var keys: Set<String> { lock.lock(); defer { lock.unlock() }; return Set(store.keys) }

        private func put(_ value: Any?, _ key: String) {
            lock.lock()
            defer { lock.unlock() }
            writes.append(key)
            guard key != dropWritesTo else { return }
            store[key] = value
        }
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ value: Date) { self.value = value }
        var now: Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: TimeInterval) { lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock() }
    }

    private func policy(_ storage: StorageProvider, _ clock: Clock, bus: DiagnosticBus = DiagnosticBus()) -> RegistrationPolicy {
        let policy = RegistrationPolicy(storage: storage, diagnostics: bus, log: Logger(debug: false), now: { clock.now }, appVersion: "1.0")
        policy.jitterForTesting = { upper in upper } // the top of every full-jitter range
        return policy
    }

    // MARK: - 5. Escalation across launches

    func testFailuresTotalEscalatesAcrossLaunchesToTheOneHourCeiling() {
        let storage = RecordingStorage()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        var windows: [TimeInterval] = []
        for _ in 0..<14 {
            // Each iteration is a new launch: a fresh policy (fresh budget) over the same storage.
            let launch = policy(storage, clock)
            XCTAssertNil(launch.openWindow(), "each launch starts after the previous window")
            windows.append(launch.recordFailure(.rateLimited) ?? -1)
            clock.advance(windows.last! + 1)
        }
        XCTAssertEqual(windows, [2, 4, 8, 16, 32, 64, 128, 256, 512, 1024, 2048, 3600, 3600, 3600],
                       "ceiling min(1 h, 2 s · 2^failures_total BEFORE the failure), carried across launches")
        let record = RegistrationBackoff.load(storage: storage, now: clock.now)
        XCTAssertEqual(record?.failuresTotal, 14)
    }

    func testTransientWindowsCapAtSixtySecondsAndTerminalIsAFlatDayThatStillCounts() {
        let storage = RecordingStorage()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let launch = policy(storage, clock)
        var last: TimeInterval = 0
        for _ in 0..<10 {
            last = launch.recordFailure(.transient) ?? -1
            clock.advance(last + 1)
        }
        XCTAssertEqual(last, RegistrationPolicy.transientCeilingSeconds)
        XCTAssertNil(launch.recordFailure(.terminal), "a terminal answer stops the chain")
        let record = RegistrationBackoff.load(storage: storage, now: clock.now)
        XCTAssertEqual(record?.until, clock.now.timeIntervalSince1970 + SDKDefaults.deviceRegistrationTerminalBackoff)
        XCTAssertEqual(record?.failuresTotal, 11, "a terminal window increments failures_total too")
    }

    func testALongerRetryAfterWinsClampedToOneHour() {
        let jitter: @Sendable (Double) -> Double = { _ in 0 }
        XCTAssertEqual(RegistrationPolicy.window(for: .rateLimited, failuresBefore: 0, retryAfter: 120, jitter: jitter), 120)
        XCTAssertEqual(RegistrationPolicy.window(for: .cap, failuresBefore: 0, retryAfter: 90_000, jitter: jitter), 3600)
        XCTAssertEqual(RegistrationPolicy.window(for: .cap, failuresBefore: 0, retryAfter: nil, jitter: jitter), 1, "1 s floor")
        XCTAssertEqual(RegistrationPolicy.window(for: .rateLimited, failuresBefore: 5, retryAfter: 0.2, jitter: { $0 }), 64,
                       "a shorter Retry-After does not shorten the jittered wait")
        XCTAssertEqual(RegistrationPolicy.window(for: .transient, failuresBefore: 0, retryAfter: 600, jitter: jitter), 600,
                       "Retry-After is honoured on every non-terminal answer, a 5xx included, past the 60 s cap")
        XCTAssertEqual(RegistrationPolicy.window(for: .transient, failuresBefore: 0, retryAfter: 90_000, jitter: jitter), 3600)
    }

    // MARK: - Q2: the first retry is jittered in [1 s, 2 s]

    /// Deterministic: a seeded SplitMix64 drives the production formula, so this shows the draw is
    /// actually used (the window varies) and stays inside the range, without flaking.
    func testTheFirstRetryIsJitteredBetweenOneAndTwoSeconds() {
        let rng = SeededGenerator(seed: 0x5EED)
        let windows = (0..<64).map { _ in
            RegistrationPolicy.window(for: .transient, failuresBefore: 0, retryAfter: nil, jitter: { upper in rng.nextUnit() * upper })
        }
        XCTAssertTrue(windows.allSatisfy { (1...2).contains($0) }, "\(windows)")
        XCTAssertGreaterThan(Set(windows).count, 32, "the jitter varies; a constant 1 s would be one value")
        XCTAssertLessThan(windows.min() ?? 2, 1.25)
        XCTAssertGreaterThan(windows.max() ?? 1, 1.75)
        // Uniform on [1 s, ceiling] (`floor + rand·(ceiling − floor)`), NOT `max(1, rand·ceiling)`,
        // which would put about half of every draw exactly on the floor.
        XCTAssertLessThanOrEqual(windows.filter { $0 == RegistrationPolicy.floorSeconds }.count, 1, "no point mass at the floor")
    }

    func testAnOpenWindowIsNeverShortenedOrMovedLaterByALaterAnswer() {
        let storage = RecordingStorage()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        let launch = policy(storage, clock)
        _ = launch.recordFailure(.rateLimited, retryAfter: 600)
        let opened = RegistrationBackoff.load(storage: storage, now: clock.now)?.until
        clock.advance(10)
        _ = launch.recordFailure(.transient)
        _ = launch.recordFailure(.rateLimited, retryAfter: 3_000)
        XCTAssertEqual(RegistrationBackoff.load(storage: storage, now: clock.now)?.until, opened)
    }

    func testTheBudgetIsSixConsecutiveFailuresAndASuccessResetsIt() {
        let launch = policy(RecordingStorage(), Clock(Date()))
        var allowed: [Bool] = []
        for _ in 0..<7 {
            allowed.append(launch.takeAttempt())
            if allowed.last == true { launch.recordFailure(.transient) }
        }
        XCTAssertEqual(allowed, [true, true, true, true, true, true, false])
        launch.recordSuccess("device-1")
        XCTAssertTrue(launch.takeAttempt(), "a success (a later rotation, say) starts a fresh budget")
    }

    // MARK: - 7. One atomic record; a failed write is logged

    func testEveryFailureWritesOneRecordUnderOneKey() throws {
        let storage = RecordingStorage()
        let clock = Clock(Date(timeIntervalSince1970: 1_800_000_000))
        _ = policy(storage, clock).recordFailure(.transient)

        XCTAssertEqual(storage.writes, [StorageKeys.deviceRegistrationBackoff], "one serialized write, one key")
        XCTAssertEqual(storage.keys, [StorageKeys.deviceRegistrationBackoff])
        let raw = try XCTUnwrap(storage.string(forKey: StorageKeys.deviceRegistrationBackoff))
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["until", "failures_total", "sdk_version"])
    }

    func testAFailedWriteIsLoggedNotSwallowed() {
        let storage = RecordingStorage()
        storage.dropWritesTo = StorageKeys.deviceRegistrationBackoff
        let bus = DiagnosticBus()
        _ = policy(storage, Clock(Date()), bus: bus).recordFailure(.cap)
        XCTAssertTrue(bus.getRecentDiagnostics().contains { $0.code == "identity.device_registration_backoff_write_failed" })
    }

    func testAnUnreadableRecordIsClearedAndLoggedNeverActive() {
        let storage = RecordingStorage()
        storage.set("{not json", forKey: StorageKeys.deviceRegistrationBackoff)
        let bus = DiagnosticBus()
        XCTAssertNil(policy(storage, Clock(Date()), bus: bus).openWindow())
        XCTAssertNil(storage.string(forKey: StorageKeys.deviceRegistrationBackoff))
        XCTAssertTrue(bus.getRecentDiagnostics().contains { $0.code == "identity.device_registration_backoff_unreadable" })
    }

    func testTheRegisteredMarkerNeedsTheSameIdAndAppVersion() {
        let storage = RecordingStorage()
        let launch = policy(storage, Clock(Date()))
        launch.recordSuccess("device-1")
        XCTAssertTrue(launch.isRegistered("device-1"))
        XCTAssertFalse(launch.isRegistered("device-2"))
        storage.set("0.9", forKey: StorageKeys.deviceRegisteredAppVersion)
        XCTAssertFalse(launch.isRegistered("device-1"), "another app version registers again")
    }

    // MARK: - § 1 / § 3: what an answer means

    func testAnUnusableAdoptedIdIsTransientAndNeverAdopted() {
        for bad in ["", "has space", ".", "..", "del\u{7F}x", String(repeating: "a", count: 257), "é"] {
            let body = #"{"data":{"device_id":"\#(bad)","anonymous_id":"a","flag_assignments":{},"experiment_assignments":{},"config":{"flush_interval_ms":1,"flush_size":1}}}"#
            guard case .transientFailure(let reason, _) = DeviceManager.classify(status: 201, body: Data(body.utf8), response: nil, log: Logger(debug: false)) else {
                return XCTFail("\(bad) must not be adopted")
            }
            XCTAssertEqual(reason, "unusable_device_id")
        }
        XCTAssertTrue(DeviceManager.isUsableDeviceId("dev_0f3a:prod.1-x"))
        XCTAssertTrue(DeviceManager.isUsableDeviceId("slash/inside~!"), "USABLE is printable ASCII, wider than what is minted")
    }

    func testAServerReturningALegacyShapedIdIsAdopted() {
        let body = #"{"data":{"device_id":"legacy:odd","anonymous_id":"a","flag_assignments":{},"experiment_assignments":{},"config":{"flush_interval_ms":1,"flush_size":1}}}"#
        guard case .success(let id) = DeviceManager.classify(status: 200, body: Data(body.utf8), response: nil, log: Logger(debug: false)) else {
            return XCTFail("a usable legacy id is adopted")
        }
        XCTAssertEqual(id, "legacy:odd")
    }

    func testStatusMapping() throws {
        let log = Logger(debug: false)
        let url = try XCTUnwrap(URL(string: "https://stub.invalid"))
        let withRetryAfter = HTTPURLResponse(url: url, statusCode: 402, httpVersion: nil, headerFields: ["Retry-After": "30"])
        guard case .capReached(_, let retryAfter) = DeviceManager.classify(status: 402, body: Data(#"{"error":{"code":"PREVIEW_LIMIT_EXCEEDED","message":"cap"}}"#.utf8), response: withRetryAfter, log: log) else {
            return XCTFail("402 is the cap class")
        }
        XCTAssertEqual(retryAfter, 30, "a 402/422 keeps its Retry-After (0.9.x discarded it)")
        guard case .transientFailure(let reason, _) = DeviceManager.classify(status: 201, body: Data("{}".utf8), response: nil, log: log) else {
            return XCTFail("a malformed 2xx is transient")
        }
        XCTAssertEqual(reason, "malformed_response")
        let unavailable = HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: ["Retry-After": "90"])
        guard case .transientFailure(_, let serverRetryAfter) = DeviceManager.classify(status: 503, body: Data(), response: unavailable, log: log) else {
            return XCTFail("503 is transient")
        }
        XCTAssertEqual(serverRetryAfter, 90, "a 503's Retry-After is kept (RFC 9110 § 10.2.3)")
    }

    // MARK: - S1: the class is decided by OUR envelope, row by row

    private enum Class: Equatable { case success, terminal, cap, rateLimited, transient }

    private func classOf(_ status: Int, _ body: String) -> Class {
        switch DeviceManager.classify(status: status, body: Data(body.utf8), response: nil, log: Logger(debug: false)) {
        case .success: return .success
        case .terminalFailure: return .terminal
        case .capReached: return .cap
        case .rateLimited: return .rateLimited
        case .transientFailure: return .transient
        }
    }

    private func envelope(_ code: String) -> String { #"{"error":{"code":"\#(code)","message":"m"}}"# }

    func testRow1ASuccessfulAnswerTakesTheSuccessPath() {
        let ok = #"{"data":{"device_id":"d-1","anonymous_id":"a","flag_assignments":{},"experiment_assignments":{},"config":{"flush_interval_ms":1,"flush_size":1}}}"#
        XCTAssertEqual(classOf(201, ok), .success)
    }

    func testRow2AValidationErrorEnvelopeOnAny4xxIsTerminal() {
        XCTAssertEqual(classOf(400, envelope("VALIDATION_ERROR")), .terminal)
        XCTAssertEqual(classOf(422, envelope("VALIDATION_ERROR")), .terminal, "a 422 VALIDATION_ERROR is not a cap")
        XCTAssertEqual(classOf(409, envelope("VALIDATION_ERROR")), .terminal)
    }

    func testRow3A401Or403WithAnEnvelopeIsTerminal() {
        XCTAssertEqual(classOf(401, envelope("API_KEY_REVOKED")), .terminal)
        XCTAssertEqual(classOf(403, envelope("FORBIDDEN")), .terminal)
    }

    func testRow4A402Or422WithAnyOtherEnvelopeCodeIsTheCapClass() {
        XCTAssertEqual(classOf(402, envelope("PREVIEW_LIMIT_EXCEEDED")), .cap)
        XCTAssertEqual(classOf(422, envelope("LIMIT_REACHED")), .cap)
    }

    func testRow5A429IsRateLimitedWithOrWithoutAnEnvelope() {
        XCTAssertEqual(classOf(429, ""), .rateLimited)
        XCTAssertEqual(classOf(429, envelope("RATE_LIMITED")), .rateLimited)
    }

    func testRow6Every4xxWithoutOurEnvelopeAndEverythingElseIsTransient() {
        for status in [400, 401, 402, 403, 404, 409, 422] {
            for body in ["", "<html>blocked</html>", #"{"error":{"code":"X"}}"#, #"{"message":"m"}"#] {
                XCTAssertEqual(classOf(status, body), .transient, "\(status) \(body.debugDescription)")
            }
        }
        XCTAssertEqual(classOf(404, envelope("NOT_FOUND")), .transient)
        XCTAssertEqual(classOf(503, envelope("UNAVAILABLE")), .transient)
        XCTAssertEqual(classOf(302, ""), .transient)
    }

    func testRetryAfterIsClampedToAFiniteHour() {
        XCTAssertNil(HTTPClient.parseRetryAfter("inf"), "an infinite value would trap Int(backoff) in Transport")
        XCTAssertNil(HTTPClient.parseRetryAfter("nan"))
        XCTAssertEqual(HTTPClient.parseRetryAfter("999999"), 3600)
        XCTAssertEqual(HTTPClient.parseRetryAfter("-5"), 0)
        XCTAssertEqual(HTTPClient.parseRetryAfter("120"), 120)
    }

    // MARK: - Q1: 401/403 are terminal only with our API's error envelope

    func testA401Or403IsTerminalOnlyWithTheAPIsErrorEnvelope() {
        let log = Logger(debug: false)
        let envelope = Data(#"{"error":{"code":"API_KEY_REVOKED","message":"This key was revoked."}}"#.utf8)
        for status in [401, 403] {
            guard case .terminalFailure(let rejection) = DeviceManager.classify(status: status, body: envelope, response: nil, log: log) else {
                return XCTFail("\(status) with our envelope is terminal")
            }
            XCTAssertEqual(rejection.reason, "API_KEY_REVOKED")
            for body in ["", "<html>Forbidden by WAF</html>", #"{"error":{"code":"FORBIDDEN"}}"#, #"{"message":"denied"}"#] {
                guard case .transientFailure(let reason, _) = DeviceManager.classify(status: status, body: Data(body.utf8), response: nil, log: log) else {
                    return XCTFail("\(status) \(body.debugDescription) without the envelope must be transient, not a 24 h blackout")
                }
                XCTAssertEqual(reason, "auth_rejected_unrecognized")
            }
        }
    }
}

/// SplitMix64: a tiny seeded generator, so the jitter test is reproducible.
private final class SeededGenerator: @unchecked Sendable {
    private let lock = NSLock()
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    /// Uniform in [0, 1).
    func nextUnit() -> Double {
        lock.lock()
        defer { lock.unlock() }
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}
