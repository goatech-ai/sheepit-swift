import XCTest
@testable import SheepitKit

/// Coverage for the sub-second timestamp fix (review follow-up on commit `ff9e51ab`,
/// MUST FIX 2b in the 0.4.0 gate).
///
/// `EnrichedEvent.timestamp` used to be built with `ISO8601DateFormatter()`'s default
/// options — second granularity, no fractional seconds — so two events emitted within the
/// same wall-clock second (the common case: `$app_install`/`$app_update` immediately
/// followed by `$session_start` on a fresh install) carried a BYTE-IDENTICAL timestamp on
/// the wire. `apps/api/src/lib/insights-funnel-query.ts`'s step join is strictly
/// `ev.ts > s${i}.ts_${i}` — so a tied timestamp made any funnel spanning two same-second
/// steps return zero rows, permanently.
///
/// Drives `SheepitClient.formatEventTimestamp(_:)` — the exact function `track()` calls —
/// with two fixed `Date`s in the SAME whole second, rather than racing the real wall
/// clock across two statements: real-clock timing could pass even against the OLD
/// second-granularity formatter if the two calls happened to straddle a second boundary,
/// which would make the regression test itself flaky in exactly the direction that hides
/// the bug.
final class EventTimestampPrecisionTests: XCTestCase {
    func testSameSecondTimestampsAreDistinctAndOrderedByFractionalPrecision() {
        let wholeSecond = Date(timeIntervalSince1970: 1_757_000_000)
        let earlier = SheepitClient.formatEventTimestamp(wholeSecond.addingTimeInterval(0.100))
        let later = SheepitClient.formatEventTimestamp(wholeSecond.addingTimeInterval(0.900))

        XCTAssertEqual(
            String(earlier.prefix(19)), String(later.prefix(19)),
            "sanity check: both timestamps must fall in the same whole second"
        )
        XCTAssertNotEqual(
            earlier, later,
            "two events in the same wall-clock second must not collapse to one timestamp"
        )
        XCTAssertLessThan(
            earlier, later,
            "ISO8601 with fractional seconds is lexically sortable, so the earlier " +
            "event's timestamp string must sort before the later one's"
        )
    }

    func testTimestampFormatCarriesFractionalSeconds() {
        let timestamp = SheepitClient.formatEventTimestamp(Date(timeIntervalSince1970: 1_757_000_000.123))

        XCTAssertTrue(
            timestamp.contains("."),
            "expected a fractional-seconds ISO8601 timestamp (e.g. 2025-09-04T17:46:40.123Z), " +
            "got \(timestamp)"
        )
        XCTAssertTrue(
            timestamp.hasSuffix("Z"),
            "expected the UTC 'Z' suffix from .withInternetDateTime, got \(timestamp)"
        )
    }
}
