import XCTest
@testable import SheepitKit

/// `ErrorCaptureLimiter` on an injected monotonic clock: the per-signature window, the global cap, the
/// bounded signature table, and the once-per-window notice.
final class ErrorCaptureLimiterTests: XCTestCase {
    private let start: TimeInterval = 1_000_000

    private func makeLimiter() -> (ErrorCaptureLimiter, LockedBox<TimeInterval>) {
        let clock = LockedBox(start)
        return (ErrorCaptureLimiter(uptime: { clock.get() }), clock)
    }

    private func advance(_ clock: LockedBox<TimeInterval>, by seconds: TimeInterval) {
        clock.mutate { $0 += seconds }
    }

    func testTheFirstCallIsSentAndRepeatsInsideTheWindowAreSuppressed() {
        let (limiter, clock) = makeLimiter()

        XCTAssertEqual(limiter.admit(signature: "a"), .send(suppressedCount: 0, droppedCount: 0))
        XCTAssertEqual(limiter.admit(signature: "a"), .suppress(notify: true))
        advance(clock, by: 59.9)
        XCTAssertEqual(limiter.admit(signature: "a"), .suppress(notify: false))
    }

    func testTheNextCallAfterTheWindowCarriesTheSuppressedCount() {
        let (limiter, clock) = makeLimiter()
        _ = limiter.admit(signature: "a")
        for _ in 0..<4 { _ = limiter.admit(signature: "a") }

        advance(clock, by: 60)

        XCTAssertEqual(limiter.admit(signature: "a"), .send(suppressedCount: 4, droppedCount: 0))
        XCTAssertEqual(limiter.admit(signature: "a"), .suppress(notify: true), "a new window, a new notice")
        advance(clock, by: 60)
        XCTAssertEqual(limiter.admit(signature: "a"), .send(suppressedCount: 1, droppedCount: 0),
                       "the count resets once reported")
    }

    func testDistinctSignaturesDoNotSuppressEachOther() {
        let (limiter, _) = makeLimiter()
        XCTAssertEqual(limiter.admit(signature: "a"), .send(suppressedCount: 0, droppedCount: 0))
        XCTAssertEqual(limiter.admit(signature: "b"), .send(suppressedCount: 0, droppedCount: 0))
    }

    func testTheGlobalCapDropsAndTheNextSendCarriesTheDroppedCount() {
        let (limiter, clock) = makeLimiter()
        for index in 0..<ErrorCaptureLimiter.globalCap {
            XCTAssertEqual(limiter.admit(signature: "s\(index)"), .send(suppressedCount: 0, droppedCount: 0))
        }

        XCTAssertEqual(limiter.admit(signature: "over-1"), .suppress(notify: true))
        XCTAssertEqual(limiter.admit(signature: "over-2"), .suppress(notify: false))

        advance(clock, by: 60)
        XCTAssertEqual(limiter.admit(signature: "next"), .send(suppressedCount: 0, droppedCount: 2))
        XCTAssertEqual(limiter.admit(signature: "after"), .send(suppressedCount: 0, droppedCount: 0))
    }

    /// Rolling, not fixed: sends spread over the window free up one slot each as they age out.
    func testTheGlobalWindowRolls() {
        let (limiter, clock) = makeLimiter()
        for index in 0..<ErrorCaptureLimiter.globalCap {
            _ = limiter.admit(signature: "s\(index)")
            advance(clock, by: 1)
        }
        // Now at start+30: the first send (at start) ages out at start+60.
        advance(clock, by: 29)
        XCTAssertEqual(limiter.admit(signature: "x"), .suppress(notify: true))
        advance(clock, by: 1)
        XCTAssertEqual(limiter.admit(signature: "y"), .send(suppressedCount: 0, droppedCount: 1))
        XCTAssertEqual(limiter.admit(signature: "z"), .suppress(notify: false))
    }

    func testTheSignatureTableIsBoundedAndAnEvictedCountIsNotLost() {
        let (limiter, clock) = makeLimiter()
        _ = limiter.admit(signature: "oldest")
        _ = limiter.admit(signature: "oldest")  // one suppressed, held by "oldest"

        for index in 0..<(ErrorCaptureLimiter.maxSignatures - 1) {
            advance(clock, by: 61)  // keep clear of the global cap
            _ = limiter.admit(signature: "s\(index)")
        }
        XCTAssertEqual(limiter.trackedSignatureCountForTesting, ErrorCaptureLimiter.maxSignatures)

        advance(clock, by: 61)
        XCTAssertEqual(limiter.admit(signature: "trigger"), .send(suppressedCount: 0, droppedCount: 0))
        XCTAssertEqual(limiter.trackedSignatureCountForTesting, ErrorCaptureLimiter.maxSignatures,
                       "one past the cap evicts the signature sent longest ago")
        XCTAssertEqual(limiter.admit(signature: "fresh"), .send(suppressedCount: 0, droppedCount: 1),
                       "the evicted signature's suppressed count moves to the dropped pool")
    }

    // MARK: - Round 2

    /// The default clock is `systemUptime`, which a wall-clock change cannot move. Compared
    /// against the source itself: a wall clock (`Date()`, ~1.7e9 s since 1970) cannot pass this.
    func testTheDefaultClockIsSystemUptime() {
        let limiter = ErrorCaptureLimiter()
        let expected = ProcessInfo.processInfo.systemUptime
        XCTAssertEqual(limiter.uptimeForTesting, expected, accuracy: 1)
    }

    /// A clock that steps backwards used to wedge every window: a brand-new signature stayed
    /// suppressed by the global cap, silently. A negative delta now counts as "window elapsed".
    func testAClockSteppedBackwardsAdmitsANewSignature() {
        let (limiter, clock) = makeLimiter()
        for index in 0..<ErrorCaptureLimiter.globalCap { _ = limiter.admit(signature: "s\(index)") }
        XCTAssertEqual(limiter.admit(signature: "blocked"), .suppress(notify: true), "precondition: cap reached")

        advance(clock, by: -365 * 24 * 3600)

        XCTAssertEqual(limiter.admit(signature: "brand-new"), .send(suppressedCount: 0, droppedCount: 1))
    }

    func testAClockSteppedBackwardsAdmitsAnOldSignature() {
        let (limiter, clock) = makeLimiter()
        _ = limiter.admit(signature: "a")
        XCTAssertEqual(limiter.admit(signature: "a"), .suppress(notify: true))

        advance(clock, by: -30)

        XCTAssertEqual(limiter.admit(signature: "a"), .send(suppressedCount: 1, droppedCount: 0))
    }

    /// With a constant clock every entry ties on `lastSent`; the old `min(by:)` could evict the
    /// signature it had just admitted. It must never, and the victim must be the earliest admitted.
    func testEvictionUnderAConstantClockKeepsTheNewSignatureAndDropsTheEarliest() {
        let limiter = ErrorCaptureLimiter(uptime: { 42 }, globalCap: .max)
        for index in 0..<ErrorCaptureLimiter.maxSignatures { _ = limiter.admit(signature: "s\(index)") }
        XCTAssertEqual(limiter.trackedSignatureCountForTesting, ErrorCaptureLimiter.maxSignatures)

        XCTAssertEqual(limiter.admit(signature: "newest"), .send(suppressedCount: 0, droppedCount: 0))

        XCTAssertTrue(limiter.isTrackedForTesting("newest"), "the just-admitted signature must survive eviction")
        XCTAssertFalse(limiter.isTrackedForTesting("s0"), "every entry ties on time: the earliest admitted goes")
        XCTAssertTrue(limiter.isTrackedForTesting("s1"))
        XCTAssertEqual(limiter.trackedSignatureCountForTesting, ErrorCaptureLimiter.maxSignatures)
    }
}
