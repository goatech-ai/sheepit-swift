import Foundation
import XCTest
@testable import SheepitKit

final class RuntimeCapabilitiesContractTests: XCTestCase {
    private let legacy = """
    {"runtime_attribution_version":1,"max_runtime_context_bytes":8192,
     "per_event_analytics_context":true,"per_metric_performance_context":true,
     "runtime_release_membership":true}
    """

    func testOlderApiOmitsBodyKeyCapability() throws {
        let response = try JSONDecoder().decode(RuntimeCapabilitiesResponse.self, from: Data(legacy.utf8))
        XCTAssertNil(response.ingestBodyKey)
        XCTAssertEqual(response.runtimeAttributionVersion, 1)
    }

    func testApiAdvertisesBodyKeyCapability() throws {
        let json = "{\"ingest_body_key\":true," + legacy.dropFirst()
        let response = try JSONDecoder().decode(RuntimeCapabilitiesResponse.self, from: Data(json.utf8))
        XCTAssertEqual(response.ingestBodyKey, true)
    }
}
