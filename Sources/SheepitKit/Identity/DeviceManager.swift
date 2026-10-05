import Foundation

/// Outcome of a `DeviceManager.register()` attempt. A plain `String?` cannot distinguish
/// "the network hiccupped, try again next launch" from "the server will reject this key or
/// this device forever until a human fixes something" — and those two need different
/// handling: the former is silently retried every cold start (the existing, correct
/// behaviour), the latter must stop hammering the endpoint and tell someone.
enum RegistrationOutcome: Sendable {
    case success(deviceId: String)
    /// Network error, 5xx, or a 400 without the API's `VALIDATION_ERROR` envelope — retried
    /// with a short (≤60s, no jitter) backoff, unchanged by this PR.
    case transientFailure
    /// 400 `VALIDATION_ERROR`/401/403 — a body the API rejects or a revoked/rejected API key.
    /// Retrying on EVERY cold start cannot fix any of these; only a human action can (ship a
    /// corrected build or rotate the key). The caller backs this off rather than retrying
    /// every launch, but must NOT treat it as permanent success either — see
    /// `SheepitClient.start()`'s backoff-window doc for why.
    case terminalFailure(RegistrationRejection)
    /// 402 (hosted daily registration cap) or 422 (environment `MAX_DEVICES_PER_ENVIRONMENT`
    /// ceiling). Split out from `terminalFailure` 2026-09-29 (client-trust hardening): unlike
    /// a revoked key, this device did nothing wrong — a daily cap resets at UTC midnight, and
    /// the environment ceiling is operator-raisable. Fix round 1 (PR #1170 review): 402 joined
    /// 422 here (was falling into `transientFailure`, retried every ≤60s with no jitter — fine
    /// for a network hiccup, wrong for a cap that only clears at midnight). Backs off up to an
    /// HOUR with full jitter (`RegistrationRetryPolicy`), never `SDKDefaults.
    /// deviceRegistrationTerminalBackoff`'s 24h.
    case capReached(RegistrationRejection)
    /// 429 — rate limited. Fix round 1 (PR #1170 review): used to fall into `transientFailure`
    /// (retried every ≤60s with no jitter, ignoring the server's own `Retry-After`). Backs off
    /// like `capReached`, but `retryAfter` (parsed by `HTTPClient`, RFC 7231 §7.1.3) dominates
    /// the jittered value when the server asked for longer.
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

    /// Parses the API's error envelope. A body that is not the envelope yields no reason and no
    /// fields rather than an error: the status alone is enough to back off.
    static func fromBadRequest(body: String) -> RegistrationRejection {
        var rejection = RegistrationRejection(statusCode: 400)
        guard
            let json = try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any],
            let error = json["error"] as? [String: Any]
        else { return rejection }
        if let code = error["code"] as? String, code.utf16.count <= 64,
           code.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber || $0 == "_") }) {
            rejection.reason = code
        }
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

    /// 401 (revoked/invalid key), 403 (forbidden) — the statuses `HTTPClient` throws as
    /// `.httpError` that no amount of retrying will ever turn into success. A 400 is terminal
    /// too but arrives as `.badRequest` (its own catch below). 402/422 (cap reached) and 429
    /// (rate limited) are their OWN cases (caught separately below) — not in this set — since
    /// 2026-09-29 (client-trust hardening): every other 4xx/5xx/network error is
    /// `transientFailure`.
    private static let terminalStatusCodes: Set<Int> = [401, 403]
    /// The hosted daily cap (402) and the environment device-cap (422) — split from
    /// `terminalStatusCodes` above. Fix round 1 (PR #1170 review): 402 joined 422 here.
    private static let capStatusCodes: Set<Int> = [402, 422]

    init(http: HTTPClient, log: Logger) {
        self.http = http
        self.log = log
    }

    /// Register this device with the API.
    func register(anonymousId: String, existingDeviceId: String?) async -> RegistrationOutcome {
        let request = Self.registrationRequest(
            anonymousId: anonymousId,
            existingDeviceId: existingDeviceId,
            locale: Locale.current
        )

        do {
            let response: DeviceRegisterResponse = try await http.post(
                path: SDKEndpoints.deviceRegister,
                body: request
            )
            log.debug("Device registered: \(response.deviceId)")
            return .success(deviceId: response.deviceId)
        } catch SDKError.badRequest(let body) {
            // 🔴 `HTTPClient` throws `.badRequest` for a 400, never `.httpError(400)`, so before this
            // branch a 400 fell through to `transientFailure`: re-sent on every launch, and every
            // 60 s for the life of the process during a logout rotation. The same body gets the
            // same answer, so it is terminal.
            let rejection = RegistrationRejection.fromBadRequest(body: body)
            // Only the API's own validation verdict is terminal. A 400 with no API envelope comes
            // from something in between (a proxy, a load balancer, a captive portal) and says
            // nothing about this body, so it is retried next launch like any other transient.
            guard rejection.reason == RegistrationRejection.validationError else {
                log.warn("Device registration got a 400 without the API's error envelope — retrying next launch")
                return .transientFailure
            }
            log.warn(
                "Device registration rejected (400 \(rejection.reason ?? "unknown")); fields: " +
                    (rejection.rejectedFields.isEmpty ? "none named" : rejection.rejectedFields.joined(separator: ", "))
            )
            return .terminalFailure(rejection)
        } catch SDKError.rateLimited(let retryAfter) {
            log.warn("Device registration rate limited (429) — backing off, honoring Retry-After")
            return .rateLimited(retryAfter: retryAfter)
        } catch SDKError.httpError(let statusCode) where Self.capStatusCodes.contains(statusCode) {
            log.warn("Device registration rejected (\(statusCode), cap reached) — backing off, not every launch")
            return .capReached(RegistrationRejection(statusCode: statusCode))
        } catch SDKError.httpError(let statusCode) where Self.terminalStatusCodes.contains(statusCode) {
            log.warn("Device registration permanently rejected (\(statusCode)) — will not retry every launch")
            return .terminalFailure(RegistrationRejection(statusCode: statusCode))
        } catch {
            log.warn("Device registration failed: \(error.localizedDescription)")
            return .transientFailure
        }
    }

    /// The register body. Every field is bounded to `deviceRegisterSchema`
    /// (`packages/shared/src/schemas/platform.ts`): one field over its limit 400s the whole
    /// request, and a device that cannot register is dead for flags and identity.
    static func registrationRequest(
        anonymousId: String,
        existingDeviceId: String?,
        locale: Locale
    ) -> DeviceRegisterRequest {
        DeviceRegisterRequest(
            deviceId: existingDeviceId,
            anonymousId: anonymousId,
            platform: "ios",
            deviceModel: DeviceProfile.deviceModel(),
            osName: DeviceProfile.osName,
            osVersion: DeviceProfile.osVersion(),
            // Host-supplied Info.plist strings; the schema caps both at 64.
            appVersion: DeviceProfile.appVersion().map { DeviceProfile.bounded($0, SDKDefaults.appVersionMaxLength) },
            buildNumber: DeviceProfile.buildNumber().map { DeviceProfile.bounded($0, SDKDefaults.appVersionMaxLength) },
            locale: DeviceProfile.wireLocaleTag(locale),
            // `length(2)`: a UN M.49 area ("419" on es-419 devices, "001") is sent as no country.
            country: TrackSnapshot.countryCode(locale.region?.identifier),
            timezone: DeviceProfile.timezone()
        )
    }

    /// Post identity resolution to the server.
    ///
    /// Success is the status alone, not a decoded body: the caller only needs to know the device
    /// row now names this user, and a response-shape drift must not make a stored identity look
    /// unconfirmed forever. Re-posting the SAME user is safe: the route's same-user path writes
    /// no merge record and consumes no merge rate limit.
    ///
    /// 🔴 Never sends `attributes`. The SDK used to forward `identify()` traits into
    /// `device_assignments.attributes`, which GDPR erase did not clear — see D-SDK4.
    ///
    /// - Parameter sendIf: checked before every HTTP attempt, retries included (`HTTPClient.postRaw`).
    @discardableResult
    func identify(
        deviceId: String,
        userId: String,
        sendIf: (@Sendable () -> Bool)? = nil
    ) async -> IdentifyOutcome {
        let request = DeviceIdentifyRequest(userId: userId, attributes: nil)

        do {
            _ = try await http.postRaw(
                path: SDKEndpoints.deviceIdentify(deviceId: deviceId),
                body: request,
                sendIf: sendIf
            )
            log.debug("Identity resolved")
            return .stored
        } catch is RequestPreconditionFailed {
            log.debug("Identity resolve abandoned before an attempt: its precondition no longer holds")
            return .notSent
        } catch SDKError.badRequest {
            log.warn("Identity resolve rejected (400)")
            return .rejected(statusCode: 400)
        } catch SDKError.httpError(let statusCode) where Self.isRejection(statusCode) {
            log.warn("Identity resolve rejected (\(statusCode))")
            return .rejected(statusCode: statusCode)
        } catch {
            log.warn("Identity resolve failed: \(error.localizedDescription)")
            return .failed
        }
    }

    /// A 4xx the same request cannot turn into a 2xx by being sent again. 408 is a timeout and
    /// 429 a rate limit (thrown as `SDKError.rateLimited`, never reaching here), so both stay
    /// retryable.
    private static func isRejection(_ statusCode: Int) -> Bool {
        (400..<500).contains(statusCode) && statusCode != 408 && statusCode != 429
    }
}

/// Outcome of `DeviceManager.identify()`.
enum IdentifyOutcome: Sendable, Equatable {
    /// A 2xx: the server's device row holds the posted user.
    case stored
    /// Network error, lost response, 5xx, 408 or 429. The row may or may not hold the user, and
    /// sending the same request later can succeed.
    case failed
    /// Any other 4xx (400 invalid body, 401/403 key, 404 unknown device). Sending
    /// the same request again gets the same answer.
    case rejected(statusCode: Int)
    /// The caller's `sendIf` stopped an attempt. An EARLIER attempt may have been sent (a 5xx or
    /// network error before the retry), so the row may or may not hold the user.
    case notSent
}
