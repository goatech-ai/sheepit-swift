import Foundation

/// The device-side mirror of the server's caps for `POST /v1/feedback/sdk`
/// (`apps/api/src/lib/feedback/sdk-payload.ts`, `apps/api/src/lib/feedback-attachments`). Lengths
/// are UTF-16 code units, which is what zod counts.
enum FeedbackLimits {
    static let messageMax = 5000
    static let emailMax = 256
    static let attributesMax = 20
    static let attributeStringMax = 256
    static let contextStringMax = 128
    static let userIdMax = 256
    static let deviceIdMax = 256
    static let sessionIdMax = 128
    static let payloadMaxBytes = 16_384
    static let screenshotsMax = 3
    static let screenshotMaxBytes = 1_048_576
    static let screenshotMaxPixelsPerSide = 16_384
    /// The server refuses these keys anywhere in a write (tenancy) or as prototype keys.
    static let refusedAttributeKeys: Set<String> = [
        "projectId", "organizationId", "project_id", "organization_id", "tenantId", "tenant_id",
        "__proto__", "constructor", "prototype",
    ]
    /// zod 3's `.email()` pattern, which the server runs.
    static let emailPattern = #"^(?!\.)(?!.*\.\.)([A-Z0-9_'+\-\.]*)[A-Z0-9_+-]@([A-Z0-9][A-Z0-9\-]*\.)+[A-Z]{2,}$"#
    static let attributeKeyPattern = #"^[A-Za-z0-9_.-]{1,64}$"#
}

/// What the SDK knows about where the feedback came from, filled in by `SheepitClient`. Every
/// field is optional on the wire; one that is empty or over its cap is left out rather than
/// failing the submission.
struct FeedbackContext: Sendable, Equatable {
    var deviceId: String?
    var sessionId: String?
    var userId: String?
    var appVersion: String?
    var buildNumber: String?
    var platform: String?
    var osVersion: String?
    var deviceModel: String?
    var locale: String?
    var screen: String?
    var sdkName: String?
    var sdkVersion: String?
}

/// A validated submission, ready to send or to save: the encoded `payload` JSON and the images.
struct FeedbackSubmission: Sendable, Equatable {
    let payload: Data
    let screenshots: [SheepitFeedbackScreenshot]
}

/// The `payload` part's JSON. Optional fields are omitted, never sent as null: the server's
/// schema is strict and its optional fields do not accept null.
private struct FeedbackPayloadBody: Encodable {
    struct Context: Encodable, Equatable {
        var app_version: String?
        var build_number: String?
        var platform: String?
        var os_version: String?
        var device_model: String?
        var locale: String?
        var screen: String?
        var sdk_name: String?
        var sdk_version: String?
    }

    let message: String
    let type: String
    let email: String?
    let user_id: String?
    let device_id: String?
    let session_id: String?
    let context: Context?
    let attributes: [String: SheepitFeedbackAttributeValue]?
}

enum FeedbackValidator {
    /// Validates in the order the arguments are listed and builds the payload. Mirrors the server's
    /// rules so a submission that passes here is not refused for its shape.
    static func build(
        message: String,
        type: SheepitFeedbackType,
        email: String?,
        attributes: [String: SheepitFeedbackAttributeValue],
        screenshots: [SheepitFeedbackScreenshot],
        context: FeedbackContext
    ) -> Result<FeedbackSubmission, SheepitFeedbackRejection> {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(.emptyMessage) }
        guard trimmed.utf16.count <= FeedbackLimits.messageMax else { return .failure(.messageTooLong) }
        // Postgres `text` cannot hold U+0000: the server refuses it with a 400, and the SDK refuses
        // it first rather than strip characters out of what the user wrote.
        guard !containsNul(trimmed) else { return .failure(.invalidMessage) }

        var cleanEmail: String?
        if let email = email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
            guard email.utf16.count <= FeedbackLimits.emailMax, !containsNul(email),
                  email.range(of: FeedbackLimits.emailPattern, options: [.regularExpression, .caseInsensitive]) != nil
            else { return .failure(.invalidEmail) }
            cleanEmail = email
        }

        guard attributes.count <= FeedbackLimits.attributesMax else { return .failure(.tooManyAttributes) }
        for key in attributes.keys.sorted() {
            guard key.range(of: FeedbackLimits.attributeKeyPattern, options: .regularExpression) != nil,
                  !FeedbackLimits.refusedAttributeKeys.contains(key)
            else { return .failure(.invalidAttribute(key: key)) }
            switch attributes[key] {
            case .string(let value) where value.utf16.count > FeedbackLimits.attributeStringMax || containsNul(value):
                return .failure(.invalidAttribute(key: key))
            case .double(let value) where !value.isFinite:
                return .failure(.invalidAttribute(key: key))
            default:
                break
            }
        }

        guard screenshots.count <= FeedbackLimits.screenshotsMax else { return .failure(.tooManyScreenshots) }
        for (index, screenshot) in screenshots.enumerated() {
            guard screenshot.data.count <= FeedbackLimits.screenshotMaxBytes else {
                return .failure(.screenshotTooLarge(index: index))
            }
            guard let size = FeedbackImageEncoder.pixelSize(of: screenshot.data), size.width > 0, size.height > 0 else {
                return .failure(.invalidScreenshot(index: index))
            }
            guard size.width <= FeedbackLimits.screenshotMaxPixelsPerSide,
                  size.height <= FeedbackLimits.screenshotMaxPixelsPerSide
            else { return .failure(.screenshotTooLarge(index: index)) }
        }

        let body = FeedbackPayloadBody(
            message: trimmed,
            type: type.rawValue,
            email: cleanEmail,
            user_id: fit(context.userId, FeedbackLimits.userIdMax),
            device_id: fit(context.deviceId, FeedbackLimits.deviceIdMax),
            session_id: fit(context.sessionId, FeedbackLimits.sessionIdMax),
            context: wireContext(context),
            attributes: attributes.isEmpty ? nil : attributes
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let payload = try? encoder.encode(body) else { return .failure(.payloadTooLarge) }
        guard payload.count <= FeedbackLimits.payloadMaxBytes else { return .failure(.payloadTooLarge) }
        return .success(FeedbackSubmission(payload: payload, screenshots: screenshots))
    }

    private static func wireContext(_ context: FeedbackContext) -> FeedbackPayloadBody.Context? {
        let cap = FeedbackLimits.contextStringMax
        let wire = FeedbackPayloadBody.Context(
            app_version: bounded(context.appVersion, cap),
            build_number: bounded(context.buildNumber, cap),
            platform: bounded(context.platform, cap),
            os_version: bounded(context.osVersion, cap),
            device_model: bounded(context.deviceModel, cap),
            locale: bounded(context.locale, cap),
            screen: bounded(context.screen, cap),
            sdk_name: bounded(context.sdkName, cap),
            sdk_version: bounded(context.sdkVersion, cap)
        )
        return wire == FeedbackPayloadBody.Context() ? nil : wire
    }

    /// Descriptive context: U+0000 removed (as `boundedScreenName` does), then cut to the cap on
    /// whole characters. Empty is left out.
    private static func bounded(_ value: String?, _ maxUTF16: Int) -> String? {
        guard let value else { return nil }
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: value.unicodeScalars.filter { $0 != "\u{0}" })
        let cut = DeviceProfile.bounded(String(scalars), maxUTF16)
        return cut.isEmpty ? nil : cut
    }

    /// Identifiers: a cut or cleaned id would name someone else, so one over its cap or holding
    /// U+0000 is left out.
    private static func fit(_ value: String?, _ maxUTF16: Int) -> String? {
        guard let value, !value.isEmpty, value.utf16.count <= maxUTF16, !containsNul(value) else { return nil }
        return value
    }

    private static func containsNul(_ value: String) -> Bool {
        value.unicodeScalars.contains("\u{0}")
    }
}
