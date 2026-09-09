import Foundation

/// Targeting rule evaluation engine.
/// Must produce identical results to packages/sdk-js/src/targeting.ts
enum Targeting {
    /// Evaluate all conditions (AND semantics — all must pass).
    static func evaluateConditions(_ conditions: [FlagCondition], attributes: [String: Any]) -> Bool {
        conditions.allSatisfy { evaluateCondition($0, attributes: attributes) }
    }

    /// Evaluate a single condition against attributes.
    static func evaluateCondition(_ cond: FlagCondition, attributes: [String: Any]) -> Bool {
        let actual = attributes[cond.field]

        switch cond.op {
        case "eq":
            return anyEquals(actual, cond.values.first?.value)
        case "neq":
            return !anyEquals(actual, cond.values.first?.value)
        case "in":
            return cond.values.contains(where: { anyEquals(actual, $0.value) })
        case "not_in":
            return !cond.values.contains(where: { anyEquals(actual, $0.value) })
        case "gt":
            return numericCompare(actual, cond.values.first?.value) == .orderedDescending
        case "gte":
            return numericCompare(actual, cond.values.first?.value) != .orderedAscending
        case "lt":
            return numericCompare(actual, cond.values.first?.value) == .orderedAscending
        case "lte":
            return numericCompare(actual, cond.values.first?.value) != .orderedDescending
        case "contains":
            guard let actualStr = actual as? String,
                  let searchStr = cond.values.first?.value as? String else { return false }
            return actualStr.contains(searchStr)
        case "exists":
            return actual != nil && !(actual is NSNull)
        default:
            return false
        }
    }

    // MARK: - Private

    private static func anyEquals(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (nil, _), (_, nil): return false
        case (let lval as Bool, let rval as Bool): return lval == rval
        case (let lval as Int, let rval as Int): return lval == rval
        case (let lval as Double, let rval as Double): return lval == rval
        case (let lval as String, let rval as String): return lval == rval
        // Cross-type numeric comparison
        case (let lval as Int, let rval as Double): return Double(lval) == rval
        case (let lval as Double, let rval as Int): return lval == Double(rval)
        default: return String(describing: lhs) == String(describing: rhs)
        }
    }

    private static func numericCompare(_ lhs: Any?, _ rhs: Any?) -> ComparisonResult {
        let lnum: Double? = switch lhs {
        case let val as Int: Double(val)
        case let val as Double: val
        default: nil
        }
        let rnum: Double? = switch rhs {
        case let val as Int: Double(val)
        case let val as Double: val
        default: nil
        }
        guard let lval = lnum, let rval = rnum else { return .orderedSame }
        if lval < rval { return .orderedAscending }
        if lval > rval { return .orderedDescending }
        return .orderedSame
    }
}
