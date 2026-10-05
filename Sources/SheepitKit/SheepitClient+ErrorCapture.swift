import Foundation

/// `captureError(_:error:attributes:)` — the public API for a host app's HANDLED (non-fatal)
/// errors. Emits `$error` through `track()`, so the event carries the same session, device, user,
/// app version and experiment assignments as any other event. See README "Errors".
///
/// The SDK's own internal failures also travel as `$error` (`trackSDKError`); the two are told
/// apart by `origin` (`app` | `sdk`) and `type` (`handled` | `sdk_internal`).
///
/// Collaborators: `ErrorCaptureLimiter` (burst limits), `ErrorAttributeSanitizer` (attribute
/// bounds and the size budget), `BoundedDescription` (crash-safe error text).
extension SheepitClient {
    /// Every string value — reserved and caller-supplied — is cut to this many characters…
    static let errorCaptureMaxStringLength = 500
    /// …and to this many UTF-8 bytes, so a single grapheme cluster stacked with thousands of
    /// combining marks cannot smuggle megabytes past the character cap.
    static let errorCaptureMaxStringUTF8Bytes = 2048

    /// Keys the SDK owns on a captured error. A caller attribute with one of these names is
    /// stored as `attr_<name>` instead (or dropped, if that name is taken too). `source` is
    /// reserved although the SDK never sets it on a handled error: the server's host-app error
    /// predicate treats `source` in (`performance`, `crashes`) as SDK-internal, so a caller value
    /// there would hide the error from host-app error counts.
    static let errorCaptureReservedKeys: Set<String> = [
        "message", "type", "origin", "source",
        "error_type", "error_description", "error_domain", "error_code",
        "suppressed_count", "dropped_count", "attributes_truncated",
    ]

    /// Report a handled (non-fatal) error. Sends a `$error` event with `origin: "app"` and
    /// `type: "handled"`, plus `message`, and — when `error` is given — `error_type`,
    /// `error_description`, `error_domain` and `error_code`. `attributes` are added under their
    /// own keys; a key that collides with a reserved one is stored as `attr_<key>`.
    ///
    /// The SDK sends exactly what it is given — redact URLs, tokens and PII before calling.
    ///
    /// `error_description`: for an `NSError` (or `URLError`, `CocoaError`, `POSIXError`, …) it is
    /// `"<domain> <code>: <text>"`, and `userInfo` is read through CoreFoundation, never printed.
    /// With a non-empty `userInfo` the text is `userInfo[NSLocalizedDescriptionKey]`, else
    /// `userInfo[NSLocalizedFailureReasonErrorKey]`, only when it is a string. With an empty one:
    /// a POSIX error's text is `strerror_r(code)`; otherwise Foundation's `localizedDescription`
    /// is used only when the error's class overrides neither `localizedDescription` nor
    /// `localizedFailureReason`, AND the domain is `NSCocoaErrorDomain` or has no
    /// `userInfoValueProvider` registered (an armed provider can crash the host). Else no text —
    /// so an error whose domain has a provider registered, including Foundation's own on
    /// `NSOSStatusErrorDomain` and `NSMachErrorDomain`, reports only `"<domain> <code>"`.
    /// An `NSObject`-rooted error class always reports its type name. A Swift error whose type
    /// has its own `description` uses it verbatim (your code, your responsibility); any other
    /// Swift error gets Swift's default shape, e.g. `declined(code: 51)`, from a bounded walk that
    /// never describes a class instance or a Foundation collection (see `BoundedDescription`).
    ///
    /// Limits: every string is cut to 500 characters (and 2 KB); keys to 64 characters; at most
    /// 50 attributes, 200 values and ~8 KB of attributes in total — past that, the remaining
    /// attributes (in sorted key order) are dropped and `attributes_truncated: true` is set. A value
    /// JSON cannot carry (`Date`, `URL`, `UUID`, `Float`, `Int64`, a non-finite `Double`, …) is sent
    /// as text; a class instance or Foundation collection that is not JSON as a `<TypeName>`
    /// placeholder. Repeats of the same error within 60 seconds are suppressed and counted
    /// (`suppressed_count` on the next one sent), and at most 30 errors are sent per rolling 60
    /// seconds (`dropped_count` on the next one sent); both windows run on a monotonic clock.
    ///
    /// Never throws and never blocks beyond `track()`. Safe from any thread. A call made from
    /// inside `SheepitConfig.onEvent` while a `captureError` on the same thread is still running
    /// is dropped (`error_capture.reentrant_dropped` diagnostic) instead of recursing. A no-op
    /// once the client is destroyed.
    public func captureError(_ message: String, error: Error? = nil, attributes: [String: Any]? = nil) {
        guard !destroyedFlag.value else { return }
        ErrorCaptureReentrancy.run(
            body: { self.performCaptureError(message, error: error, attributes: attributes) },
            onReentry: {
                self.diagnosticBus.emit(
                    .warn,
                    .transport,
                    code: "error_capture.reentrant_dropped",
                    message: "captureError() was called from inside its own onEvent callback; the nested call was dropped"
                )
            }
        )
    }

    private func performCaptureError(_ message: String, error: Error?, attributes: [String: Any]?) {
        let reserved = Self.errorCaptureReservedProperties(message: message, error: error)
        let signature = [
            reserved["message"], reserved["error_type"], reserved["error_domain"], reserved["error_code"],
        ].map { $0.map { String(describing: $0) } ?? "" }.joined(separator: "\u{1F}")

        switch errorCaptureLimiter.admit(signature: signature) {
        case .suppress(let notify):
            if notify {
                diagnosticBus.emit(
                    .info,
                    .transport,
                    code: "error_capture.suppressed",
                    message: "captureError() is being rate-limited: repeats within 60s, or more than 30 errors per 60s, are counted instead of sent"
                )
            }
            return
        case .send(let suppressedCount, let droppedCount):
            var props = Self.errorCaptureProperties(reserved: reserved, attributes: attributes)
            if suppressedCount > 0 { props["suppressed_count"] = suppressedCount }
            if droppedCount > 0 { props["dropped_count"] = droppedCount }
            track(SDKErrorEvent.name, properties: props)
            addBreadcrumb(
                category: "error",
                message: Self.boundedScreenName(reserved["message"] as? String ?? "")
            )
        }
    }

    // MARK: - Property building (pure)

    /// The SDK-owned properties of a captured error, every string already bounded.
    ///
    /// - `error_type`: `String(reflecting: type(of: error))` — module-qualified (`MyApp.NetworkError`,
    ///   `MyApp.Outer.Inner`) rather than the bare name `String(describing:)` gives, so two types
    ///   with one name in different modules do not merge. The `(unknown context at $…)` segment
    ///   Swift prints for a `private`/`fileprivate` type is removed: its address changes from launch
    ///   to launch, which would split one error into a new group on every run. Accepted price: two
    ///   private error types with the SAME name in the SAME module now share an `error_type` /
    ///   `error_domain` (their `error_description` still differs).
    /// - `error_description`: see `BoundedDescription.of(error:)` — `localizedDescription` only
    ///   with an empty `userInfo`, no override of it, and the Cocoa domain or no registered
    ///   provider (each can otherwise crash the host); POSIX via `strerror_r`; never
    ///   `String(describing:)` of an `NSError` or of any `NSObject`-rooted error.
    /// - `error_domain` / `error_code`: from `error as NSError`, included for EVERY non-nil error.
    ///   Bridging is total; for a Swift enum the domain is its type name and the code is the case
    ///   index, which still tells cases without associated values apart.
    static func errorCaptureReservedProperties(message: String, error: Error?) -> [String: Any] {
        var props: [String: Any] = [
            "message": bounded(message),
            "type": "handled",
            "origin": "app",
        ]
        if let error {
            let bridged = error as NSError
            props["error_type"] = stableName(String(reflecting: Swift.type(of: error)))
            props["error_description"] = BoundedDescription.of(error: error)
            props["error_domain"] = stableName(bridged.domain)
            props["error_code"] = bridged.code
        }
        return props
    }

    /// `reserved` plus the caller's `attributes`, sanitized and budgeted. Reserved keys always win.
    static func errorCaptureProperties(reserved: [String: Any], attributes: [String: Any]?) -> [String: Any] {
        var props = reserved
        guard let attributes, !attributes.isEmpty else { return props }
        if ErrorAttributeSanitizer.merge(attributes, into: &props) {
            props["attributes_truncated"] = true
        }
        return props
    }

    /// At most `errorCaptureMaxStringLength` characters (grapheme clusters, so a character is never
    /// split) and at most `errorCaptureMaxStringUTF8Bytes` UTF-8 bytes.
    static func bounded(_ string: String) -> String {
        bounded(string, characters: errorCaptureMaxStringLength, utf8Bytes: errorCaptureMaxStringUTF8Bytes)
    }

    static func bounded(_ string: String, characters: Int, utf8Bytes: Int) -> String {
        if string.utf8.count <= utf8Bytes, string.count <= characters { return string }
        var out = ""
        var bytes = 0
        var count = 0
        for character in string {
            let size = character.utf8.count
            guard count < characters, bytes + size <= utf8Bytes else { break }
            out.append(character)
            bytes += size
            count += 1
        }
        return out
    }

    /// A type or domain name, launch-stable and bounded: cut to 4 KB first (the regex below cost
    /// 899 ms on a 40 MB domain), stripped of the per-launch `(unknown context at $…).` segment,
    /// then cut to the usual 500 characters — so a long name cannot leave half an address behind.
    static func stableName(_ name: String) -> String {
        bounded(stableTypeName(bounded(name, characters: .max, utf8Bytes: 4096)))
    }

    /// `name` without the per-launch `(unknown context at $…).` segment of a private type.
    static func stableTypeName(_ name: String) -> String {
        name.replacingOccurrences(
            of: #"\(unknown context at \$[0-9a-fA-F]+\)\."#,
            with: "",
            options: .regularExpression
        )
    }
}

/// The `$error` event and its two discriminators. `trackSDKError` and `captureError` both emit
/// it; `origin`/`type` are what a query uses to tell them apart.
enum SDKErrorEvent {
    static let name = "$error"
}

/// Per-thread guard that stops `captureError` (and, under its own key, `recordRequest`) recursing
/// through `SheepitConfig.onEvent`, which `track()` calls synchronously on the caller's thread.
/// Thread-local rather than a lock or a flag on the client: two threads capturing at once are not
/// recursion and must both proceed. One key per API, so `captureError` called from `onEvent`
/// during a `recordRequest` still runs — at most one level, since each API is then blocked. An
/// ASYNC hop (`onEvent` → `DispatchQueue.async` → `captureError`) is not caught here; the
/// limiter's global cap is what bounds it.
enum ErrorCaptureReentrancy {
    static let captureErrorKey = "ai.sheepit.sdk.captureError.state"
    static let recordRequestKey = "ai.sheepit.sdk.recordRequest.state"
    private static let active = 1
    private static let reentryReported = 2

    /// Runs `body` unless this thread is already inside one for `key`. A nested call runs
    /// `onReentry` the FIRST time per outer call only, so a diagnostic subscriber that itself
    /// calls the same API cannot recurse through `onReentry` either.
    static func run(key: String = captureErrorKey, body: () -> Void, onReentry: () -> Void) {
        let storage = Thread.current.threadDictionary
        if let state = storage[key] as? Int {
            if state == active {
                storage[key] = reentryReported
                onReentry()
            }
            return
        }
        storage[key] = active
        defer { storage.removeObject(forKey: key) }
        body()
    }
}
