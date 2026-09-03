import XCTest
@testable import SheepitSDK

/// Tests targeting rule evaluation to match JS SDK behavior.
final class TargetingTests: XCTestCase {
    func testEqOperator() {
        let cond = FlagCondition(field: "plan", op: "eq", values: [AnyCodable("pro")])
        XCTAssertTrue(Targeting.evaluateCondition(cond, attributes: ["plan": "pro"]))
        XCTAssertFalse(Targeting.evaluateCondition(cond, attributes: ["plan": "free"]))
        XCTAssertFalse(Targeting.evaluateCondition(cond, attributes: [:]))
    }

    func testNeqOperator() {
        let cond = FlagCondition(field: "plan", op: "neq", values: [AnyCodable("free")])
        XCTAssertTrue(Targeting.evaluateCondition(cond, attributes: ["plan": "pro"]))
        XCTAssertFalse(Targeting.evaluateCondition(cond, attributes: ["plan": "free"]))
    }

    func testInOperator() {
        let cond = FlagCondition(field: "country", op: "in", values: [AnyCodable("US"), AnyCodable("CA")])
        XCTAssertTrue(Targeting.evaluateCondition(cond, attributes: ["country": "US"]))
        XCTAssertTrue(Targeting.evaluateCondition(cond, attributes: ["country": "CA"]))
        XCTAssertFalse(Targeting.evaluateCondition(cond, attributes: ["country": "UK"]))
    }

    func testNotInOperator() {
        let cond = FlagCondition(field: "country", op: "not_in", values: [AnyCodable("CN"), AnyCodable("RU")])
        XCTAssertTrue(Targeting.evaluateCondition(cond, attributes: ["country": "US"]))
        XCTAssertFalse(Targeting.evaluateCondition(cond, attributes: ["country": "CN"]))
    }

    func testNumericOperators() {
        let gt = FlagCondition(field: "age", op: "gt", values: [AnyCodable(18)])
        XCTAssertTrue(Targeting.evaluateCondition(gt, attributes: ["age": 21]))
        XCTAssertFalse(Targeting.evaluateCondition(gt, attributes: ["age": 18]))
        XCTAssertFalse(Targeting.evaluateCondition(gt, attributes: ["age": 15]))

        let lte = FlagCondition(field: "score", op: "lte", values: [AnyCodable(100)])
        XCTAssertTrue(Targeting.evaluateCondition(lte, attributes: ["score": 100]))
        XCTAssertTrue(Targeting.evaluateCondition(lte, attributes: ["score": 50]))
        XCTAssertFalse(Targeting.evaluateCondition(lte, attributes: ["score": 101]))
    }

    func testContainsOperator() {
        let cond = FlagCondition(field: "email", op: "contains", values: [AnyCodable("@company.com")])
        XCTAssertTrue(Targeting.evaluateCondition(cond, attributes: ["email": "user@company.com"]))
        XCTAssertFalse(Targeting.evaluateCondition(cond, attributes: ["email": "user@gmail.com"]))
        XCTAssertFalse(Targeting.evaluateCondition(cond, attributes: ["email": 123])) // wrong type
    }

    func testExistsOperator() {
        let cond = FlagCondition(field: "user_id", op: "exists", values: [])
        XCTAssertTrue(Targeting.evaluateCondition(cond, attributes: ["user_id": "abc"]))
        XCTAssertFalse(Targeting.evaluateCondition(cond, attributes: [:]))
    }

    func testANDSemantics() {
        let conditions = [
            FlagCondition(field: "plan", op: "eq", values: [AnyCodable("pro")]),
            FlagCondition(field: "country", op: "eq", values: [AnyCodable("US")]),
        ]
        XCTAssertTrue(Targeting.evaluateConditions(conditions, attributes: ["plan": "pro", "country": "US"]))
        XCTAssertFalse(Targeting.evaluateConditions(conditions, attributes: ["plan": "pro", "country": "UK"]))
        XCTAssertFalse(Targeting.evaluateConditions(conditions, attributes: ["plan": "free", "country": "US"]))
    }

    func testEmptyConditionsPassesAll() {
        XCTAssertTrue(Targeting.evaluateConditions([], attributes: [:]))
    }
}
