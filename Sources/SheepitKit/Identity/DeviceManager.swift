import Foundation

/// Outcome of one `DeviceManager.register()` attempt. Classes per
/// `Docs/Technical/SDK_DEVICE_REGISTRATION_CONTRACT.md` § 3; every non-success lands in a class
/// `RegistrationPolicy` persists.
enum RegistrationOutcome: Sendable {
    case success(deviceId: String)
    /// Network error, timeout, 5xx, any unexpected throw, a 2xx whose body does not decode or
    /// whose `device_id` is unusable, a 400/401/403 without the API's error envelope (a WAF, proxy
    /// or captive portal said it, not our API), or any other status. `reason` is the diagnostic
    /// `outcome` value; `retryAfter` the server's `Retry-After`, when it sent one (a 503 does).
    case transientFailure(reason: String, retryAfter: TimeInterval? = nil)
    /// 400 `VALIDATION_ERROR`, or 401/403 carrying the API's own `{error: {code, message}}`
    /// envelope: retrying cannot fix these, only a corrected build or key.
    case terminalFailure(RegistrationRejection)
    /// 402 (hosted daily registration cap) or 422 (environment device ceiling). This device did
    /// nothing wrong; the cap clears on its own. `retryAfter` is the server's `Retry-After`.
    case capReached(RegistrationRejection, retryAfter: TimeInterval?)
    /// 429.
    case rateLimited(retryAfter: TimeInterval?)
}

/// Why the API refused a registration, for diagnostics. Carries the error code and the names of
/// the rejected body fields from a 400's `details.fieldErrors`, never the server's messages or
/// any value this device sent.
struct RegistrationRejection: Sendable, Equatable {
    /// The API's `error.code` for a body its schema rejected (`apps/api/src/routes/v1/devices.ts`).
    static let validationError = "VALIDATION_ERROR"

    let statusCode: Int
    /// The API's `error.code` (`"VALIDATION_ERROR"`), when it sent one.
    var reason: String?
    /// Sorted names of the fields a 400 rejected. Empty for every other status.
    var rejectedFields: [String] = []

    /// A `VALIDATION_ERROR` envelope's code and the names of the rejected body fields (from
    /// `details.fieldErrors`), never the server's messages. A body that is not the envelope yields
    /// no reason and no fields.
    static func fromValidationError(status: Int, body: Data) -> RegistrationRejection {
        var rejection = RegistrationRejection(statusCode: status)
        guard
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let error = json["error"] as? [String: Any]
        else { return rejection }
        rejection.reason = apiErrorCode(in: error)
        if let details = error["details"] as? [String: Any],
           let fieldErrors = details["fieldErrors"] as? [String: Any] {
            rejection.rejectedFields = fieldErrors.keys
                .filter { $0.utf16.count <= 64 }
                .sorted()
                .prefix(20)
                .map { $0 }
        }
        return rejection
    }

    /// The API's `error.code` from an error envelope's `error` object, when it is one of ours
    /// (upper-case ASCII, digits and `_`, at most 64 long); anything else is not trusted as a code.
    static func apiErrorCode(in error: [String: Any]) -> String? {
        guard let code = error["code"] as? String, code.utf16.count <= 64,
              code.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "_") })
        else { return nil }
        return code
    }

    /// The `error.code` of a body that is our API's full `{error: {code, message}}` envelope, or nil.
    /// Stricter than `apiErrorCode(body:)`: a message is required too, so a proxy page that happens
    /// to carry an upper-case `code` is not mistaken for our API.
    static func apiErrorCode(envelope body: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let error = json["error"] as? [String: Any],
            error["message"] is String
        else { return nil }
        return apiErrorCode(in: error)
    }

    /// `apiErrorCode(in:)` for a whole response body; nil when the body is not the envelope.
    static func apiErrorCode(body: Data) -> String? {
        guard
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let error = json["error"] as? [String: Any]
        else { return nil }
        return apiErrorCode(in: error)
    }

    /// Diagnostic payload fields shared by the launch and rotation paths.
    var diagnosticData: [String: AnyCodable] {
        var data: [String: AnyCodable] = ["status_code": AnyCodable(statusCode)]
        if let reason { data["reason"] = AnyCodable(reason) }
        if !rejectedFields.isEmpty { data["rejected_fields"] = AnyCodable(rejectedFields) }
        return data
    }
}

/// Handles device registration with the Sheepit API.
/// Mirrors packages/sdk-js/src/device.ts
actor DeviceManager {
    private let http: HTTPClient
    private let log: Logger
    /// `SheepitConfig.appVersion`; see `DeviceProfile.wireAppVersion(override:)`.
    private let appVersionOverride: String?

    private static let terminalStatusCodes: Set<Int> = [401, 403]
    private static let capStatusCodes: Set<Int> = [402, 422]

    /// USABLE (contract § 1): what the SDK may store, send and adopt — 1–256 characters of
    /// printable ASCII `0x21`–`0x7E`, and not `.` or `..` (dot segments collapse in a URL path).
    /// Deliberately wider than what the SDK mints (STRICT, a lowercase UUIDv4,
    /// `ContextManager.mintDeviceId`): the server honours legacy rows of any shape, so a stored or
    /// returned `legacy:odd` is kept verbatim. A 2xx with an unusable id is transient and never
    /// adopted; a stored unusable id is replaced before the first send. Path use is safe either way:
    /// `SDKEndpoints.pathSegment` percent-encodes every byte outside `A-Za-z0-9-_~`.
    static func isUsableDeviceId(_ id: String) -> Bool {
        unusableDeviceIdReason(id) == nil
    }

    /// Why `id` is not USABLE (`empty` | `too_long` | `dot_segment` | `invalid_character`), or nil.
    static func unusableDeviceIdReason(_ id: String) -> String? {
        if id.isEmpty { return "empty" }
        if id.utf8.count > 256 { return "too_long" }
        if id == "." || id == ".." { return "dot_segment" }
        return id.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) } ? nil : "invalid_character"
    }

    init(http: HTTPClient, log: Logger, appVersionOverride: String?) {
        self.http = http
        self.log = log
        self.appVersionOverride = appVersionOverride
    }

    /// One registration request, proposing `proposedDeviceId` ("client proposes, server
    /// disposes"): the server honours a well-formed proposal and the SDK adopts whatever
    /// `device_id` comes back. The proposal is unchanged on every retry, so it is also the
    /// idempotency key. Exactly ONE HTTP attempt (`postOnceRaw`): `RegistrationPolicy` is the only
    /// retry layer. Contract: `Docs/Technical/SDK_DEVICE_REGISTRATION_CONTRACT.md`.
    func register(anonymousId: String, proposedDeviceId: String) async -> RegistrationOutcome {
        let request = Self.registrationRequest(
            anonymousId: anonymousId,
            proposedDeviceId: proposedDeviceId,
            appVersionOverride: appVersionOverride,
            locale: Locale.current
        )
        let data: Data
        let response: HTTPURLResponse
        do {
            (data, response) = try await http.postOnceRaw(
                path: SDKEndpoints.deviceRegister, body: request,
                timeout: RegistrationPolicy.registerRequestTimeoutSeconds
            )
        } catch {
            log.warn("Device registration failed: \(error.localizedDescription)")
            return .transientFailure(reason: "network_error", retryAfter: nil)
        }
        return Self.classify(status: response.statusCode, body: data, response: response, log: log)
    }

    /// The outcome for one answered request. Static so the mapping is testable on its own.
    static func classify(status: Int, body: Data, response: HTTPURLResponse?, log: Logger) -> RegistrationOutcome {
        let retryAfter = HTTPClient.parseRetryAfter(response?.value(forHTTPHeaderField: "Retry-After"))
        switch status {
        case 200..<300:
            guard let decoded = try? JSONDecoder().decode(ApiDataResponse<DeviceRegisterResponse>.self, from: body) else {
                log.warn("Device registration answered \(status) with a body that does not decode — retrying")
                return .transientFailure(reason: "malformed_response", retryAfter: retryAfter)
            }
            guard isUsableDeviceId(decoded.data.deviceId) else {
                log.warn("Device registration answered an unusable device_id — not adopted, retrying")
                return .transientFailure(reason: "unusable_device_id", retryAfter: retryAfter)
            }
            log.debug("Device registered: \(decoded.data.deviceId)")
            return .success(deviceId: decoded.data.deviceId)
        case 429:
            // Row 5: a rate limit, with or without our envelope.
            log.warn("Device registration rate limited (429) — backing off, honoring Retry-After")
            return .rateLimited(retryAfter: retryAfter)
        case 400..<500:
            return classifyClientError(status: status, body: body, retryAfter: retryAfter, log: log)
        case 500...:
            log.warn("Device registration failed (\(status)) — retrying")
            return .transientFailure(reason: "server_error", retryAfter: retryAfter)
        default:
            log.warn("Device registration answered \(status) — retrying")
            return .transientFailure(reason: "unexpected_status", retryAfter: retryAfter)
        }
    }

    /// A 4xx other than 429. The class is decided by OUR envelope (`{error: {code, message}}`), not
    /// by the status alone — a cross-SDK rule (`Docs/Technical/SDK_DEVICE_REGISTRATION_CONTRACT.md`
    /// § 3), applied in this order:
    ///   2. `VALIDATION_ERROR` on any 4xx (400, 422) → terminal 24 h;
    ///   3. 401/403 with an envelope → terminal 24 h;
    ///   4. 402/422 with an envelope, any other code (`PREVIEW_LIMIT_EXCEEDED`, `LIMIT_REACHED`) → cap;
    ///   6. anything else, including every 4xx without our envelope (a WAF, proxy or captive
    ///      portal said it, not our API) → transient.
    private static func classifyClientError(
        status: Int,
        body: Data,
        retryAfter: TimeInterval?,
        log: Logger
    ) -> RegistrationOutcome {
        guard let code = RegistrationRejection.apiErrorCode(envelope: body) else {
            log.warn("Device registration got a \(status) without the API's error envelope — retrying")
            let reason: String
            switch status {
            case 400: reason = "bad_request_unrecognized"
            case 401, 403: reason = "auth_rejected_unrecognized"
            case 402, 422: reason = "cap_unrecognized"
            default: reason = "unexpected_status"
            }
            return .transientFailure(reason: reason, retryAfter: retryAfter)
        }
        if code == RegistrationRejection.validationError {
            let rejection = RegistrationRejection.fromValidationError(status: status, body: body)
            log.warn(
                "Device registration rejected (\(status) \(code)); fields: " +
                    (rejection.rejectedFields.isEmpty ? "none named" : rejection.rejectedFields.joined(separator: ", "))
            )
            return .terminalFailure(rejection)
        }
        if terminalStatusCodes.contains(status) {
            log.warn("Device registration permanently rejected (\(status) \(code)) — backing off 24 h")
            return .terminalFailure(RegistrationRejection(statusCode: status, reason: code))
        }
        if capStatusCodes.contains(status) {
            log.warn("Device registration rejected (\(status) \(code), cap reached) — backing off")
            return .capReached(RegistrationRejection(statusCode: status, reason: code), retryAfter: retryAfter)
        }
        log.warn("Device registration answered \(status) \(code) — retrying")
        return .transientFailure(reason: "unexpected_status", retryAfter: retryAfter)
    }

    /// The register body. Every field is bounded to `deviceRegisterSchema`
    /// (`packages/shared/src/schemas/platform.ts`): one field over its limit 400s the whole
    /// request, and a device that cannot register is dead for flags and identity.
    static func registrationRequest(
        anonymousId: String,
        proposedDeviceId: String,
        appVersionOverride: String?,
        locale: Locale
    ) -> DeviceRegisterRequest {
        DeviceRegisterRequest(
            deviceId: proposedDeviceId,
            anonymousId: anonymousId,
            platform: DeviceProfile.platform,
            deviceModel: DeviceProfile.deviceModel(),
            osName: DeviceProfile.osName,
            osVersion: DeviceProfile.osVersion(),
            // The same version and build events, crashes and perf send; the schema caps both at 64.
            appVersion: DeviceProfile.wireAppVersion(override: appVersionOverride),
            buildNumber: DeviceProfile.wireBuildNumber(),
            locale: DeviceProfile.wireLocaleTag(locale),
            // `length(2)`: a UN M.49 area ("419" on es-419 devices, "001") is sent as no country.
            country: TrackSnapshot.countryCode(locale.region?.identifier),
            timezone: DeviceProfile.timezone()
        )
    }

    /// One identify request (`POST /v1/devices/:id/identify`); `IdentifyLadder` decides what to do
    /// with the answer. Single attempt: the ladder owns every retry, so its attempt count is the
    /// number of POSTs sent and a 503's `Retry-After` reaches it.
    ///
    /// Success is the status alone, not a decoded body: the caller only needs to know the device
    /// row now names this user, and a response-shape drift must not make a stored identity look
    /// unconfirmed forever. Re-posting the SAME user is safe: the route's same-user path writes
    /// no merge record and consumes no merge rate limit.
    ///
    /// 🔴 Never sends `attributes`. The SDK used to forward `identify()` traits into
    /// `device_assignments.attributes`, which GDPR erase did not clear — see D-SDK4.
    ///
    /// - Parameter sendIf: checked right before the request goes out.
    /// - Returns: nil when nothing was sent (`sendIf` no longer held, or the task was cancelled);
    ///   status 0 for a network error or timeout.
    func identifyOnce(
        deviceId: String,
        userId: String,
        sendIf: (@Sendable () -> Bool)? = nil
    ) async -> IdentifyResponse? {
        let request = DeviceIdentifyRequest(userId: userId, attributes: nil)
        do {
            let (data, response) = try await http.postOnceRaw(
                path: SDKEndpoints.deviceIdentify(deviceId: deviceId),
                body: request,
                sendIf: sendIf
            )
            let status = response.statusCode
            if (200..<300).contains(status) {
                log.debug("Identity resolved")
                return IdentifyResponse(status: status, retryAfter: nil, code: nil)
            }
            log.warn("Identity resolve answered \(status)")
            return IdentifyResponse(
                status: status,
                retryAfter: HTTPClient.parseRetryAfter(response.value(forHTTPHeaderField: "Retry-After")),
                code: RegistrationRejection.apiErrorCode(body: data)
            )
        } catch is RequestPreconditionFailed {
            log.debug("Identity resolve abandoned before an attempt: its precondition no longer holds")
            return nil
        } catch {
            if error is CancellationError || Task.isCancelled { return nil }
            log.warn("Identity resolve failed: \(error.localizedDescription)")
            return IdentifyResponse(status: 0, retryAfter: nil, code: nil)
        }
    }
}

