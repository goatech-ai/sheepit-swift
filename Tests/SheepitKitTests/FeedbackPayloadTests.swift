import CoreGraphics
import XCTest
@testable import SheepitKit

/// `FeedbackValidator` (the server's caps, on the device), `MultipartFormData` (exact wire bytes),
/// `SheepitFeedbackScreenshot` sniffing and `FeedbackImageEncoder`. No network.
final class FeedbackPayloadTests: XCTestCase {
    private let context = FeedbackContext(
        deviceId: "device-1", sessionId: "session-1", userId: "user-1", appVersion: "2.1.0",
        buildNumber: "42", platform: "ios", osVersion: "18.1", deviceModel: "iPhone16,2",
        locale: "en-US", screen: "Checkout", sdkName: "sdk-swift", sdkVersion: "0.8.0"
    )

    private func build(
        message: String = "It broke",
        email: String? = nil,
        attributes: [String: SheepitFeedbackAttributeValue] = [:],
        screenshots: [SheepitFeedbackScreenshot] = [],
        context: FeedbackContext? = nil
    ) -> Result<FeedbackSubmission, SheepitFeedbackRejection> {
        FeedbackValidator.build(
            message: message, type: .bug, email: email, attributes: attributes,
            screenshots: screenshots, context: context ?? self.context
        )
    }

    private func rejection(_ result: Result<FeedbackSubmission, SheepitFeedbackRejection>) -> SheepitFeedbackRejection? {
        if case .failure(let rejection) = result { return rejection }
        return nil
    }

    private func payload(_ result: Result<FeedbackSubmission, SheepitFeedbackRejection>) throws -> [String: Any] {
        let submission = try result.get()
        return try XCTUnwrap(JSONSerialization.jsonObject(with: submission.payload) as? [String: Any])
    }

    // MARK: - Message and email

    func testMessageIsTrimmedAndBoundedAt5000UTF16Units() throws {
        XCTAssertEqual(rejection(build(message: "  \n\t ")), .emptyMessage)
        XCTAssertEqual(rejection(build(message: String(repeating: "a", count: 5001))), .messageTooLong)
        XCTAssertNil(rejection(build(message: "  " + String(repeating: "a", count: 5000) + "\n")))
        // An emoji is two UTF-16 units, which is what the server's zod `.max()` counts.
        XCTAssertEqual(rejection(build(message: String(repeating: "😀", count: 2501))), .messageTooLong)
        XCTAssertEqual(try payload(build(message: "  It broke \n"))["message"] as? String, "It broke")
    }

    func testEmailMustBeAnAddressTheServerAccepts() throws {
        for bad in ["nope", "a@b", "a..b@example.com", ".a@example.com", "a@example.c", String(repeating: "a", count: 250) + "@example.com"] {
            XCTAssertEqual(rejection(build(email: bad)), .invalidEmail, bad)
        }
        XCTAssertEqual(try payload(build(email: " Jane.Doe+qa@example.co.uk "))["email"] as? String, "Jane.Doe+qa@example.co.uk")
        XCTAssertNil(try payload(build(email: "   "))["email"], "a blank email is left out, not refused")
    }

    func testNulIsRefusedInWhatTheUserWroteAndRemovedFromContext() throws {
        XCTAssertEqual(rejection(build(message: "a\u{0}b")), .invalidMessage)
        XCTAssertEqual(rejection(build(email: "a\u{0}@example.com")), .invalidEmail)
        XCTAssertEqual(rejection(build(attributes: ["k": "v\u{0}"])), .invalidAttribute(key: "k"))
        XCTAssertEqual(rejection(build(attributes: ["k\u{0}": "v"])), .invalidAttribute(key: "k\u{0}"))

        let json = try payload(build(context: FeedbackContext(deviceId: "d\u{0}1", userId: "u", screen: "Home\u{0}Tab")))
        XCTAssertNil(json["device_id"], "an id holding U+0000 is left out, not altered")
        XCTAssertEqual((json["context"] as? [String: String])?["screen"], "HomeTab")
        XCTAssertFalse(String(decoding: try build().get().payload, as: UTF8.self).contains("\\u0000"))
    }

    func testTheDiagnosticNameNeverCarriesTheAttributeKey() {
        XCTAssertEqual(SheepitFeedbackRejection.invalidAttribute(key: "private_field").diagnosticName, "invalid_attribute")
        XCTAssertEqual(SheepitFeedbackRejection.server(statusCode: 400, code: "X").diagnosticName, "server")
    }

    // MARK: - Attributes

    func testAttributeRulesMirrorTheServer() throws {
        var many: [String: SheepitFeedbackAttributeValue] = [:]
        for index in 0..<21 { many["k\(index)"] = .int(index) }
        XCTAssertEqual(rejection(build(attributes: many)), .tooManyAttributes)
        for key in ["bad key", "", String(repeating: "k", count: 65), "__proto__", "constructor", "project_id", "organizationId", "tenant_id"] {
            XCTAssertEqual(rejection(build(attributes: [key: true])), .invalidAttribute(key: key), key)
        }
        XCTAssertEqual(rejection(build(attributes: ["s": .string(String(repeating: "x", count: 257))])), .invalidAttribute(key: "s"))
        XCTAssertEqual(rejection(build(attributes: ["d": .double(.infinity)])), .invalidAttribute(key: "d"))
        XCTAssertEqual(rejection(build(attributes: ["d": .double(.nan)])), .invalidAttribute(key: "d"))

        let attributes = try XCTUnwrap(try payload(build(attributes: [
            "plan": "pro", "seats": 3, "ratio": 0.5, "beta": true, "a.b-c_d": .string(String(repeating: "x", count: 256)),
        ]))["attributes"] as? [String: Any])
        XCTAssertEqual(attributes["plan"] as? String, "pro")
        XCTAssertEqual(attributes["seats"] as? Int, 3)
        XCTAssertEqual(attributes["ratio"] as? Double, 0.5)
        XCTAssertEqual(attributes["beta"] as? Bool, true)
        XCTAssertEqual((attributes["a.b-c_d"] as? String)?.count, 256)
    }

    // MARK: - Screenshots

    func testScreenshotDataIsJudgedByItsFirstBytes() {
        XCTAssertEqual(SheepitFeedbackScreenshot(data: FeedbackImages.png())?.format, .png)
        XCTAssertEqual(SheepitFeedbackScreenshot(data: FeedbackImages.jpeg())?.format, .jpeg)
        XCTAssertNil(SheepitFeedbackScreenshot(data: Data("GIF89a....".utf8)))
        XCTAssertNil(SheepitFeedbackScreenshot(data: Data()))
    }

    func testScreenshotCountSizeAndDimensionCaps() throws {
        let png = try XCTUnwrap(SheepitFeedbackScreenshot(data: FeedbackImages.png()))
        XCTAssertEqual(rejection(build(screenshots: [png, png, png, png])), .tooManyScreenshots)
        XCTAssertNil(rejection(build(screenshots: [png, png, png])))

        let oversize = try XCTUnwrap(SheepitFeedbackScreenshot(
            data: Data(SheepitFeedbackScreenshot.pngSignature) + Data(count: FeedbackLimits.screenshotMaxBytes)
        ))
        XCTAssertEqual(rejection(build(screenshots: [png, oversize])), .screenshotTooLarge(index: 1))

        let garbage = try XCTUnwrap(SheepitFeedbackScreenshot(data: Data(SheepitFeedbackScreenshot.jpegSignature) + Data("not an image".utf8)))
        XCTAssertEqual(rejection(build(screenshots: [garbage])), .invalidScreenshot(index: 0))

        let wide = try XCTUnwrap(SheepitFeedbackScreenshot(data: FeedbackImages.png(width: 16_385, height: 1)))
        XCTAssertEqual(rejection(build(screenshots: [wide])), .screenshotTooLarge(index: 0))
        let edge = try XCTUnwrap(SheepitFeedbackScreenshot(data: FeedbackImages.png(width: 16_384, height: 1)))
        XCTAssertNil(rejection(build(screenshots: [edge])))
    }

    // MARK: - Payload shape

    func testPayloadCarriesTheContextAndOmitsWhatIsMissing() throws {
        let json = try payload(build())
        XCTAssertEqual(json["type"] as? String, "bug")
        XCTAssertEqual(json["user_id"] as? String, "user-1")
        XCTAssertEqual(json["device_id"] as? String, "device-1")
        XCTAssertEqual(json["session_id"] as? String, "session-1")
        XCTAssertNil(json["email"])
        XCTAssertNil(json["attributes"], "an empty attribute map is left out")
        let context = try XCTUnwrap(json["context"] as? [String: String])
        XCTAssertEqual(context, [
            "app_version": "2.1.0", "build_number": "42", "platform": "ios", "os_version": "18.1",
            "device_model": "iPhone16,2", "locale": "en-US", "screen": "Checkout",
            "sdk_name": "sdk-swift", "sdk_version": "0.8.0",
        ])

        let bare = try payload(build(context: FeedbackContext(
            deviceId: "", sessionId: nil, userId: String(repeating: "u", count: 257), screen: String(repeating: "s", count: 300)
        )))
        XCTAssertNil(bare["device_id"], "empty is left out")
        XCTAssertNil(bare["session_id"])
        XCTAssertNil(bare["user_id"], "an over-long id is left out, never cut into someone else's")
        XCTAssertEqual((bare["context"] as? [String: String])?["screen"]?.count, 128, "descriptive context is cut to 128")
        XCTAssertNil(try payload(build(context: FeedbackContext()))["context"], "an empty context object is left out")
    }

    func testPayloadOver16KiBIsRejected() {
        var attributes: [String: SheepitFeedbackAttributeValue] = [:]
        for index in 0..<20 { attributes["key_\(index)"] = .string(String(repeating: "界", count: 256)) }
        // 5000 × 3 bytes + 20 × 768 bytes of attribute text: within every field cap, over the total.
        XCTAssertEqual(rejection(build(message: String(repeating: "界", count: 5000), attributes: attributes)), .payloadTooLarge)
    }

    // MARK: - Multipart

    func testMultipartBodyBytesAreExact() throws {
        let png = try XCTUnwrap(SheepitFeedbackScreenshot(data: Data(SheepitFeedbackScreenshot.pngSignature) + Data("P".utf8)))
        let jpeg = try XCTUnwrap(SheepitFeedbackScreenshot(data: Data(SheepitFeedbackScreenshot.jpegSignature) + Data("J".utf8)))
        let submission = FeedbackSubmission(payload: Data(#"{"message":"hi"}"#.utf8), screenshots: [png, jpeg])
        let form = MultipartFormData(boundary: "XyZ")
        XCTAssertEqual(form.contentType, "multipart/form-data; boundary=XyZ")

        let head: String = "--XyZ\r\n"
            + "Content-Disposition: form-data; name=\"payload\"\r\n"
            + "Content-Type: application/json\r\n\r\n"
            + "{\"message\":\"hi\"}\r\n"
        let firstFile: String = "--XyZ\r\n"
            + "Content-Disposition: form-data; name=\"screenshot\"; filename=\"screenshot-1.png\"\r\n"
            + "Content-Type: image/png\r\n\r\n"
        let secondFile: String = "\r\n--XyZ\r\n"
            + "Content-Disposition: form-data; name=\"screenshot\"; filename=\"screenshot-2.jpg\"\r\n"
            + "Content-Type: image/jpeg\r\n\r\n"
        var expected = Data(head.utf8)
        expected.append(Data(firstFile.utf8))
        expected.append(png.data)
        expected.append(Data(secondFile.utf8))
        expected.append(jpeg.data)
        expected.append(Data("\r\n--XyZ--\r\n".utf8))
        XCTAssertEqual(form.encode(submission), expected)
    }

    func testABoundaryFoundInTheContentIsNeverUsed() throws {
        let submission = FeedbackSubmission(payload: Data(#"{"message":"--XyZ"}"#.utf8), screenshots: [])
        XCTAssertNil(MultipartFormData(boundary: "XyZ").encode(submission))
        let (body, contentType) = MultipartFormData.encoded(submission)
        let boundary = try XCTUnwrap(contentType.components(separatedBy: "boundary=").last)
        XCTAssertTrue(boundary.hasPrefix("SheepitBoundary-"))
        XCTAssertTrue(body.starts(with: Data("--\(boundary)\r\n".utf8)))
        XCTAssertNotEqual(MultipartFormData.randomBoundary(), MultipartFormData.randomBoundary())
    }

    // MARK: - Image encoding (the core every UIImage / NSImage goes through)

    func testALargeNoisyImageIsShrunkUnder1MiBAnd4096Pixels() throws {
        let data = try XCTUnwrap(FeedbackImageEncoder.jpeg(from: FeedbackImages.cgImage(width: 5000, height: 2500, noise: true)))
        XCTAssertLessThanOrEqual(data.count, FeedbackLimits.screenshotMaxBytes)
        XCTAssertTrue(data.starts(with: SheepitFeedbackScreenshot.jpegSignature))
        let size = try XCTUnwrap(FeedbackImageEncoder.pixelSize(of: data))
        XCTAssertLessThanOrEqual(max(size.width, size.height), FeedbackImageEncoder.maxLongSide)
        XCTAssertEqual(Double(size.width) / Double(size.height), 2, accuracy: 0.01, "aspect ratio kept")
        XCTAssertEqual(rejection(build(screenshots: [try XCTUnwrap(SheepitFeedbackScreenshot(data: data))])), nil)
    }

    func testASmallTransparentImageEncodesInOnePass() throws {
        let data = try XCTUnwrap(FeedbackImageEncoder.jpeg(from: FeedbackImages.cgImage(width: 10, height: 20, alpha: true)))
        let size = try XCTUnwrap(FeedbackImageEncoder.pixelSize(of: data))
        XCTAssertEqual(size.width, 10)
        XCTAssertEqual(size.height, 20)
    }

    func testAnImpossibleBudgetGivesNilInsteadOfLooping() {
        XCTAssertNil(FeedbackImageEncoder.jpeg(from: FeedbackImages.cgImage(width: 2000, height: 2000, noise: true), maxBytes: 100))
    }

    #if os(macOS)
    func testNSImageConvenienceProducesAJPEG() throws {
        let image = NSImage(cgImage: FeedbackImages.cgImage(width: 640, height: 480), size: NSSize(width: 640, height: 480))
        let screenshot = try XCTUnwrap(SheepitFeedbackScreenshot(image: image))
        XCTAssertEqual(screenshot.format, .jpeg)
        XCTAssertLessThanOrEqual(screenshot.data.count, FeedbackLimits.screenshotMaxBytes)
    }
    #endif
}
