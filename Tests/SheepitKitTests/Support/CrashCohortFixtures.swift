import Foundation
import XCTest
import SheepitCrashHandler
@testable import SheepitKit

/// Production atomic snapshots serialized in the new supplement, with frozen legacy fixtures.
enum CrashCohortFixtures {
    static func capture(
        user: String? = "user-A", device: String = "device-A", session: String? = "session-A",
        token: String? = "receipt-A", changed: Bool = false
    ) -> sheepit_crash_cohort_t {
        XCTAssertTrue(sheepit_crash_cohort_set(user, device, session, token, changed))
        var cohort = sheepit_crash_cohort_t()
        sheepit_crash_cohort_snapshot(&cohort)
        return cohort
    }

    static func write(
        _ cohort: sheepit_crash_cohort_t, to url: URL,
        timestamp: UInt64 = CrashFixtures.timestampMs, imageCount: UInt32 = 2,
        formatVersion: UInt32 = UInt32(SHEEPIT_SUPPLEMENT_COHORT_VERSION)
    ) throws {
        var supplement = sheepit_crash_supplement_v3_t()
        supplement.legacy.format_version = formatVersion
        supplement.legacy.report_timestamp_ms = timestamp
        supplement.legacy.image_count = imageCount
        supplement.legacy.magic = UInt32(SHEEPIT_SUPPLEMENT_MAGIC)
        supplement.cohort = cohort
        try withUnsafeBytes(of: &supplement) { try Data($0).write(to: url) }
    }

    static func writeLegacyV2(
        to url: URL, token: String = "receipt-v2", timestamp: UInt64 = CrashFixtures.timestampMs,
        imageCount: UInt32 = 2, magic: UInt32 = UInt32(SHEEPIT_SUPPLEMENT_MAGIC)
    ) throws {
        var supplement = sheepit_crash_supplement_v2_t()
        supplement.legacy.format_version = UInt32(SHEEPIT_SUPPLEMENT_ASSIGNMENT_VERSION)
        supplement.legacy.report_timestamp_ms = timestamp
        supplement.legacy.image_count = imageCount
        supplement.legacy.magic = magic
        CrashFixtures.setCString(&supplement.assignment.token, token)
        try withUnsafeBytes(of: &supplement) { try Data($0).write(to: url) }
    }
}
