import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Handles device registration with the Sheepit API.
/// Mirrors packages/sdk-js/src/device.ts
actor DeviceManager {
    private let http: HTTPClient
    private let log: GTLogger

    init(http: HTTPClient, log: GTLogger) {
        self.http = http
        self.log = log
    }

    /// Register this device with the API. Returns the server-assigned device ID.
    func register(anonymousId: String, existingDeviceId: String?) async -> String? {
        let request = DeviceRegisterRequest(
            deviceId: existingDeviceId,
            anonymousId: anonymousId,
            platform: "ios",
            deviceModel: deviceModel(),
            osName: "iOS",
            osVersion: osVersion(),
            appVersion: appVersion(),
            buildNumber: buildNumber(),
            locale: Locale.current.identifier,
            country: Locale.current.region?.identifier,
            timezone: TimeZone.current.identifier
        )

        do {
            let response: DeviceRegisterResponse = try await http.post(
                path: SDKEndpoints.deviceRegister,
                body: request
            )
            log.debug("Device registered: \(response.deviceId)")
            return response.deviceId
        } catch {
            log.warn("Device registration failed: \(error.localizedDescription)")
            return nil
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

    // MARK: - Device Info

    private func deviceModel() -> String {
        #if canImport(UIKit)
        return UIDevice.current.model
        #else
        return "Mac"
        #endif
    }

    private func osVersion() -> String {
        #if canImport(UIKit)
        return UIDevice.current.systemVersion
        #else
        return ProcessInfo.processInfo.operatingSystemVersionString
        #endif
    }

    private func appVersion() -> String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    private func buildNumber() -> String? {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }
}
