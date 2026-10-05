import Foundation

/// Bounds and budgets the caller's `attributes` on a `captureError` event
/// (`SheepitClient+ErrorCapture.swift`), so that every documented cap together still fits one
/// event comfortably inside the server's 32 KB per-event limit (`ingest-admission.ts`, measured on
/// `JSON.stringify(ev)` including the event context).
///
/// Per-value caps alone did not do that: a 50×50×50 array of 500-character strings sat inside
/// every documented cap and encoded to 62.8 MB. So a GLOBAL budget is spent while sanitizing,
/// not checked after: `maxLeaves` scalar values and `maxBytes` of estimated JSON (keys + values,
/// strings costed with their JSON escaping) across ALL attributes, nested containers included.
/// Attributes are taken in sorted key order; the first one that does not fit is dropped whole,
/// along with every one after it, and the caller sets `attributes_truncated`. Work is bounded by
/// the budget too: an oversized value is abandoned as soon as it overflows, never walked in full.
/// Choosing which 50 keys to keep — at the top level and in each nested dictionary — is the one
/// step linear in the input: a single pass with a 50-entry buffer (`smallestKeys`), never a sort
/// of every key, and never a copy of the dictionary (`ContainerView`). An array is read through
/// its first 50 elements, O(cap) whatever its size.
enum ErrorAttributeSanitizer {
    static let maxAttributes = 50
    static let maxKeyLength = 64
    static let maxKeyUTF8Bytes = 256
    static let maxNestedElements = 50
    static let maxDepth = 3
    static let maxLeaves = 200
    static let maxBytes = 8 * 1024
    private static let renamePrefix = "attr_"

    struct Budget {
        var leaves = 0
        var bytes = 0
        /// Set when a nested container lost elements to a size cap (an array cut to its first 50, a
        /// dictionary cut to its 50 smallest keys) — reported as `attributes_truncated`.
        var cutContainer = false

        mutating func spend(leaves: Int = 0, bytes: Int) -> Bool {
            guard self.leaves + leaves <= ErrorAttributeSanitizer.maxLeaves,
                  self.bytes + bytes <= ErrorAttributeSanitizer.maxBytes else { return false }
            self.leaves += leaves
            self.bytes += bytes
            return true
        }
    }

    /// Merges `attributes` into `props` (which holds the reserved properties). Returns whether any
    /// attribute was dropped for a limit (count or budget) — the caller's `attributes_truncated`.
    /// An attribute dropped only because its key collides is not "truncated"; it is documented.
    static func merge(_ attributes: [String: Any], into props: inout [String: Any]) -> Bool {
        var budget = Budget()
        var truncated = attributes.count > maxAttributes
        for key in smallestKeys(attributes.keys, limit: maxAttributes) {
            guard let value = attributes[key], let target = targetKey(for: key, in: props) else { continue }
            var attempt = budget
            guard attempt.spend(bytes: jsonCost(of: target) + 2),
                  let clean = sanitize(value, depth: 0, budget: &attempt) else {
                truncated = true
                break
            }
            budget = attempt
            props[target] = clean
        }
        return truncated || budget.cutContainer
    }

    /// The key an attribute is stored under, or nil when it must be dropped: bounded to
    /// `maxKeyLength`, renamed to `attr_<key>` (re-bounded, so the prefix never pushes it past the
    /// bound) when it is reserved, and dropped when the result is already taken — by a reserved
    /// key or by an earlier caller key that truncates to the same text. Sorted order makes "first
    /// wins" deterministic; every `attr_…` key sorts before every reserved key, so a caller's own
    /// `attr_type` always beats the rename of `type`.
    static func targetKey(for key: String, in props: [String: Any]) -> String? {
        var target = boundedKey(key)
        if SheepitClient.errorCaptureReservedKeys.contains(target) {
            target = boundedKey(renamePrefix + target)
            if SheepitClient.errorCaptureReservedKeys.contains(target) { return nil }
        }
        return props[target] == nil ? target : nil
    }

    static func boundedKey(_ key: String) -> String {
        SheepitClient.bounded(key, characters: maxKeyLength, utf8Bytes: maxKeyUTF8Bytes)
    }

    /// `value` as something `AnyCodable` encodes faithfully, or nil once the budget is spent. The
    /// cases are tested in the order `AnyCodable.encode` tests them, so what passes here is what
    /// it emits — with two deliberate pre-steps: an `Optional` is unwrapped first (a wrapped
    /// `NSNumber` 1 otherwise matched `as Bool`), and an `NSNumber` is classified by its own type
    /// (`AnyCodable`'s order would send every 0/1 `NSNumber` as a boolean).
    static func sanitize(_ value: Any, depth: Int, budget: inout Budget) -> Any? {
        // One `Mirror` per value: its cost is bounded by the 200-value budget, never by input size.
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            guard let wrapped = mirror.children.first else { return budget.spend(leaves: 1, bytes: 5) ? NSNull() : nil }
            return sanitize(wrapped.value, depth: depth, budget: &budget)
        }
        if Swift.type(of: value) is AnyObject.Type, let number = value as? NSNumber {
            return sanitize(number: number, budget: &budget)
        }
        switch value {
        case is NSNull:
            return budget.spend(leaves: 1, bytes: 5) ? value : nil
        case let bool as Bool:
            return budget.spend(leaves: 1, bytes: 6) ? bool : nil
        case let int as Int:
            return budget.spend(leaves: 1, bytes: 21) ? int : nil
        case let double as Double:
            guard double.isFinite else { return text(String(describing: double), budget: &budget) }
            return budget.spend(leaves: 1, bytes: 25) ? double : nil
        case let string as String:
            return text(string, budget: &budget)
        default:
            if let array = ContainerView.array(value) {
                return sanitizeArray(array, depth: depth, budget: &budget)
            }
            if let dictionary = ContainerView.dictionary(value) {
                return sanitizeDictionary(dictionary, value: value, depth: depth, budget: &budget)
            }
            return leaf(value, depth: depth, budget: &budget)
        }
    }

    /// A Foundation number (from `JSONSerialization`, `userInfo`, Objective-C) as the Swift value it
    /// holds. Without this, `as Bool` — tested first, in `AnyCodable`'s order — claims every
    /// `NSNumber` that is 0 or 1, so a JSON-decoded `1` was sent as `true`. A `float` or an
    /// `NSDecimalNumber` is sent as its own decimal text: widening a float to a double prints
    /// `1.100000023841858`, and a decimal (money) must not go through binary floating point.
    private static func sanitize(number: NSNumber, budget: inout Budget) -> Any? {
        if CFGetTypeID(number) == CFBooleanGetTypeID() {
            return budget.spend(leaves: 1, bytes: 6) ? number.boolValue : nil
        }
        let objCType = String(cString: number.objCType)
        if number is NSDecimalNumber || objCType == "f" {
            return text(number.stringValue, budget: &budget)
        }
        if objCType == "d" {
            let double = number.doubleValue
            guard double.isFinite else { return text(number.stringValue, budget: &budget) }
            return budget.spend(leaves: 1, bytes: 25) ? double : nil
        }
        // An unsigned 64-bit value past `Int.max` does not fit an `Int`; its exact digits do.
        guard let int = Int(number.stringValue) else { return text(number.stringValue, budget: &budget) }
        return budget.spend(leaves: 1, bytes: 21) ? int : nil
    }

    /// The first `maxNestedElements` elements, read without converting the whole array.
    private static func sanitizeArray(_ array: ContainerView.ArrayView, depth: Int, budget: inout Budget) -> Any? {
        guard depth < maxDepth else { return text("<array of \(array.count)>", budget: &budget) }
        guard budget.spend(bytes: 2) else { return nil }
        if array.count > maxNestedElements { budget.cutContainer = true }
        var out: [Any] = []
        for element in array.leading(maxNestedElements) {
            guard let clean = sanitize(element, depth: depth + 1, budget: &budget),
                  budget.spend(bytes: 1) else { return nil }
            out.append(clean)
        }
        return out
    }

    /// A dictionary keeps its `maxNestedElements` smallest string keys (`smallestKeys`: one pass,
    /// no sort, no copy of the dictionary — see `ContainerView.dictionary`); losing any sets
    /// `attributes_truncated`. Non-string keys are skipped; a dictionary with none left is text.
    private static func sanitizeDictionary(
        _ dictionary: ContainerView.DictionaryView,
        value: Any,
        depth: Int,
        budget: inout Budget
    ) -> Any? {
        guard depth < maxDepth else { return text("<dictionary of \(dictionary.count)>", budget: &budget) }
        guard let entries = dictionary.smallestEntries(maxNestedElements) else {
            return leaf(value, depth: depth, budget: &budget)
        }
        if dictionary.count > entries.count { budget.cutContainer = true }
        guard budget.spend(bytes: 2) else { return nil }
        var out: [String: Any] = [:]
        for (key, element) in entries {
            let bounded = boundedKey(key)
            guard out[bounded] == nil else { continue }
            guard budget.spend(bytes: jsonCost(of: bounded) + 2),
                  let clean = sanitize(element, depth: depth + 1, budget: &budget) else { return nil }
            out[bounded] = clean
        }
        return out
    }

    /// A value `AnyCodable` would encode as `null`: a class instance or Foundation collection
    /// (anything not caught above as NSString / NSNumber / NSNull / array or dictionary) becomes a
    /// `<TypeName>` placeholder — never asked to describe itself, since a cyclic one overflows the
    /// stack; anything else gets `BoundedDescription`'s text. (Optionals were unwrapped already.)
    private static func leaf(_ value: Any, depth: Int, budget: inout Budget) -> Any? {
        if Swift.type(of: value) is AnyObject.Type {
            return text(BoundedDescription.placeholder(for: value), budget: &budget)
        }
        return text(BoundedDescription.of(value: value), budget: &budget)
    }

    /// The `limit` smallest keys, in ascending order — what `keys.sorted().prefix(limit)` returns —
    /// in ONE pass with a bounded buffer: O(n log limit) comparisons instead of an O(n log n) sort
    /// of every key. Sorting a 1M-key dictionary cost ~1.1 s on the caller's thread.
    static func smallestKeys<Keys: Sequence>(_ keys: Keys, limit: Int) -> [String] where Keys.Element == String {
        var buffer: [String] = []
        buffer.reserveCapacity(limit + 1)
        for key in keys {
            if buffer.count == limit, let largest = buffer.last, !(key < largest) { continue }
            var low = 0
            var high = buffer.count
            while low < high {
                let middle = (low + high) / 2
                if buffer[middle] < key { low = middle + 1 } else { high = middle }
            }
            buffer.insert(key, at: low)
            if buffer.count > limit { buffer.removeLast() }
        }
        return buffer
    }

    private static func text(_ string: String, budget: inout Budget) -> Any? {
        let bounded = SheepitClient.bounded(string)
        return budget.spend(leaves: 1, bytes: jsonCost(of: bounded) + 1) ? bounded : nil
    }

    /// Bytes `string` costs as a JSON string literal, worst case: quotes, `\"` / `\\` / `\/`
    /// escapes (Foundation's `JSONEncoder` escapes `/`), `\u00XX` for control characters.
    static func jsonCost(of string: String) -> Int {
        var cost = 2
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0x22, 0x5C, 0x2F: cost += 2
            case 0..<0x20: cost += 6
            default: cost += String(scalar).utf8.count
            }
        }
        return cost
    }
}

/// Size and element access for the containers a caller can pass, WITHOUT the conversion that
/// `as? [Any]` / `as? [String: Any]` performs (a full copy when the element type is narrower than
/// `Any`; ~80-140 ms for a million entries in a debug build). Foundation collections are checked
/// first, as classes, so a Swift protocol cast can never bridge one into a copy.
enum ContainerView {
    struct ArrayView {
        let count: Int
        let leading: (Int) -> [Any]
    }

    static func array(_ value: Any) -> ArrayView? {
        if Swift.type(of: value) is AnyObject.Type {
            guard let array = value as? NSArray else { return nil }
            return ArrayView(count: array.count) { limit in
                (0..<min(limit, array.count)).map { array.object(at: $0) }
            }
        }
        guard let array = value as? any SanitizerArray else { return nil }
        return ArrayView(count: array.sanitizerCount) { array.sanitizerLeading($0) }
    }

    struct DictionaryView {
        let count: Int
        /// The `limit` smallest string-keyed entries in key order, or nil when there are no
        /// string keys at all.
        let smallestEntries: (Int) -> [(String, Any)]?
    }

    static func dictionary(_ value: Any) -> DictionaryView? {
        if Swift.type(of: value) is AnyObject.Type {
            guard let dictionary = value as? NSDictionary else { return nil }
            return DictionaryView(count: dictionary.count) { limit in
                // Keys read through CoreFoundation and judged as CF types, so a non-string key is
                // skipped, never force-bridged (the Swift `[String: Any]` cast would abort on one).
                let cfDictionary = dictionary as CFDictionary
                let count = CFDictionaryGetCount(cfDictionary)
                var rawKeys = [UnsafeRawPointer?](repeating: nil, count: count)
                rawKeys.withUnsafeMutableBufferPointer { buffer in
                    CFDictionaryGetKeysAndValues(cfDictionary, buffer.baseAddress, nil)
                }
                let keys = rawKeys.lazy.compactMap { raw -> String? in
                    guard let raw else { return nil }
                    let object = Unmanaged<AnyObject>.fromOpaque(raw).takeUnretainedValue()
                    // Type-checked above, so a reinterpretation rather than a dynamic `as!` cast.
                    guard CFGetTypeID(object) == CFStringGetTypeID() else { return nil }
                    return unsafeBitCast(object, to: CFString.self) as String
                }
                let chosen = ErrorAttributeSanitizer.smallestKeys(keys, limit: limit)
                guard !chosen.isEmpty || dictionary.count == 0 else { return nil }
                return chosen.compactMap { key in dictionary.object(forKey: key).map { (key, $0) } }
            }
        }
        guard let dictionary = value as? any SanitizerDictionary else { return nil }
        return DictionaryView(count: dictionary.sanitizerCount) { dictionary.sanitizerSmallestEntries($0) }
    }
}

protocol SanitizerArray {
    var sanitizerCount: Int { get }
    func sanitizerLeading(_ limit: Int) -> [Any]
}

extension Array: SanitizerArray {
    var sanitizerCount: Int { count }
    func sanitizerLeading(_ limit: Int) -> [Any] { prefix(limit).map { $0 } }
}

protocol SanitizerDictionary {
    var sanitizerCount: Int { get }
    func sanitizerSmallestEntries(_ limit: Int) -> [(String, Any)]?
}

/// Conditional on `Key == String`: inside, keys are statically strings, so nothing is cast,
/// reinterpreted or copied. (A per-key `as? String` in the unconstrained version cost ~310 ms for
/// 1M keys in a release build; an `as?` between dictionary types, ~170 ms.) A dictionary with any
/// other key type does not conform, and the caller falls back to text.
extension Dictionary: SanitizerDictionary where Key == String {
    var sanitizerCount: Int { count }

    func sanitizerSmallestEntries(_ limit: Int) -> [(String, Any)]? {
        ErrorAttributeSanitizer.smallestKeys(keys, limit: limit).compactMap { key in
            self[key].map { (key, $0 as Any) }
        }
    }
}
