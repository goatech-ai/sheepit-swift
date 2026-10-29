import XCTest
@testable import SheepitKit

/// `IdentifyLadder` in isolation: scripted answers, a recorded sleep, no network. The client-level
/// cases (a real device replacement, `$identify_failed` on the wire) are in `IdentifyRetryTests`.
final class IdentifyLadderTests: XCTestCase {
    /// Scripted dependencies. Each `post` takes the next answer; `nil` means nothing was sent.
    private final class Script: @unchecked Sendable {
        var answers: [IdentifyResponse?]
        var replacement: String?
        var current = true
        var posted: [String] = []
        var marked: [String] = []
        var reregistered: [String] = []
        var slept: [TimeInterval] = []
        /// Runs after the Nth post (1-based) answers.
        var afterPost: [Int: () -> Void] = [:]

        init(_ answers: [IdentifyResponse?], replacement: String? = nil) {
            self.answers = answers
            self.replacement = replacement
        }

        func deps(random: Double = 0) -> IdentifyLadder.Dependencies {
            IdentifyLadder.Dependencies(
                post: { deviceId in
                    self.posted.append(deviceId)
                    let answer = self.answers.isEmpty ? IdentifyResponse.ok : self.answers.removeFirst()
                    self.afterPost[self.posted.count]?()
                    return answer
                },
                reregister: { deviceId in
                    self.reregistered.append(deviceId)
                    return self.replacement
                },
                markBound: { self.marked.append($0) },
                isCurrent: { self.current },
                sleep: { self.slept.append($0) },
                random: { random }
            )
        }
    }

    func testABindThatSucceedsAtOnceIsBound() async {
        let script = Script([.ok])
        let result = await IdentifyLadder.run(deviceId: "dev_a", script.deps())
        XCTAssertEqual(result, .init(outcome: .bound, attempts: 1, status: 200, deviceId: "dev_a"))
        XCTAssertEqual(script.marked, ["dev_a"], "marked before the request")
    }

    func testTransientFailuresRetryAfterOneTwoAndFourSecondsThenGiveUp() async {
        let script = Script([.status(0), .status(500), .status(408), .status(429)])
        let result = await IdentifyLadder.run(deviceId: "dev_a", script.deps())
        XCTAssertEqual(result, .init(outcome: .exhausted, attempts: 4, status: 429, deviceId: "dev_a"))
        XCTAssertEqual(script.slept, [1, 2, 4])
    }

    func testABindThatSucceedsOnARetryIsBoundAfterRetry() async {
        let script = Script([.status(503), .ok])
        let result = await IdentifyLadder.run(deviceId: "dev_a", script.deps())
        XCTAssertEqual(result.outcome, .boundAfterRetry)
        XCTAssertEqual(result.attempts, 2)
    }

    /// Jitter only ever lengthens a wait (up to half again), so clients that failed together spread
    /// out without retrying sooner than asked.
    func testJitterLengthensTheWaitByUpToHalf() async throws {
        let script = Script([.status(503), .ok])
        _ = await IdentifyLadder.run(deviceId: "dev_a", script.deps(random: 0.999))
        XCTAssertEqual(script.slept.count, 1)
        XCTAssertEqual(try XCTUnwrap(script.slept.first), 1.4995, accuracy: 0.0001)
    }

    /// `503 IDENTIFY_BUSY` sends `Retry-After`; a longer one wins over the ladder's own wait, capped
    /// at 5 s so a huge header cannot park the identify chain.
    func testRetryAfterIsHonouredUpToFiveSeconds() async {
        let script = Script([
            IdentifyResponse(status: 503, retryAfter: 3, code: "IDENTIFY_BUSY"),
            IdentifyResponse(status: 503, retryAfter: 600, code: "IDENTIFY_BUSY"),
            IdentifyResponse(status: 503, retryAfter: 1, code: "IDENTIFY_BUSY"),
            .ok,
        ])
        _ = await IdentifyLadder.run(deviceId: "dev_a", script.deps())
        XCTAssertEqual(script.slept, [3, 5, 4])
    }

    func testANotFoundRegistersAReplacementOnceAndBindsIt() async {
        let script = Script([.notFound, .ok], replacement: "dev_b")
        let result = await IdentifyLadder.run(deviceId: "dev_a", script.deps())
        XCTAssertEqual(result, .init(outcome: .boundAfterReregister, attempts: 2, status: 200, deviceId: "dev_b"))
        XCTAssertEqual(script.reregistered, ["dev_a"])
        XCTAssertEqual(script.posted, ["dev_a", "dev_b"])
        XCTAssertEqual(script.marked, ["dev_a", "dev_b"])
        XCTAssertEqual(script.slept, [], "retried at once on the new device")
    }

    func testAReplacementThatIsAlsoUnknownIsNotFound() async {
        let script = Script([.notFound, .notFound], replacement: "dev_b")
        let result = await IdentifyLadder.run(deviceId: "dev_a", script.deps())
        XCTAssertEqual(result, .init(outcome: .notFound, attempts: 2, status: 404, deviceId: "dev_b"))
        XCTAssertEqual(script.reregistered, ["dev_a"], "never a second replacement")
    }

    func testNoReplacementIsNotFoundOnTheOriginalDevice() async {
        for replacement in [nil, "dev_a"] {
            let script = Script([.notFound], replacement: replacement)
            let result = await IdentifyLadder.run(deviceId: "dev_a", script.deps())
            XCTAssertEqual(result, .init(outcome: .notFound, attempts: 1, status: 404, deviceId: "dev_a"))
        }
    }

    /// Only the API's own `NOT_FOUND` means the device is unknown. A 404 from a proxy or a WAF says
    /// nothing about it, and registering a device for it would leak devices into the project's total.
    func testA404WithoutTheAPIsCodeIsFinal() async {
        let script = Script([IdentifyResponse(status: 404, retryAfter: nil, code: nil)], replacement: "dev_b")
        let result = await IdentifyLadder.run(deviceId: "dev_a", script.deps())
        XCTAssertEqual(result.outcome, .rejected)
        XCTAssertEqual(script.reregistered, [])
    }

    func testOtherClientErrorsAreFinal() async {
        for status in [400, 401, 403, 409, 422] {
            let script = Script([.status(status)])
            let result = await IdentifyLadder.run(deviceId: "dev_a", script.deps())
            XCTAssertEqual(result, .init(outcome: .rejected, attempts: 1, status: status, deviceId: "dev_a"))
        }
    }

    func testABindNoLongerWantedAfterAFailureStopsWithoutRetrying() async {
        let script = Script([.status(503), .ok])
        script.afterPost[1] = { script.current = false }
        let result = await IdentifyLadder.run(deviceId: "dev_a", script.deps())
        XCTAssertEqual(result.outcome, .stale)
        XCTAssertEqual(script.posted.count, 1)
        XCTAssertEqual(script.slept, [])
    }

    func testABindNoLongerWantedDuringTheReplacementStopsWithoutPostingToIt() async {
        let script = Script([.notFound, .ok], replacement: "dev_b")
        script.afterPost[1] = { script.current = false }
        let result = await IdentifyLadder.run(deviceId: "dev_a", script.deps())
        XCTAssertEqual(result.outcome, .stale)
        XCTAssertEqual(script.posted, ["dev_a"])
        XCTAssertEqual(script.reregistered, [], "the staleness check runs before registering")
    }

    func testABindNoLongerWantedOnceTheReplacementIsRegisteredStopsWithoutPostingToIt() async {
        let script = Script([.notFound, .ok])
        var replacement: String? = "dev_b"
        let deps = script.deps()
        let staleAfterRegistering = IdentifyLadder.Dependencies(
            post: deps.post,
            reregister: { _ in script.current = false; defer { replacement = nil }; return replacement },
            markBound: deps.markBound,
            isCurrent: deps.isCurrent,
            sleep: deps.sleep
        )
        let result = await IdentifyLadder.run(deviceId: "dev_a", staleAfterRegistering)
        XCTAssertEqual(result.outcome, .stale)
        XCTAssertEqual(script.posted, ["dev_a"])
    }

    func testAZeroOrMissingRetryAfterLeavesTheLadderWait() async {
        let script = Script([IdentifyResponse(status: 503, retryAfter: 0, code: nil), .status(503), .ok])
        _ = await IdentifyLadder.run(deviceId: "dev_a", script.deps())
        XCTAssertEqual(script.slept, [1, 2])
    }

    func testANotFoundAfterTransientRetriesStillRegistersAReplacement() async {
        let script = Script([.status(503), .notFound, .ok], replacement: "dev_b")
        let result = await IdentifyLadder.run(deviceId: "dev_a", script.deps())
        XCTAssertEqual(result, .init(outcome: .boundAfterReregister, attempts: 3, status: 200, deviceId: "dev_b"))
        XCTAssertEqual(script.posted, ["dev_a", "dev_a", "dev_b"])
    }

    /// Unlike sdk-js: a 2xx is bound even when the bind stopped being wanted while it was on the wire,
    /// because the row does hold that user (`SheepitClient.postIdentity` records it as such).
    func testASuccessAnsweredAfterTheBindStoppedBeingWantedIsStillBound() async {
        let script = Script([.ok])
        script.afterPost[1] = { script.current = false }
        let result = await IdentifyLadder.run(deviceId: "dev_a", script.deps())
        XCTAssertEqual(result.outcome, .bound)
    }

    func testNothingSentIsStaleWithNoAttempts() async {
        let script = Script([nil])
        let result = await IdentifyLadder.run(deviceId: "dev_a", script.deps())
        XCTAssertEqual(result, .init(outcome: .stale, attempts: 0, status: 0, deviceId: "dev_a"))
    }

    func testABindNotWantedFromTheStartSendsNothing() async {
        let script = Script([.ok])
        script.current = false
        let result = await IdentifyLadder.run(deviceId: "dev_a", script.deps())
        XCTAssertEqual(result.outcome, .stale)
        XCTAssertEqual(script.posted, [])
        XCTAssertEqual(script.marked, [])
    }

    // MARK: - Against reset()

    /// Each attempt's last check before its request comes after that attempt's mark: the order
    /// `SheepitClient.reset()` relies on (it moves the token, then reads the marker). Across the
    /// first attempt, a transient retry and the attempt on a replacement device.
    func testEveryAttemptIsMarkedBeforeTheCheckThatGuardsItsRequest() async {
        var log: [String] = []
        let script = Script([.status(503), .notFound, .ok], replacement: "dev_b")
        let deps = script.deps()
        let logged = IdentifyLadder.Dependencies(
            post: { log.append("post:\($0)"); return await deps.post($0) },
            reregister: deps.reregister,
            markBound: { log.append("mark:\($0)"); deps.markBound($0) },
            isCurrent: { log.append("check"); return deps.isCurrent() },
            sleep: deps.sleep
        )
        let result = await IdentifyLadder.run(deviceId: "dev_a", logged)

        XCTAssertEqual(result.outcome, .boundAfterReregister)
        XCTAssertEqual(script.posted, ["dev_a", "dev_a", "dev_b"])
        for (index, entry) in log.enumerated() where entry.hasPrefix("post:") {
            let device = entry.dropFirst("post:".count)
            XCTAssertEqual(Array(log[(index - 2)..<index]), ["mark:\(device)", "check"], "attempt at \(index): \(log)")
        }
    }

    /// A logout modelled as `SheepitClient.reset()` runs it (the token moves, then it decides from the
    /// marker whether to rotate), landed at every point of an attempt. No request may go out for a
    /// device that logout decided to keep: the server would bind the logged-out user to the row the
    /// next user is evaluated on. Checked only before the mark, a logout landing between the check
    /// and the mark kept the device and the request still went out.
    func testNoLogoutAtAnyPointOfAnAttemptKeepsADeviceTheRequestThenBinds() async {
        enum Point: CaseIterable { case firstCheck, beforeMark, afterMark, lastCheck, beforeSend }
        for point in Point.allCases {
            var token = 0
            var checks = 0
            var marked: Set<String> = []
            var kept: String?
            var posted: [String] = []
            var landed = false
            func logout(at here: Point, device: String) {
                guard here == point, !landed else { return }
                landed = true
                token += 1
                if !marked.contains(device) { kept = device }
            }
            let deps = IdentifyLadder.Dependencies(
                post: { device in
                    logout(at: .beforeSend, device: device)
                    posted.append(device)
                    return .ok
                },
                reregister: { _ in nil },
                markBound: { device in
                    logout(at: .beforeMark, device: device)
                    marked.insert(device)
                    logout(at: .afterMark, device: device)
                },
                isCurrent: {
                    checks += 1
                    logout(at: checks == 1 ? .firstCheck : .lastCheck, device: "dev_a")
                    return token == 0
                },
                sleep: { _ in }
            )
            let result = await IdentifyLadder.run(deviceId: "dev_a", deps)

            XCTAssertTrue(landed, "precondition: the logout landed at \(point)")
            if let kept {
                XCTAssertFalse(posted.contains(kept), "a request bound the logged-out user to the kept device (\(point))")
            }
            XCTAssertEqual(result.outcome, point == .beforeSend ? .bound : .stale, "\(point)")
        }
    }
}

private extension IdentifyResponse {
    static let ok = IdentifyResponse(status: 200, retryAfter: nil, code: nil)
    static let notFound = IdentifyResponse(status: 404, retryAfter: nil, code: "NOT_FOUND")
    static func status(_ status: Int) -> IdentifyResponse {
        IdentifyResponse(status: status, retryAfter: nil, code: nil)
    }
}
