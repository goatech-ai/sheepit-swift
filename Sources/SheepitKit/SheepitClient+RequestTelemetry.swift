import Foundation

/// `recordRequest(method:url:status:durationMs:responseBytes:error:)` — the public API for a host
/// app's FAILED first-party HTTP requests. Emits `$http_error` (the event sdk-js's fetch capture
/// already sends) through `track()`, so it carries the same session, device, user, app version and
/// experiment assignments as every other event. See README "Network request failures".
///
/// Reuses `captureError`'s hardened parts rather than its instances: its own
/// `ErrorCaptureLimiter` (so request failures cannot starve `captureError`, nor the reverse), the
/// per-thread `ErrorCaptureReentrancy` guard under its own key, `bounded` / `stableName`, and
/// `BoundedDescription` for the error text. `RequestTelemetryPolicy` decides what is recordable.
extension SheepitClient {
    /// Methods are short; anything longer is a caller bug, not information.
    static let requestTelemetryMaxMethodLength = 32

    /// Record a first-party HTTP request your app made — only if it FAILED. Sends a
    /// `$http_error` event when `status` is 400 or above, or when `status` is nil, 0 or negative
    /// (a transport failure: no HTTP response at all; pass the reason as `error`). A status from
    /// 1 to 399 returns at once and sends nothing, so it is cheap to call for every request.
    ///
    /// Opt-in: nothing is recorded unless the URL's host is in `SheepitConfig.requestTelemetryHosts`.
    /// A URL on the SDK's own `apiUrl` is never recorded.
    ///
    /// Sent: `url` (scheme, host, non-default port and path — never the query, fragment or
    /// userinfo), `host`, `path`, `method`, `status` (`0` for a transport failure, as sdk-js does),
    /// `latency_ms`, `kind` (`http_error` | `network_failure`), `origin: "app"`, `response_bytes`
    /// when given and not negative, and for an `error`: `error_name`, `error_message`,
    /// `error_domain`, `error_code` (plus `aborted` on a transport failure). Never headers or
    /// bodies. 🔴 The path is sent verbatim — keep tokens and personal data out of your paths.
    ///
    /// Limits: the same method + host + path + status is sent at most once per 60 seconds
    /// (repeats are counted as `suppressed_count` on the next one sent), and at most 30 per
    /// rolling 60 seconds across all requests (`dropped_count`). Strings are cut to 500
    /// characters and 2 KB; the method to 32 characters.
    ///
    /// Never throws and never blocks beyond `track()`. Safe from any thread. A call made from
    /// inside `SheepitConfig.onEvent` while a `recordRequest` on the same thread is still running
    /// is dropped (`request_telemetry.reentrant_dropped` diagnostic). A no-op once the client is
    /// destroyed.
    ///
    /// - Parameters:
    ///   - method: The HTTP method, e.g. `"GET"`. Uppercased; empty means `GET`.
    ///   - url: The request URL. Only its scheme, host, port and path are used.
    ///   - status: The HTTP status code, or nil (or 0, or a negative value) when no response arrived.
    ///   - durationMs: How long the request took, in milliseconds. Sent rounded.
    ///   - responseBytes: The response body size, if known. A negative value (e.g.
    ///     `URLResponse.expectedContentLength`'s `-1`) is not sent.
    ///   - error: Why the request failed, typically the `URLError` of a transport failure.
    public func recordRequest(
        method: String,
        url: URL,
        status: Int?,
        durationMs: Double,
        responseBytes: Int? = nil,
        error: Error? = nil
    ) {
        guard !destroyedFlag.value else { return }
        let status = Self.httpStatus(status)
        if let status, status < 400 { return }
        guard let target = requestTelemetryPolicy.target(for: url) else { return }
        ErrorCaptureReentrancy.run(
            key: ErrorCaptureReentrancy.recordRequestKey,
            body: {
                self.performRecordRequest(
                    method: method, target: target, status: status,
                    durationMs: durationMs, responseBytes: responseBytes, error: error
                )
            },
            onReentry: {
                self.diagnosticBus.emit(
                    .warn,
                    .transport,
                    code: "request_telemetry.reentrant_dropped",
                    message: "recordRequest() was called from inside its own onEvent callback; the nested call was dropped"
                )
            }
        )
    }

    private func performRecordRequest(
        method: String,
        target: RequestTelemetryPolicy.Target,
        status: Int?,
        durationMs: Double,
        responseBytes: Int?,
        error: Error?
    ) {
        // The signature only — the error text (`BoundedDescription`, `stableName`) is built after
        // `admit`, so a suppressed repeat in a tight loop costs a URL reduction and a lock.
        let methodValue = Self.requestMethod(method)
        let host = Self.bounded(target.host)
        let path = Self.bounded(target.path)
        let outcome = status.map(String.init) ?? RequestTelemetryKind.networkFailure
        let signature = [methodValue, host, path, outcome].joined(separator: "\u{1F}")

        switch requestTelemetryLimiter.admit(signature: signature) {
        case .suppress(let notify):
            if notify {
                diagnosticBus.emit(
                    .info,
                    .transport,
                    code: "request_telemetry.suppressed",
                    message: "recordRequest() is being rate-limited: repeats within 60s, or more than 30 failures per 60s, are counted instead of sent"
                )
            }
            return
        case .send(let suppressedCount, let droppedCount):
            var props = Self.requestTelemetryProperties(
                method: method, target: target, status: status,
                durationMs: durationMs, responseBytes: responseBytes, error: error
            )
            if suppressedCount > 0 { props["suppressed_count"] = suppressedCount }
            if droppedCount > 0 { props["dropped_count"] = droppedCount }
            track(RequestTelemetryKind.eventName, properties: props)
            addBreadcrumb(
                category: "http",
                message: Self.boundedScreenName("\(methodValue) \(host)\(path) \(outcome)")
            )
        }
    }

    // MARK: - Property building (pure)

    /// `status` as an HTTP status, or nil for a transport failure: nil, 0 (what the wire carries
    /// for one, and what sdk-js passes) and any negative value (e.g. a `URLError` code passed by
    /// mistake) all mean "no response".
    static func httpStatus(_ status: Int?) -> Int? {
        guard let status, status > 0 else { return nil }
        return status
    }

    /// Every property of a recorded request except the limiter's counts, every string bounded.
    /// The error fields come only from `stableName`, `BoundedDescription` and the `NSError`
    /// bridge's domain and code — never from the error's own `localizedDescription`/`description`.
    static func requestTelemetryProperties(
        method: String,
        target: RequestTelemetryPolicy.Target,
        status: Int?,
        durationMs: Double,
        responseBytes: Int?,
        error: Error?
    ) -> [String: Any] {
        let status = httpStatus(status)
        var props: [String: Any] = [
            "url": bounded(target.url),
            "host": bounded(target.host),
            "path": bounded(target.path),
            "method": requestMethod(method),
            "status": status ?? 0,
            "latency_ms": latencyMs(durationMs),
            "kind": status == nil ? RequestTelemetryKind.networkFailure : RequestTelemetryKind.httpError,
            "origin": "app",
        ]
        if let responseBytes, responseBytes >= 0 { props["response_bytes"] = responseBytes }
        if let error {
            let bridged = error as NSError
            props["error_name"] = stableName(String(reflecting: Swift.type(of: error)))
            props["error_message"] = BoundedDescription.of(error: error)
            props["error_domain"] = stableName(bridged.domain)
            props["error_code"] = bridged.code
            if status == nil {
                props["aborted"] = bridged.domain == NSURLErrorDomain && bridged.code == NSURLErrorCancelled
            }
        }
        return props
    }

    /// Trimmed, uppercased, at most `requestTelemetryMaxMethodLength` characters; empty → `GET`
    /// (`URLRequest`'s own default).
    static func requestMethod(_ method: String) -> String {
        let trimmed = bounded(method, characters: 256, utf8Bytes: 1024)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        let cut = bounded(trimmed, characters: requestTelemetryMaxMethodLength, utf8Bytes: requestTelemetryMaxMethodLength * 4)
        return cut.isEmpty ? "GET" : cut
    }

    /// Rounded to whole milliseconds, like sdk-js's `Date.now()` difference. `Int(_:)` traps on a
    /// non-finite or out-of-range `Double`, so those become 0 (non-finite, negative) or
    /// `Int32.max` (about 24.8 days).
    static func latencyMs(_ durationMs: Double) -> Int {
        guard durationMs.isFinite, durationMs > 0 else { return 0 }
        guard durationMs < Double(Int32.max) else { return Int(Int32.max) }
        return Int(durationMs.rounded())
    }
}

/// `$http_error` and its `kind` values, shared with sdk-js (`http-error-capture.ts`).
enum RequestTelemetryKind {
    static let eventName = "$http_error"
    static let httpError = "http_error"
    static let networkFailure = "network_failure"
}
