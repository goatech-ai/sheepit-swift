import Foundation

/// Public types of `submitFeedback(message:type:email:attributes:screenshots:)`
/// (`SheepitClient+Feedback.swift`). Wire contract: `POST /v1/feedback/sdk`
/// (`apps/api/src/routes/v1/feedback-sdk.ts`, payload schema `apps/api/src/lib/feedback/sdk-payload.ts`).

/// What the feedback is about. Sent as the payload's `type`.
public enum SheepitFeedbackType: String, Sendable, CaseIterable {
    case bug
    case feature
    case general
}

/// One value of `submitFeedback`'s `attributes`. Write literals: `["plan": "pro", "seats": 3, "beta": true]`.
public enum SheepitFeedbackAttributeValue: Sendable, Equatable, Encodable,
    ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral,
    ExpressibleByBooleanLiteral {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)

    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        }
    }
}

/// An image attached to feedback: PNG or JPEG bytes, at most 1 MiB and 16384 pixels a side
/// (the server's limits; `submitFeedback` checks them before sending).
///
/// The SDK never captures the screen. The app passes an image it took itself, either already
/// encoded (`init?(data:)`) or as a `UIImage` / `NSImage`, which the SDK encodes as JPEG.
public struct SheepitFeedbackScreenshot: Sendable, Equatable {
    public enum Format: String, Sendable {
        case jpeg
        case png
    }

    /// The encoded image, exactly as it is uploaded.
    public let data: Data
    public let format: Format

    /// PNG or JPEG bytes, judged by their first bytes (not by a file name). Nil for anything else.
    /// Size and dimensions are checked when the feedback is submitted.
    public init?(data: Data) {
        guard let format = Self.sniff(data) else { return nil }
        self.data = data
        self.format = format
    }

    static let pngSignature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    static let jpegSignature: [UInt8] = [0xFF, 0xD8, 0xFF]

    static func sniff(_ data: Data) -> Format? {
        if data.starts(with: pngSignature) { return .png }
        if data.starts(with: jpegSignature) { return .jpeg }
        return nil
    }

    var mimeType: String { format == .png ? "image/png" : "image/jpeg" }
    var fileExtension: String { format == .png ? "png" : "jpg" }
}

/// What happened to one `submitFeedback` call.
public enum SheepitFeedbackResult: Sendable, Equatable {
    /// Stored by the server. `id` is the feedback row's id ("" if a 2xx body could not be read).
    case sent(id: String)
    /// Not delivered yet (offline, timeout, 408, 429, 5xx) and saved on the device, under the
    /// client's apiUrl, environment and key. The SDK retries it one request at a time, honouring
    /// `Retry-After` across relaunches, until it is delivered, refused, or 7 days old (at most 10
    /// are kept; the oldest goes first). `reset()` deletes everything saved, under every key.
    /// What was saved under a key, environment or apiUrl no client uses any more is deleted at a
    /// later start once all of it is over 7 days old. `destroy()` deletes nothing.
    case queued
    /// Not sent and not saved. Re-sending the same feedback gets the same answer.
    case rejected(SheepitFeedbackRejection)
}

/// Why feedback was rejected. Every case but `server` is decided on the device, with no request.
public enum SheepitFeedbackRejection: Error, Sendable, Equatable {
    /// The message is empty after trimming whitespace.
    case emptyMessage
    /// Over 5000 characters (UTF-16 code units) after trimming.
    case messageTooLong
    /// Contains U+0000 (NUL), which the server cannot store.
    case invalidMessage
    /// Not an email address the server accepts, over 256 characters, or containing U+0000.
    case invalidEmail
    /// More than 20 attributes.
    case tooManyAttributes
    /// A key that is not 1-64 of `A-Z a-z 0-9 _ . -`, a reserved key, a string value over 256
    /// characters, a string containing U+0000, or a non-finite number.
    case invalidAttribute(key: String)
    /// More than 3 screenshots.
    case tooManyScreenshots
    /// The screenshot at `index` is over 1 MiB or over 16384 pixels on a side.
    case screenshotTooLarge(index: Int)
    /// The screenshot at `index` could not be read as an image.
    case invalidScreenshot(index: Int)
    /// The encoded payload (message, email, attributes and context) is over 16 KiB.
    case payloadTooLarge
    /// The client was destroyed, or its configuration was rejected (`status().rejectionReason`).
    case clientUnavailable
    /// The feedback could not be delivered and saving it for a retry failed (disk full or not writable).
    case queueUnavailable
    /// The server refused it: a 4xx other than 408 and 429. `code` is the API's error code
    /// (e.g. `VALIDATION_ERROR`, `KEY_TYPE_NOT_ALLOWED`) when the body carried one.
    case server(statusCode: Int, code: String?)

    /// The case name alone, for diagnostics: never the attribute key, which is the app's data.
    var diagnosticName: String {
        switch self {
        case .emptyMessage: return "empty_message"
        case .messageTooLong: return "message_too_long"
        case .invalidMessage: return "invalid_message"
        case .invalidEmail: return "invalid_email"
        case .tooManyAttributes: return "too_many_attributes"
        case .invalidAttribute: return "invalid_attribute"
        case .tooManyScreenshots: return "too_many_screenshots"
        case .screenshotTooLarge: return "screenshot_too_large"
        case .invalidScreenshot: return "invalid_screenshot"
        case .payloadTooLarge: return "payload_too_large"
        case .clientUnavailable: return "client_unavailable"
        case .queueUnavailable: return "queue_unavailable"
        case .server: return "server"
        }
    }
}
