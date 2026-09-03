import XCTest
@testable import SheepitSDK

/// `FlagValue.from(_:)` used to fall through to `.bool(false)` for any
/// object or array, so a customer with a `json` flag silently read
/// `false`. These tests pin the `.json` case end to end.
final class FlagValueJSONTests: XCTestCase {
    // MARK: - from(_:)

    func testFromObjectProducesJSONCase() {
        let value = FlagValue.from(["accent": "purple", "compact": true] as [String: Any])
        XCTAssertNotNil(value.jsonObject, "object flag must not degrade to another case")
        XCTAssertEqual(value.jsonObject?["accent"] as? String, "purple")
        XCTAssertEqual(value.jsonObject?["compact"] as? Bool, true)
        XCTAssertNil(value.boolValue, "the old fall-through produced .bool(false) here")
    }

    func testFromArrayProducesJSONCase() {
        let value = FlagValue.from([1, "x", false] as [Any])
        XCTAssertEqual(value.jsonArray?.count, 3)
        XCTAssertEqual(value.jsonArray?[1] as? String, "x")
        XCTAssertNil(value.boolValue)
    }

    func testFromNullProducesJSONCase() {
        let value = FlagValue.from(NSNull())
        XCTAssertNotNil(value.jsonValue)
        XCTAssertTrue(value.jsonValue?.value is NSNull)
    }

    func testPrimitivesAreUnchanged() {
        XCTAssertEqual(FlagValue.from(true), .bool(true))
        XCTAssertEqual(FlagValue.from(false), .bool(false))
        XCTAssertEqual(FlagValue.from(42), .int(42))
        XCTAssertEqual(FlagValue.from(1.5), .double(1.5))
        XCTAssertEqual(FlagValue.from("blue"), .string("blue"))
    }

    func testFromUnwrapsAnyCodable() {
        let value = FlagValue.from(AnyCodable(["a": 1] as [String: Any]))
        XCTAssertEqual(value.jsonObject?["a"] as? Int, 1)
    }

    // MARK: - Round-trip through the wire format

    func testJSONFlagRoundTripsThroughConfigDecoding() throws {
        // Shape of a /v1/config `flags` map carrying an object-valued flag.
        let json = """
        {"home_theme": {"accent": "purple", "sizes": [1, 2, 3], "nested": {"on": true}}}
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode([String: AnyCodable].self, from: json)
        let manager = GTFlagManager()
        manager.setEvaluatedFlags(decoded)

        var exposures: [(String, FlagValue)] = []
        let value = manager.evaluate(flagKey: "home_theme", defaultValue: .bool(false)) { key, val in
            exposures.append((key, val))
        }

        XCTAssertEqual(value.jsonObject?["accent"] as? String, "purple")
        XCTAssertEqual((value.jsonObject?["sizes"] as? [Any])?.count, 3)
        XCTAssertEqual((value.jsonObject?["nested"] as? [String: Any])?["on"] as? Bool, true)
        XCTAssertEqual(exposures.count, 1)
        XCTAssertEqual(exposures.first?.0, "home_theme")

        // And re-encodes to the same JSON shape.
        let reEncoded = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(value.jsonValue)
        ) as? [String: Any]
        XCTAssertEqual(reEncoded?["accent"] as? String, "purple")
    }

    func testDecodeJSONIntoModel() {
        struct Theme: Decodable, Equatable {
            let accent: String
            let compact: Bool
        }
        let value = FlagValue.from(["accent": "purple", "compact": true] as [String: Any])
        XCTAssertEqual(value.decodeJSON(Theme.self), Theme(accent: "purple", compact: true))
        // Wrong shape → nil, not a crash.
        XCTAssertNil(FlagValue.from(["accent": 1] as [String: Any]).decodeJSON(Theme.self))
        // Non-.json cases → nil.
        XCTAssertNil(FlagValue.bool(true).decodeJSON(Theme.self))
    }

    // MARK: - Equality

    func testEquatableComparesContainersStructurally() {
        let left = FlagValue.from(["a": [1, 2], "b": ["c": "d"]] as [String: Any])
        let right = FlagValue.from(["b": ["c": "d"], "a": [1, 2]] as [String: Any])
        XCTAssertEqual(left, right, "identical payloads must compare equal regardless of key order")

        let different = FlagValue.from(["a": [1, 3], "b": ["c": "d"]] as [String: Any])
        XCTAssertNotEqual(left, different)
        XCTAssertNotEqual(left, FlagValue.from(["a": [1, 2]] as [String: Any]))
    }

    func testEqualValuesHashEqually() {
        let left = AnyCodable(["a": 1, "b": [1, 2]] as [String: Any])
        let right = AnyCodable(["b": [1, 2], "a": 1] as [String: Any])
        XCTAssertEqual(left, right)
        XCTAssertEqual(left.hashValue, right.hashValue, "Hashable must agree with Equatable")
    }

    // MARK: - anyValue (the $flag_exposure property)

    func testAnyValueReturnsRawPayload() {
        XCTAssertEqual(FlagValue.bool(true).anyValue as? Bool, true)
        XCTAssertEqual(FlagValue.int(7).anyValue as? Int, 7)
        XCTAssertEqual(FlagValue.string("blue").anyValue as? String, "blue")
        let json = FlagValue.from(["a": 1] as [String: Any])
        XCTAssertEqual((json.anyValue as? [String: Any])?["a"] as? Int, 1)
    }

    // MARK: - Debug override persistence

    func testJSONOverrideSurvivesReload() {
        let key = "lp_debug_overrides"
        UserDefaults.standard.removeObject(forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let manager = GTFlagManager()
        manager.setOverridesAllowed(true)
        manager.overrideFlag("home_theme", value: .from(["accent": "red"] as [String: Any]))

        let reloaded = GTFlagManager()
        reloaded.setOverridesAllowed(true)
        XCTAssertEqual(
            reloaded.getOverrides()["home_theme"]?.jsonObject?["accent"] as? String,
            "red"
        )
    }

    func testLegacyStringOverrideFormatStillLoads() throws {
        let key = "lp_debug_overrides"
        // The pre-.json on-disk format: every value stringified.
        let legacy = try JSONEncoder().encode(["a": "true", "b": "42", "c": "blue"])
        UserDefaults.standard.set(legacy, forKey: key)
        defer { UserDefaults.standard.removeObject(forKey: key) }

        let manager = GTFlagManager()
        manager.setOverridesAllowed(true)
        let overrides = manager.getOverrides()
        XCTAssertEqual(overrides["a"], .bool(true))
        XCTAssertEqual(overrides["b"], .int(42))
        XCTAssertEqual(overrides["c"], .string("blue"))
    }
}
