import Foundation

/// Recursion-safe, size-bounded text for a captured error (`error_description`) and for an
/// attribute value JSON cannot carry. Used by `SheepitClient+ErrorCapture.swift`.
///
/// 🔴 Why this exists: Foundation-composed text is NOT safe on arbitrary values, and every crash
/// below was reproduced through the public `captureError` in review:
///   - `String(describing:)` of an `NSError` whose `userInfo` holds a dictionary that contains
///     itself recurses until the stack overflows (SIGSEGV in the HOST app).
///   - `localizedDescription` composes its text from `userInfo`: a cyclic dictionary under
///     `NSLocalizedFailureReasonErrorKey` overflows the stack the same way, and a non-string
///     (`NSNumber`, array, dictionary) under `NSLocalizedDescriptionKey` raises an uncaught
///     `NSInvalidArgumentException` (`-length` sent to a non-string).
///   - Even READING `NSError.userInfo` from Swift is unsafe: Swift imports it as `[String: Any]`
///     and force-bridges the whole dictionary, so one non-string KEY (legal in Objective-C and
///     CoreFoundation) aborts the process — "Could not cast value of type '__NSCFNumber' to
///     'NSString'", signal 6. `userInfo` is therefore only ever read through CoreFoundation.
///   - An `NSObject`-rooted error class conforms to `CustomStringConvertible` through `NSObject`;
///     its inherited `description` is `<Module.Type: 0x…>`, a per-launch address.
/// Swift can catch none of these, so a crash here takes the host app down.
///
/// - An NSError-backed error (a real `NSError` or subclass; Foundation's error structs such as
///   `URLError` / `CocoaError` / `POSIXError` arrive as one once erased to `Error`):
///   `"<domain> <code>: <text>"`. `userInfo` is read via `CFErrorCopyUserInfo`, never through the
///   Swift `userInfo` property, and never described.
///     - NON-EMPTY `userInfo` (CF count > 0): Foundation is never asked. The text is the
///       `NSLocalizedDescriptionKey` value, else the `NSLocalizedFailureReasonErrorKey` value, each
///       only when it is a CFString; else no text, `"<domain> <code>"`.
///     - EMPTY `userInfo`, `NSPOSIXErrorDomain`: Foundation is never asked; the text is
///       `strerror_r(code)` (pure C, thread-safe) for a positive code in `Int32` range.
///     - EMPTY `userInfo`, any other domain: Foundation's `localizedDescription` (founder decision,
///       2026-10-02) only when (b) the error's class overrides neither `localizedDescription` nor
///       `localizedFailureReason` relative to `NSError` (a recursive override can crash the host),
///       AND (c) the domain is `NSCocoaErrorDomain` OR no `NSError.setUserInfoValueProvider` is
///       registered for it. A provider's values are NOT in the CF count and `localizedDescription`
///       calls the provider, so an armed provider (returning a non-string or a cyclic dictionary,
///       or raising) can crash the host. Registration is process-global, and measured on macOS 27
///       Foundation accepts a replacement provider on every one of its domains EXCEPT
///       `NSCocoaErrorDomain` ("Cannot replace provider for NSCocoaErrorDomain") — so Cocoa is the
///       only domain trusted with a provider registered. Foundation's own providers sit on Cocoa,
///       POSIX, OSStatus and Mach (measured), which is why OSStatus / Mach errors report
///       `"<domain> <code>"`. Otherwise no text, `"<domain> <code>"`.
///     - Residuals: (i) a process-wide swizzle of `-[NSError localizedDescription]` (APM libraries
///       do this) is invisible to (b), and runs on the Cocoa and unarmed paths — and the unarmed
///       set (`NSURLErrorDomain`, `kCFErrorDomainCFNetwork`, custom domains with no provider) is the
///       common case, so a broken swizzle would reach most real errors; (ii) a provider
///       registered between the check and the call is a race (low realism); (iii) Cocoa's
///       replacement refusal was measured on macOS only, not on an iOS 16 runtime.
/// - A class instance (not NSError-backed): an `NSObject`-rooted class ALWAYS reports its
///   qualified type name — its `description` / `debugDescription` is never called (NSObject's
///   prints a per-launch address; Foundation subclasses such as `NSData` / `NSNumber` / `NSValue`
///   / `NSDate` raise "only defined for abstract class"; an override can recurse). A pure
///   Swift class uses its own description only when its type conforms to
///   `CustomStringConvertible` / `CustomDebugStringConvertible`; otherwise its qualified type name.
/// - A Swift value error whose type conforms to `CustomStringConvertible` /
///   `CustomDebugStringConvertible`: its own description, verbatim — the host app's code, its
///   responsibility.
/// - Any other Swift error: a bounded `Mirror` walk reproducing Swift's default shape, e.g.
///   `declined(code: 51, reason: "insufficient_funds")` or `Failure(field: 1)`. At most
///   `maxDepth` levels and `maxChildren` per level; it stops once the text is long enough to be
///   cut anyway. Class instances, Foundation collections and anything at the depth cap print as
///   a `<TypeName>` placeholder. `Optional`s are unwrapped.
enum BoundedDescription {
    static let maxDepth = 3
    static let maxChildren = 50

    static func of(error: Error) -> String {
        if isNSErrorBacked(error) {
            return nsErrorText(error as NSError)
        }
        let type = Swift.type(of: error)
        if let cls = type as? AnyClass {
            return classErrorText(error, class: cls)
        }
        if describesItself(type) {
            return SheepitClient.bounded(String(describing: error))
        }
        return of(value: error)
    }

    /// `type(of:) is NSError.Type`, on the error as received (already erased to `Error`). Measured
    /// on the macOS host: true for a real `NSError` or subclass, a `CFError`, AND Foundation's error
    /// structs (`URLError`, `CocoaError`, `POSIXError`) — once erased to `Error` their dynamic type
    /// is `NSError` — and false for a Swift enum, struct or class error merely bridgeable through
    /// `as NSError`.
    static func isNSErrorBacked(_ error: Error) -> Bool {
        Swift.type(of: error) is NSError.Type
    }

    /// See the type doc. `domain` and `code` never touch `userInfo`; `userInfo` is read only as a
    /// `CFDictionary` (count, then two keys), each value accepted only when it is a `CFString`.
    static func nsErrorText(_ error: NSError) -> String {
        let head = "\(SheepitClient.stableName(error.domain)) \(error.code)"
        let info = CFErrorCopyUserInfo(error as CFError)
        let text: String?
        if let info, CFDictionaryGetCount(info) > 0 {
            text = cfString(info, NSLocalizedDescriptionKey) ?? cfString(info, NSLocalizedFailureReasonErrorKey)
        } else if error.domain == NSPOSIXErrorDomain {
            text = posixText(error.code)
        } else if foundationTextIsSafe(error) {
            text = error.localizedDescription
        } else {
            text = nil
        }
        guard let text else { return SheepitClient.bounded(head) }
        return SheepitClient.bounded(head + ": " + SheepitClient.bounded(text))
    }

    /// Preconditions (b) and (c) for asking Foundation, for an error whose `userInfo` is already
    /// known to be empty (see the type doc). Each is a read that runs no host code: two
    /// method-implementation comparisons on the runtime class and a provider lookup (not a call).
    static func foundationTextIsSafe(_ error: NSError) -> Bool {
        guard let cls = object_getClass(error),
              !overrides(cls, "localizedDescription", relativeTo: NSError.self),
              !overrides(cls, "localizedFailureReason", relativeTo: NSError.self) else { return false }
        return error.domain == NSCocoaErrorDomain || NSError.userInfoValueProvider(forDomain: error.domain) == nil
    }

    /// `strerror_r` for a POSIX error code: C, thread-safe, no Foundation and no provider. Nil for a
    /// code outside `1...Int32.max` or one `strerror_r` rejects.
    static func posixText(_ code: Int) -> String? {
        guard code > 0, code <= Int(Int32.max) else { return nil }
        var buffer = [CChar](repeating: 0, count: 256)
        guard strerror_r(Int32(code), &buffer, buffer.count) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// The value under `key`, only when it is a string. `object(forKey:)` on the toll-free
    /// `NSDictionary` looks up one key; the dictionary itself is never bridged to Swift (which is
    /// what aborts on a non-string key), and the value is type-checked before it is converted.
    private static func cfString(_ dictionary: CFDictionary, _ key: String) -> String? {
        guard let value = (dictionary as NSDictionary).object(forKey: key as NSString) else { return nil }
        let object = value as AnyObject
        // Type-checked first, then reinterpreted — the same idiom as `ContainerView`'s key scan.
        guard CFGetTypeID(object) == CFStringGetTypeID() else { return nil }
        return unsafeBitCast(object, to: CFString.self) as String
    }

    /// A class-instance error: its own description only when its class provides one (see the
    /// type doc), else its qualified type name — never `NSObject`'s `<Type: 0x…>`.
    private static func classErrorText(_ error: Error, class cls: AnyClass) -> String {
        let typeName = SheepitClient.stableName(String(reflecting: cls))
        // `NSObject`-rooted: never ask it to describe itself (see the type doc).
        if cls is NSObject.Type { return typeName }
        return describesItself(cls) ? SheepitClient.bounded(String(describing: error)) : typeName
    }

    /// Whether `cls` (or a superclass below `base`) replaces `base`'s implementation.
    private static func overrides(_ cls: AnyClass, _ selectorName: String, relativeTo base: AnyClass) -> Bool {
        let selector = NSSelectorFromString(selectorName)
        return class_getMethodImplementation(cls, selector) != class_getMethodImplementation(base, selector)
    }

    /// Whether the TYPE conforms to `CustomStringConvertible` / `CustomDebugStringConvertible`.
    /// A metatype check, not a value cast: a metatype cast does not bridge through `NSError`, so
    /// the answer does not depend on runtime value-cast semantics we cannot test on an iOS 16
    /// runtime. (Written as a value cast on `Error`, `error is CustomStringConvertible` is also a
    /// compile-time "'is' test is always true" warning — a build failure under
    /// `-warnings-as-errors`.) Measured on the macOS host: true for a self-describing Swift error;
    /// false for plain enum, struct and class errors. NOT used to decide for an `NSObject`
    /// subclass, which always conforms through `NSObject` (see `classErrorText`).
    private static func describesItself(_ type: Any.Type) -> Bool {
        type is CustomStringConvertible.Type || type is CustomDebugStringConvertible.Type
    }

    /// Bounded text for any value.
    static func of(value: Any) -> String {
        var out = ""
        walk(value, depth: 0, into: &out)
        return SheepitClient.bounded(out)
    }

    /// Stop appending once the text is past what `SheepitClient.bounded` would keep.
    private static func isFull(_ out: String) -> Bool {
        out.utf8.count >= SheepitClient.errorCaptureMaxStringUTF8Bytes
    }

    static func placeholder(for value: Any) -> String {
        "<\(SheepitClient.stableName(String(describing: Swift.type(of: value))))>"
    }

    private static func walk(_ value: Any, depth: Int, into out: inout String) {
        guard !isFull(out) else { return }

        // Unwrap first: an `Optional<Int>` held in `Any` also matches `is any BinaryInteger`
        // below, and would print as `Optional(5)`.
        let mirror = Mirror(reflecting: value)
        if mirror.displayStyle == .optional {
            if let wrapped = mirror.children.first {
                walk(wrapped.value, depth: depth, into: &out)
            } else {
                out += "nil"
            }
            return
        }

        // Leaves, printed the way Swift prints them inside an enum payload or a struct.
        switch value {
        case let string as String:
            out += String(reflecting: SheepitClient.bounded(string))
            return
        case let substring as Substring:
            out += String(reflecting: SheepitClient.bounded(String(substring)))
            return
        case let character as Character:
            out += String(reflecting: character)
            return
        case is Bool, is any BinaryInteger, is any BinaryFloatingPoint:
            out += String(describing: value)
            return
        default:
            break
        }

        if Swift.type(of: value) is AnyObject.Type {
            if let number = value as? NSNumber {
                out += number.stringValue
            } else {
                out += placeholder(for: value)
            }
            return
        }

        switch mirror.displayStyle {
        case .collection, .set:
            guard depth < maxDepth else { out += placeholder(for: value); return }
            out += "["
            appendChildren(mirror, labeled: false, depth: depth + 1, into: &out)
            out += "]"
            return
        case .dictionary:
            guard depth < maxDepth else { out += placeholder(for: value); return }
            appendDictionary(mirror, depth: depth + 1, into: &out)
            return
        default:
            break
        }

        // A non-container value with its own description: Foundation value types (`Date`, `URL`,
        // `UUID`, `Decimal`, …) or the host's own type.
        if describesItself(Swift.type(of: value)) {
            out += SheepitClient.bounded(String(describing: value))
            return
        }
        guard depth < maxDepth else { out += placeholder(for: value); return }

        switch mirror.displayStyle {
        case .enum:
            guard let payload = mirror.children.first else {
                // A payload-less, description-less enum prints its case name; nothing to walk.
                out += String(describing: value)
                return
            }
            out += (payload.label ?? "") + "("
            let payloadMirror = Mirror(reflecting: payload.value)
            if payloadMirror.displayStyle == .tuple {
                appendChildren(payloadMirror, labeled: true, depth: depth + 1, into: &out)
            } else {
                walk(payload.value, depth: depth + 1, into: &out)
            }
            out += ")"
        case .struct:
            out += SheepitClient.stableName(String(describing: Swift.type(of: value))) + "("
            appendChildren(mirror, labeled: true, depth: depth + 1, into: &out)
            out += ")"
        case .tuple:
            out += "("
            appendChildren(mirror, labeled: true, depth: depth + 1, into: &out)
            out += ")"
        default:
            out += placeholder(for: value)
        }
    }

    private static func appendChildren(_ mirror: Mirror, labeled: Bool, depth: Int, into out: inout String) {
        var index = 0
        for child in mirror.children {
            guard !isFull(out) else { return }
            if index == maxChildren { out += ", …"; return }
            if index > 0 { out += ", " }
            if labeled, let label = child.label, !label.hasPrefix(".") { out += label + ": " }
            walk(child.value, depth: depth, into: &out)
            index += 1
        }
    }

    private static func appendDictionary(_ mirror: Mirror, depth: Int, into out: inout String) {
        guard !mirror.children.isEmpty else { out += "[:]"; return }
        out += "["
        var index = 0
        for child in mirror.children {
            guard !isFull(out) else { return }
            if index == maxChildren { out += ", …"; break }
            if index > 0 { out += ", " }
            let pair = Array(Mirror(reflecting: child.value).children)
            if pair.count == 2 {
                walk(pair[0].value, depth: depth, into: &out)
                out += ": "
                walk(pair[1].value, depth: depth, into: &out)
            }
            index += 1
        }
        out += "]"
    }
}
