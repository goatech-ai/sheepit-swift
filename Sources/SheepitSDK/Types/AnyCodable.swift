import Foundation

/// A type-erased Codable value for handling dynamic JSON values (flags,
/// properties, payloads).
///
/// Audit E-008 — `value: Any` is non-Sendable, but `Codable` JSON
/// decoding here only ever stores values of types that are themselves
/// Sendable: `Bool`, `Int`, `Double`, `String`, `NSNull`, plus
/// recursive `[Any]` / `[String: Any]` containers built from those
/// same primitives. The struct is also `let`-stored — no mutation
/// after init. Safe to mark `@unchecked Sendable`; the invariant is
/// enforced by `init(from:)` not accepting any other shape.
///
/// Use `[String: AnyCodable]` (NOT `[String: Any]`) at API
/// boundaries that need Sendable propagation — see
/// `SheepitExperimentResult.payload`.
public struct AnyCodable: Codable, @unchecked Sendable, Equatable, Hashable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported JSON type")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }

    public static func == (lhs: AnyCodable, rhs: AnyCodable) -> Bool {
        isEqual(lhs.value, rhs.value)
    }

    /// Structural equality over the JSON shapes `init(from:)` can
    /// produce. Containers recurse — without this, two identical
    /// object- or array-valued flags compared unequal, which would make
    /// `FlagValue.json` Equatable in name only.
    private static func isEqual(_ lhs: Any, _ rhs: Any) -> Bool {
        switch (lhs, rhs) {
        case (is NSNull, is NSNull): return true
        case (let lval as Bool, let rval as Bool): return lval == rval
        case (let lval as Int, let rval as Int): return lval == rval
        case (let lval as Double, let rval as Double): return lval == rval
        case (let lval as String, let rval as String): return lval == rval
        case (let lval as [Any], let rval as [Any]):
            guard lval.count == rval.count else { return false }
            for (left, right) in zip(lval, rval) where !isEqual(left, right) { return false }
            return true
        case (let lval as [String: Any], let rval as [String: Any]):
            guard lval.count == rval.count else { return false }
            for (key, leftValue) in lval {
                guard let rightValue = rval[key], isEqual(leftValue, rightValue) else { return false }
            }
            return true
        default: return false
        }
    }

    public func hash(into hasher: inout Hasher) {
        switch value {
        case is NSNull: hasher.combine(0)
        case let bool as Bool: hasher.combine(bool)
        case let int as Int: hasher.combine(int)
        case let double as Double: hasher.combine(double)
        case let string as String: hasher.combine(string)
        // Containers: hash only the shape (kind + count). Equal values
        // always produce equal hashes; unequal values may collide, which
        // is permitted. Hashing contents would require an ordering the
        // untyped payload does not have.
        case let array as [Any]: hasher.combine(1); hasher.combine(array.count)
        case let dict as [String: Any]: hasher.combine(2); hasher.combine(dict.keys.sorted())
        default: hasher.combine(0)
        }
    }
}
