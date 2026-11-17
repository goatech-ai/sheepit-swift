/// Dormant generated DTO receipt fields remain optional for already-cached configs.
import Foundation
import XCTest
@testable import SheepitKit

final class AssignmentTokenDTOTests: XCTestCase {
    func testLegacyCachedConfigDecodesWithoutReceipt() throws {
        let body = Data(#"{"config_version":"1","etag":"old","flags":{},"experiments":{}}"#.utf8)
        let config = try JSONDecoder().decode(SDKConfigResponse.self, from: body)
        XCTAssertNil(config.assignmentToken)
        XCTAssertEqual(config.etag, "old")
    }

    func testConfigRetainsOpaqueAppliedReceipt() throws {
        let body = Data(#"{"config_version":"1","etag":"same","flags":{},"experiments":{},"assignment_token":"at1.1.opaque"}"#.utf8)
        let config = try JSONDecoder().decode(SDKConfigResponse.self, from: body)
        XCTAssertEqual(config.assignmentToken, "at1.1.opaque")
    }

    func testFullConfigWithoutValidatorDecodesAvailableOrNullReceipt() throws {
        for receipt in ["\"at1.1.opaque\"", "null"] {
            let body = Data("{\"config_version\":\"1\",\"flags\":{},\"experiments\":{},\"assignment_token\":\(receipt)}".utf8)
            let config = try JSONDecoder().decode(SDKConfigResponse.self, from: body)
            XCTAssertNil(config.etag)
            XCTAssertEqual(config.assignmentToken, receipt == "null" ? nil : "at1.1.opaque")
        }
    }

    func testDormantIngestFieldsAreOmittedUntilExplicitlySet() throws {
        var context = IngestContext(
            app: nil, sdk: nil, user: nil, device: nil, session: nil,
            flags: nil, experiments: nil, experimentAssignments: nil,
            account: nil, revenue: nil, releaseId: nil)
        let absent = try JSONDecoder().decode(
            [String: String].self, from: JSONEncoder().encode(context))
        XCTAssertTrue(absent.isEmpty)
        context.assignmentToken = "at1.1.opaque"
        context.assignmentStatus = "identity_changed"
        let present = try JSONDecoder().decode(
            [String: String].self, from: JSONEncoder().encode(context))
        XCTAssertEqual(present, [
            "assignment_token": "at1.1.opaque",
            "assignment_status": "identity_changed"
        ])
    }

    /// The server sends `assignment_token: null` on unresolved_device, scope_missing and key_unavailable.
    func testNullAndAbsentReceiptsAreNotMalformedAndLeaveTheCachedBytesAlone() throws {
        let nullBody = Data(#"{"data":{"config_version":"1","assignment_token":null,"flags":{},"experiments":{}}}"#.utf8)
        let absentBody = Data(#"{"data":{"config_version":"1","flags":{},"experiments":{}}}"#.utf8)
        for body in [nullBody, absentBody] {
            let config = try JSONDecoder().decode(ApiDataResponse<SDKConfigResponse>.self, from: body).data
            XCTAssertFalse(AssignmentReceipt.isMalformed(config.rawAssignmentToken))
            XCTAssertEqual(AssignmentReceipt.cacheData(body, config: config), body, "no rewrite, no re-serialization")
        }
        // The NSNull spelling of the same thing, however a decoder surfaces it.
        XCTAssertFalse(AssignmentReceipt.isMalformed(AnyCodable(NSNull())))
        XCTAssertTrue(AssignmentReceipt.isMalformed(AnyCodable("")))
        XCTAssertTrue(AssignmentReceipt.isMalformed(AnyCodable(123)))
    }

    func testAMalformedReceiptNeverCostsTheCacheItsBytes() throws {
        let unparseable = Data("not json".utf8)
        let config = try JSONDecoder().decode(ApiDataResponse<SDKConfigResponse>.self, from:
            Data(#"{"data":{"config_version":"1","assignment_token":123,"flags":{},"experiments":{}}}"#.utf8)).data
        XCTAssertEqual(AssignmentReceipt.cacheData(unparseable, config: config), unparseable)
        let flat = Data(#"{"config_version":"1","assignment_token":123}"#.utf8)
        XCTAssertEqual(AssignmentReceipt.cacheData(flat, config: config), flat, "an envelope it cannot rewrite is kept whole")
    }
}
