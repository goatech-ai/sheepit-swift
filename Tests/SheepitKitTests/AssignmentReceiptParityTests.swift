import XCTest
@testable import SheepitKit

/// Whole-receipt identity, validated recovery and persisted-state parity with the approved protocol.
final class AssignmentReceiptParityTests: XCTestCase {
    func testDeviceOnlyAndEmptySetsRequireTheWholeAppliedIdentityBeforeRecovery() throws {
        let member = try JSONDecoder().decode(SDKExperimentAssignment.self,
            from: Data(#"{"variant_key":"treatment","payload":{},"subject_kind":"device"}"#.utf8))
        for members in [[String: SDKExperimentAssignment](), ["read": member, "unread": member]] {
            let manager = ExperimentManager(storage: InMemoryStorage())
            manager.setAssignments(members, appliedUnder: .unknown)
            let captured = manager.capture()
            XCTAssertEqual(manager.receipt(captured, eventUserId: "current", flagKey: "read-flag").receipt.status, "identity_changed")
            let exposures = LockedBox(0)
            _ = manager.resolve(experimentKey: "read") { _, _, _, set in
                exposures.mutate { $0 += 1 }
                _ = manager.receipt(set, eventUserId: "current", experimentKey: "read", variant: "treatment")
            }
            let held = manager.setAssignments(members, appliedUnder: .fetchedUnder("other"), assignmentToken: "foreign",
                eventIdentity: .fetchedUnder("current"))
            XCTAssertTrue(held.isEmpty, "a receipt for a different identity cannot release pending reads")
            XCTAssertTrue(manager.setAssignments(members, appliedUnder: .unknown, assignmentToken: "foreign-refreshed",
                eventIdentity: .fetchedUnder("current")).isEmpty)
            let released = manager.setAssignments(members, appliedUnder: .fetchedUnder("current"), assignmentToken: "current",
                eventIdentity: .fetchedUnder("current"))
            XCTAssertEqual(released, ["read-flag"])
            _ = manager.resolve(experimentKey: "read") { _, _, _, _ in exposures.mutate { $0 += 1 } }
            XCTAssertEqual(exposures.get(), members.isEmpty ? 0 : 2)
            XCTAssertTrue(manager.setAssignments(members, appliedUnder: .fetchedUnder("current"), assignmentToken: "fresh-alias",
                eventIdentity: .fetchedUnder("current")).isEmpty)
            _ = manager.resolve(experimentKey: "read") { _, _, _, _ in exposures.mutate { $0 += 1 } }
            XCTAssertEqual(exposures.get(), members.isEmpty ? 0 : 2, "alias-only refresh never duplicates exposures")
        }
    }

    func testNullReceiptDoesNotReleaseAReadWhileAUsableLaterReceiptDoes() {
        let manager = ExperimentManager(storage: InMemoryStorage())
        manager.setAssignments([:], appliedUnder: .fetchedUnder(nil))
        _ = manager.receipt(eventUserId: nil, flagKey: "read")
        _ = manager.beginIdentitySwitch(to: "b")
        XCTAssertTrue(manager.setAssignments([:], appliedUnder: .fetchedUnder("b"), assignmentToken: nil).isEmpty)
        XCTAssertNil(manager.receipt(eventUserId: "b").receipt.token)
        XCTAssertEqual(manager.setAssignments([:], appliedUnder: .fetchedUnder("b"), assignmentToken: "ready"), ["read"])
        XCTAssertTrue(manager.setAssignments([:], appliedUnder: .fetchedUnder("b"), assignmentToken: "alias").isEmpty)
    }

    func testDeviceChangeInvalidatesTheOldCapturedReceiptWithoutRepairingItsAlias() {
        let manager = ExperimentManager(storage: InMemoryStorage())
        manager.setAssignments([:], appliedUnder: .fetchedUnder("a"), assignmentToken: "old")
        let captured = manager.capture()
        manager.invalidateReceiptForDeviceChange()
        XCTAssertNil(manager.receipt(eventUserId: "a").receipt.token)
        XCTAssertEqual(manager.receipt(captured, eventUserId: "a").receipt,
            AssignmentReceipt(token: "old", identityChanged: true))
    }

    func testUnknownNullAndWrongPersistedStatusNeverBecomeAttributableOrThrow() throws {
        let statuses: [Any] = [NSNull(), false, "identity_changd", "future_status", ["unknown": 1]]
        for status in statuses {
            let data = try JSONSerialization.data(withJSONObject: ["token": "kept-if-valid", "status": status])
            let decoded = try JSONDecoder().decode(AssignmentReceipt.self, from: data)
            XCTAssertNil(decoded.token)
            XCTAssertNil(decoded.status)
        }
        for raw in ["[]", "123", "true", #"{"token":123}"#] {
            XCTAssertNil(try JSONDecoder().decode(AssignmentReceipt.self, from: Data(raw.utf8)).token)
        }
        XCTAssertEqual(try JSONDecoder().decode(AssignmentReceipt.self,
            from: Data(#"{"token":"valid"}"#.utf8)).token, "valid")
        XCTAssertEqual(AssignmentReceipt.validToken(String(repeating: "界", count: 32))?.utf8.count, 96)
        XCTAssertNil(AssignmentReceipt.validToken(String(repeating: "界", count: 33)))
    }
    func testMalformedPersistedReceiptDoesNotDropItsEventOrReplaceHistoricalIdentity() throws {
        let event = EnrichedEvent(eventId: "saved", eventName: "purchase", eventProperties: ["assignment_status": AnyCodable("business")],
            deviceId: "saved-device", anonymousId: "saved-anonymous", sessionId: "saved-session", userId: "saved-user",
            platform: "ios", sdkVersion: "0.11.0", locale: "en", timezone: "UTC", timestamp: "2026-11-12T00:00:00Z",
            assignmentReceipt: AssignmentReceipt(token: "valid"))
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Any])
        let malformed: [Any] = [
            ["token": "kept-if-valid", "status": false] as [String: Any],
            ["token": "kept-if-valid", "status": NSNull()] as [String: Any], [Any](),
        ]
        for bad in malformed {
            var altered = original
            altered["assignmentReceipt"] = bad
            let data = try JSONSerialization.data(withJSONObject: [altered, original])
            let queue = try JSONDecoder().decode([EnrichedEvent].self, from: data)
            XCTAssertEqual(queue.count, 2)
            XCTAssertNil(queue[0].assignmentReceipt?.token)
            XCTAssertEqual(queue[1].assignmentReceipt?.token, "valid")
            XCTAssertEqual(queue[0].userId, "saved-user")
            XCTAssertEqual(queue[0].sessionId, "saved-session")
            XCTAssertEqual(queue[0].eventProperties?["assignment_status"]?.value as? String, "business")
        }
    }

    func testNulReceiptIsRejectedByNewAndPersistedReceiptConsumers() throws {
        for token in ["\0receipt", "receipt\0", "good\0receipt"] {
            XCTAssertNil(AssignmentReceipt(token: token).token)
            let raw = try JSONSerialization.data(withJSONObject: ["token": token])
            XCTAssertNil(try JSONDecoder().decode(AssignmentReceipt.self, from: raw).token)
        }
        XCTAssertEqual(AssignmentReceipt(token: "receipt").token, "receipt")
    }

}
