import XCTest
@testable import SheepitKit

/// Fix round 2 (PR #1170 review), item 11: `RegistrationRetryPolicy` had NO dedicated test —
/// only exercised indirectly through `DeviceRegistrationTests`' end-to-end launch-path tests.
/// Pure, static, no dependencies — every case below is deterministic (the floor and
/// `retryAfter`-dominance paths pin an EXACT value; only the free-running jitter path needs a
/// bound instead of an exact number).
final class RegistrationRetryPolicyTests: XCTestCase {
    // MARK: - Floor

    func testFloorsAtOneSecondAtAttemptZeroWithNoRetryAfter() {
        // At failures=0, exponentialCeiling = min(3600, 1*2^0) = 1, so jitter draws from
        // [0, 1) — `max(1, jittered, 0)` is 1 EVERY time, not just on average.
        for _ in 0..<20 {
            XCTAssertEqual(
                RegistrationRetryPolicy.delay(afterFailures: 0, retryAfter: nil),
                .seconds(1),
                "the floor must win deterministically at attempt 0 — jitter alone cannot exceed it"
            )
        }
    }

    func testFloorsAtOneSecondEvenWithANegativeRetryAfter() {
        // `max(0, retryAfter ?? 0)` clamps a negative Retry-After to 0 before it can pull the
        // delay below the floor.
        XCTAssertEqual(
            RegistrationRetryPolicy.delay(afterFailures: 0, retryAfter: -30),
            .seconds(1)
        )
    }

    // MARK: - Retry-After dominance

    func testRetryAfterDominatesTheJitteredExponentialValueWhenItAsksForLonger() {
        // At failures=0 the exponential ceiling is 1s; a 1800s Retry-After must win outright.
        XCTAssertEqual(
            RegistrationRetryPolicy.delay(afterFailures: 0, retryAfter: 1_800),
            .seconds(1_800)
        )
    }

    func testRetryAfterIsCappedAtOneHourEvenWhenItAsksForLonger() {
        // A 2h Retry-After must be clamped to the 1h ceiling, not honored as-is — a
        // malformed or deliberately huge header must not wedge registration indefinitely.
        XCTAssertEqual(
            RegistrationRetryPolicy.delay(afterFailures: 0, retryAfter: 7_200),
            .seconds(3_600)
        )
    }

    func testNoRetryAfterFallsBackToTheJitteredExponentialValue() {
        // At a high enough attempt count the exponential ceiling itself exceeds 1s, so
        // `retryAfter: nil` (treated as 0) must not floor the result down to 1s.
        for _ in 0..<20 {
            let delay = RegistrationRetryPolicy.delay(afterFailures: 10, retryAfter: nil)
            XCTAssertGreaterThanOrEqual(delay, .seconds(1))
            XCTAssertLessThanOrEqual(delay, .seconds(3_600))
        }
    }

    // MARK: - Ceiling (never exceeds 1h, however high the attempt count)

    func testNeverExceedsOneHourEvenAtAnAstronomicallyHighAttemptCount() {
        for _ in 0..<20 {
            let delay = RegistrationRetryPolicy.delay(afterFailures: 1_000, retryAfter: nil)
            XCTAssertLessThanOrEqual(delay, .seconds(3_600))
            XCTAssertGreaterThanOrEqual(delay, .seconds(1))
        }
    }

    // MARK: - Jitter bounds (exponential ceiling scales with attempts, then saturates)

    func testJitterStaysWithinTheExponentialCeilingAtEachAttempt() {
        // failures=5 → exponentialCeiling = min(3600, 1*2^5) = 32 — the delay must never
        // exceed that ceiling (jitter is drawn from [0, ceiling)), and never drop below the
        // 1s floor.
        for _ in 0..<50 {
            let delay = RegistrationRetryPolicy.delay(afterFailures: 5, retryAfter: nil)
            XCTAssertGreaterThanOrEqual(delay, .seconds(1))
            XCTAssertLessThanOrEqual(delay, .seconds(32))
        }
    }

    func testExponentialCeilingSaturatesAtOneHourWellBeforeFailures12() {
        // 2^12 * 1s = 4096s > 3600s — by failures=12 the ceiling is already capped.
        for _ in 0..<20 {
            let delay = RegistrationRetryPolicy.delay(afterFailures: 12, retryAfter: nil)
            XCTAssertLessThanOrEqual(delay, .seconds(3_600))
        }
    }
}
