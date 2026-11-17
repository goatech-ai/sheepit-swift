import XCTest
import Darwin
import SheepitCrashHandler
@testable import SheepitKit

/// Full valid IDs and opaque receipts stay one saved cohort across capture, corruption and replay.
final class CrashIdentityCohortTests: XCTestCase {
    private var dir: URL!
    private var report: URL { dir.appendingPathComponent("report.crash") }
    private var supplement: URL { dir.appendingPathComponent("report.supplement") }

    override func setUp() {
        dir = CrashFixtures.tempDirectory("identity-cohort")
    }

    override func tearDown() {
        sheepit_crash_cohort_set(nil, nil, nil, nil, false)
        try? FileManager.default.removeItem(at: dir)
    }

    func testFullUnicodeAndSharedPrefixIdentitiesSurviveSavedPayloadRoundTrip() throws {
        try CrashFixtures.writeReport(to: report)
        let ids = [String(repeating: "a", count: 256), String(repeating: "界", count: 100),
                   String(repeating: "界", count: 256), String(repeating: "😀", count: 128),
                   String(repeating: "p", count: 255) + "A", String(repeating: "p", count: 255) + "B"]
        XCTAssertEqual(ids[2].utf8.count, 768)
        for id in ids {
            let cohort = CrashCohortFixtures.capture(user: id, device: id, session: id)
            try CrashCohortFixtures.write(cohort, to: supplement)
            let payload = try XCTUnwrap(CrashReportReader.read(from: report.path, supplementPath: supplement.path))
            XCTAssertEqual(payload.userId, id)
            XCTAssertEqual(payload.deviceId, id)
            XCTAssertEqual(payload.sessionId, id)
            XCTAssertEqual(payload.captureIdentityOutcome, "coherent")
            let saved = try XCTUnwrap(CrashSupplement.load(
                path: supplement.path, reportTimestampMs: CrashFixtures.timestampMs, reportImageCount: 2))
            XCTAssertEqual(saved.identityCohort?.assignmentToken, "receipt-A")
            XCTAssertEqual(try CrashFixtures.wireJSON(payload)["assignment_token"] as? String, "receipt-A")
        }
    }

    func testSavedIdentityAndReceiptNeverComeFromTheNextLaunch() throws {
        try CrashFixtures.writeReport(to: report)
        let captured = CrashCohortFixtures.capture(user: "saved-user", device: "saved-device", token: "saved-receipt")
        try CrashCohortFixtures.write(captured, to: supplement)
        _ = CrashCohortFixtures.capture(user: "uploading-user", device: "uploading-device", token: "current-receipt")
        let store = PendingCrashStore(directory: dir.appendingPathComponent("pending"))
        let entry = try XCTUnwrap(store.adopt(liveFile: report, liveSupplement: supplement, now: Date(), maxReports: 5).entry)
        let payload = try XCTUnwrap(CrashReportReader.read(
            from: entry.url.path, supplementPath: store.supplementURL(for: entry).path))
        XCTAssertEqual(payload.userId, "saved-user")
        XCTAssertEqual(payload.deviceId, "saved-device")
        let saved = try XCTUnwrap(CrashSupplement.load(path: store.supplementURL(for: entry).path,
            reportTimestampMs: CrashFixtures.timestampMs, reportImageCount: 2))
        XCTAssertEqual(saved.identityCohort?.assignmentToken, "saved-receipt")
    }

    func testNullAndMarkedReceiptsPreserveTheirCapturedIdentity() throws {
        try CrashFixtures.writeReport(to: report)
        for (token, changed) in [(nil, false), ("held-receipt", true)] as [(String?, Bool)] {
            try CrashCohortFixtures.write(CrashCohortFixtures.capture(user: nil, session: nil,
                token: token, changed: changed), to: supplement)
            let saved = try XCTUnwrap(CrashSupplement.load(path: supplement.path,
                reportTimestampMs: CrashFixtures.timestampMs, reportImageCount: 2))
            XCTAssertNil(saved.identityCohort?.userId)
            XCTAssertNil(saved.identityCohort?.sessionId)
            XCTAssertEqual(saved.identityCohort?.assignmentToken, token)
            XCTAssertEqual(saved.identityCohort?.identityChanged, changed)
        }
    }

    func testReaderNeverShipsATokenForAMarkedCohortFromAnOlderBuild() throws {
        try CrashFixtures.writeReport(to: report)
        try CrashCohortFixtures.write(CrashCohortFixtures.capture(user: "u", token: "held-receipt", changed: true), to: supplement)
        let payload = try XCTUnwrap(CrashReportReader.read(from: report.path, supplementPath: supplement.path))
        XCTAssertNil(payload.assignmentToken, "identity_changed makes no claim, whatever the saved bytes carry")
        XCTAssertEqual(payload.assignmentStatus, "identity_changed")
    }

    func testCorruptCohortRefusesAttributionWithoutRepairingSavedBytes() throws {
        try CrashFixtures.writeReport(to: report)
        let mutations: [(inout sheepit_crash_cohort_t) -> Void] = [
            { $0.valid = 0 }, { $0.generation |= 1 }, { $0.has_user = 2 },
            { $0.has_session = 2 }, { $0.reserved = 1 }, { $0.assignment.identity_changed = 2 },
            { _ = withUnsafeMutableBytes(of: &$0.user_id) { $0.initializeMemory(as: UInt8.self, repeating: 97) } },
            { withUnsafeMutableBytes(of: &$0.user_id) { $0[0] = 0xff } },
            { withUnsafeMutableBytes(of: &$0.assignment.token) { $0[0] = 0xff } },
            { CrashFixtures.setCString(&$0.user_id, String(repeating: "a", count: 257)) },
            { $0.device_id = sheepit_crash_cohort_t().device_id },
            { $0.has_user = 0 }, { $0.has_session = 0 },
        ]
        for mutate in mutations {
            var cohort = CrashCohortFixtures.capture()
            mutate(&cohort)
            try CrashCohortFixtures.write(cohort, to: supplement)
            let bytes = try Data(contentsOf: supplement)
            let payload = try XCTUnwrap(CrashReportReader.read(from: report.path, supplementPath: supplement.path))
            XCTAssertEqual(payload.captureIdentityOutcome, "unavailable")
            XCTAssertNil(payload.userId)
            XCTAssertNil(payload.deviceId)
            XCTAssertNil(payload.sessionId)
            XCTAssertEqual(try Data(contentsOf: supplement), bytes)
        }
    }

    func testOldFormatsAndTimestampSizeFencesRemainReadableOrRefused() throws {
        try CrashFixtures.writeReport(to: report)
        try CrashFixtures.writeSupplement(to: supplement)
        XCTAssertEqual(CrashReportReader.read(from: report.path, supplementPath: supplement.path)?.captureIdentityOutcome, "legacy")
        try CrashCohortFixtures.writeLegacyV2(to: supplement)
        var receipt = sheepit_assignment_receipt_t()
        XCTAssertTrue(sheepit_read_crash_assignment(supplement.path, CrashFixtures.timestampMs, &receipt))
        XCTAssertEqual(CrashText.string(receipt.token), "receipt-v2")
        XCTAssertEqual(CrashReportReader.read(from: report.path, supplementPath: supplement.path)?.captureIdentityOutcome, "legacy")
        try CrashCohortFixtures.write(CrashCohortFixtures.capture(), to: supplement, timestamp: CrashFixtures.timestampMs + 1)
        XCTAssertNil(CrashSupplement.load(path: supplement.path, reportTimestampMs: CrashFixtures.timestampMs, reportImageCount: 2))
        XCTAssertEqual(CrashReportReader.read(from: report.path, supplementPath: supplement.path)?.captureIdentityOutcome, "unavailable")
        try CrashCohortFixtures.write(CrashCohortFixtures.capture(), to: supplement)
        var bytes = try Data(contentsOf: supplement)
        bytes.removeLast()
        try bytes.write(to: supplement)
        XCTAssertNil(CrashSupplement.load(path: supplement.path, reportTimestampMs: CrashFixtures.timestampMs, reportImageCount: 2))
        XCTAssertEqual(CrashReportReader.read(from: report.path, supplementPath: supplement.path)?.captureIdentityOutcome, "unavailable")
        bytes.append(contentsOf: [0, 0])
        try bytes.write(to: supplement)
        XCTAssertNil(CrashSupplement.load(path: supplement.path, reportTimestampMs: CrashFixtures.timestampMs, reportImageCount: 2))
        XCTAssertEqual(CrashReportReader.read(from: report.path, supplementPath: supplement.path)?.captureIdentityOutcome, "unavailable")
    }

    func testRawSavedImageCountMustMatchBeforeCohortValidation() throws {
        for count in [UInt32(SHEEPIT_MAX_IMAGES), UInt32(SHEEPIT_MAX_IMAGES) + 1, UInt32.max] {
            try CrashFixtures.writeReport(to: report, imageCount: count)
            try CrashCohortFixtures.write(CrashCohortFixtures.capture(), to: supplement,
                imageCount: UInt32(SHEEPIT_MAX_IMAGES))
            let saved = try Data(contentsOf: supplement)
            let payload = try XCTUnwrap(CrashReportReader.read(from: report.path, supplementPath: supplement.path))
            if count == UInt32(SHEEPIT_MAX_IMAGES) {
                XCTAssertEqual(payload.captureIdentityOutcome, "coherent")
                XCTAssertEqual(payload.userId, "user-A")
                XCTAssertEqual(payload.deviceId, "device-A")
                XCTAssertEqual(payload.sessionId, "session-A")
            } else {
                XCTAssertEqual(payload.captureIdentityOutcome, "unavailable")
                XCTAssertNil(payload.userId)
                XCTAssertNil(payload.deviceId)
                XCTAssertNil(payload.sessionId)
            }
            XCTAssertEqual(payload.binaryImages?.count, 2, "iteration remains bounded to physical image slots")
            XCTAssertEqual(try CrashFixtures.wireJSON(payload)["assignment_token"] as? String,
                count == UInt32(SHEEPIT_MAX_IMAGES) ? "receipt-A" : nil)
            XCTAssertEqual(try Data(contentsOf: supplement), saved)
        }
    }

    func testUnknownOrTruncatedSidecarCannotRestoreTheFrozenIdentityPrefix() throws {
        let prefix = String(repeating: "p", count: 255)
        try CrashFixtures.writeReport(to: report, userId: prefix)
        for version in [UInt32(0), 1, 2, 4, UInt32.max] {
            try CrashCohortFixtures.write(CrashCohortFixtures.capture(user: prefix + "A"),
                to: supplement, formatVersion: version)
            let saved = try Data(contentsOf: supplement)
            let payload = try XCTUnwrap(CrashReportReader.read(from: report.path, supplementPath: supplement.path))
            XCTAssertEqual(payload.captureIdentityOutcome, "unavailable", "version \(version)")
            XCTAssertNil(payload.userId)
            XCTAssertNil(payload.deviceId)
            XCTAssertNil(payload.sessionId)
            XCTAssertEqual(try Data(contentsOf: supplement), saved)
        }
        try CrashCohortFixtures.write(CrashCohortFixtures.capture(user: prefix + "A"), to: supplement)
        let complete = try Data(contentsOf: supplement)
        for bytes in [0, 2, 4] {
            try Data(complete.prefix(bytes)).write(to: supplement)
            let payload = try XCTUnwrap(CrashReportReader.read(from: report.path, supplementPath: supplement.path))
            XCTAssertEqual(payload.captureIdentityOutcome, "unavailable", "short header \(bytes)")
            XCTAssertNil(payload.userId)
        }
    }

    func testRecognizedLegacyFormatsRequireTheirActualLayoutAndCorrelation() throws {
        let prefix = String(repeating: "p", count: 255)
        try CrashFixtures.writeReport(to: report, userId: prefix)
        let validWriters: [() throws -> Void] = [
            { try CrashFixtures.writeSupplement(to: self.supplement) },
            { try CrashCohortFixtures.writeLegacyV2(to: self.supplement) },
        ]
        for write in validWriters {
            try write()
            let payload = try XCTUnwrap(CrashReportReader.read(from: report.path, supplementPath: supplement.path))
            XCTAssertEqual(payload.captureIdentityOutcome, "legacy")
            XCTAssertEqual(payload.userId, prefix)
            var oversized = try Data(contentsOf: supplement)
            oversized.append(0)
            try oversized.write(to: supplement)
            XCTAssertEqual(CrashReportReader.read(from: report.path, supplementPath: supplement.path)?.captureIdentityOutcome,
                "unavailable", "a recognized version with an impossible writer size is not legacy")
        }
        let invalidWriters: [() throws -> Void] = [
            { try CrashFixtures.writeSupplement(to: self.supplement, timestampMs: CrashFixtures.timestampMs + 1) },
            { try CrashCohortFixtures.writeLegacyV2(to: self.supplement, timestamp: CrashFixtures.timestampMs + 1) },
            { try CrashFixtures.writeSupplement(to: self.supplement, imageCount: 3) },
            { try CrashCohortFixtures.writeLegacyV2(to: self.supplement, imageCount: 3) },
            { try CrashFixtures.writeSupplement(to: self.supplement, magic: 0) },
            { try CrashCohortFixtures.writeLegacyV2(to: self.supplement, magic: 0) },
        ]
        for write in invalidWriters {
            try write()
            let payload = try XCTUnwrap(CrashReportReader.read(from: report.path, supplementPath: supplement.path))
            XCTAssertEqual(payload.captureIdentityOutcome, "unavailable")
            XCTAssertNil(payload.userId)
        }
    }

    func testUnreadableExistingSidecarIsUnavailableWhileMissingSidecarRemainsLegacy() throws {
        let prefix = String(repeating: "p", count: 255)
        try CrashFixtures.writeReport(to: report, userId: prefix)
        try CrashCohortFixtures.write(CrashCohortFixtures.capture(user: prefix + "A"), to: supplement)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: supplement.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: supplement.path) }
        let descriptor = open(supplement.path, O_RDONLY)
        let readError = errno
        if descriptor >= 0 { close(descriptor) }
        XCTAssertEqual(descriptor, -1, "the test requires a genuine unprivileged permission failure")
        XCTAssertEqual(readError, EACCES)
        let unavailable = try XCTUnwrap(CrashReportReader.read(from: report.path, supplementPath: supplement.path))
        XCTAssertEqual(unavailable.captureIdentityOutcome, "unavailable")
        XCTAssertNil(unavailable.userId)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: supplement.path)
        XCTAssertTrue(FileManager.default.isReadableFile(atPath: supplement.path))
        try FileManager.default.removeItem(at: supplement)
        let missing = try XCTUnwrap(CrashReportReader.read(from: report.path, supplementPath: supplement.path))
        XCTAssertEqual(missing.captureIdentityOutcome, "legacy")
        XCTAssertEqual(missing.userId, prefix)
    }

    func testConcurrentNativeWritersCannotPairIdentitiesAndReceipts() {
        let group = DispatchGroup()
        for name in ["A", "B"] {
            group.enter()
            DispatchQueue.global().async {
                for _ in 0..<200 { sheepit_crash_cohort_set("user-" + name, "device-" + name, "session-" + name, "receipt-" + name, false) }
                group.leave()
            }
        }
        for _ in 0..<1000 {
            var raw = sheepit_crash_cohort_t()
            sheepit_crash_cohort_snapshot(&raw)
            guard let cohort = CrashIdentityCohort(raw) else { continue }
            let name = String(cohort.deviceId.suffix(1))
            XCTAssertEqual(cohort.userId, "user-" + name)
            XCTAssertEqual(cohort.sessionId, "session-" + name)
            XCTAssertEqual(cohort.assignmentToken, "receipt-" + name)
        }
        group.wait()
        var final = sheepit_crash_cohort_t()
        sheepit_crash_cohort_snapshot(&final)
        XCTAssertNotNil(CrashIdentityCohort(final), "a completed normal writer must yield a usable cohort")
    }
}
