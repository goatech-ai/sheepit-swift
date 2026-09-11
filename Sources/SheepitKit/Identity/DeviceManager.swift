import Foundation

/// Outcome of a `DeviceManager.register()` attempt. A plain `String?` cannot distinguish
/// "the network hiccupped, try again next launch" from "the server will reject this key or
/// this device forever until a human fixes something" — and those two need different
/// handling: the former is silently retried every cold start (the existing, correct
/// behaviour), the latter must stop hammering the endpoint and tell someone.
enum RegistrationOutcome: Sendable {
    case success(deviceId: String)
    /// Network error, 5xx, 400, or 429 — the next launch's `start()` should retry
    /// unconditionally, exactly as before this type existed.
    case transientFailure
    /// 401/403/422 — a revoked/rejected API key or a device-cap ceiling. Retrying on
    /// EVERY cold start cannot fix any of these; only a human action can (rotate the key,
    /// ship a corrected one, or free up capacity). The caller backs this off rather than
    /// retrying every launch, but must NOT treat it as permanent success either — see
    /// `SheepitClient.start()`'s backoff-window doc for why.
    case terminalFailure(statusCode: Int)
}

/// Handles device registration with the Sheepit API.
/// Mirrors packages/sdk-js/src/device.ts
actor DeviceManager {
    private let http: HTTPClient
    private let log: Logger

    /// 401 (revoked/invalid key), 403 (forbidden), 422 (device-cap reached) — the set the
    /// server can return for `/v1/devices/register` that no amount of retrying will ever
    /// turn into success. Every other 4xx/5xx/network error is `transientFailure`.
    private static let terminalStatusCodes: Set<Int> = [401, 403, 422]

    init(http: HTTPClient, log: Logger) {
        self.http = http
        self.log = log
    }

    /// Register this device with the API.
    func register(anonymousId: String, existingDeviceId: String?) async -> RegistrationOutcome {
        let request = DeviceRegisterRequest(
            deviceId: existingDeviceId,
            anonymousId: anonymousId,
            platform: "ios",
            deviceModel: DeviceProfile.deviceModel(),
            osName: DeviceProfile.osName,
            osVersion: DeviceProfile.osVersion(),
            appVersion: DeviceProfile.appVersion(),
            buildNumber: DeviceProfile.buildNumber(),
            locale: Locale.current.identifier,
            country: Locale.current.region?.identifier,
            timezone: DeviceProfile.timezone()
        )

        do {
            let response: DeviceRegisterResponse = try await http.post(
                path: SDKEndpoints.deviceRegister,
                body: request
            )
            log.debug("Device registered: \(response.deviceId)")
            return .success(deviceId: response.deviceId)
        } catch SDKError.httpError(let statusCode) where Self.terminalStatusCodes.contains(statusCode) {
            log.warn("Device registration permanently rejected (\(statusCode)) — will not retry every launch")
            return .terminalFailure(statusCode: statusCode)
        } catch {
            log.warn("Device registration failed: \(error.localizedDescription)")
            return .transientFailure
        }
    }

    /// Post identity resolution to the server.
    func identify(deviceId: String, userId: String, attributes: [String: Any]? = nil) async {
        let attrMap: [String: AnyCodable]? = attributes?.mapValues { AnyCodable($0) }
        let request = DeviceIdentifyRequest(userId: userId, attributes: attrMap)

        do {
            let _: DeviceIdentifyResponse = try await http.post(
                path: SDKEndpoints.deviceIdentify(deviceId: deviceId),
                body: request
            )
            log.debug("Identity resolved: \(userId)")
        } catch {
            log.warn("Identity resolve failed: \(error.localizedDescription)")
        }
    }
}
