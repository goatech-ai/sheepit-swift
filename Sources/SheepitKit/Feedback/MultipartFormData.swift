import Foundation

/// The `multipart/form-data` body of `POST /v1/feedback/sdk` (RFC 7578): one `payload` part typed
/// `application/json`, then one `screenshot` file part per image, in order. Hand-written because
/// Foundation has no encoder; the exact bytes are pinned by `FeedbackMultipartTests`.
struct MultipartFormData {
    let boundary: String

    /// A random boundary. `encode` checks it against the content anyway.
    init(boundary: String = MultipartFormData.randomBoundary()) {
        self.boundary = boundary
    }

    static func randomBoundary() -> String {
        "SheepitBoundary-" + UUID().uuidString
    }

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    /// Nil only when the boundary occurs inside a part, which would end that part early; the
    /// caller then draws a fresh boundary (`encoded(_:)`).
    func encode(_ submission: FeedbackSubmission) -> Data? {
        let delimiter = Data("--\(boundary)".utf8)
        if submission.payload.range(of: delimiter) != nil
            || submission.screenshots.contains(where: { $0.data.range(of: delimiter) != nil }) {
            return nil
        }
        var body = Data()
        func line(_ text: String) { body.append(Data((text + "\r\n").utf8)) }

        line("--\(boundary)")
        line(#"Content-Disposition: form-data; name="payload""#)
        line("Content-Type: application/json")
        line("")
        body.append(submission.payload)
        line("")
        for (index, screenshot) in submission.screenshots.enumerated() {
            line("--\(boundary)")
            line(#"Content-Disposition: form-data; name="screenshot"; filename="screenshot-\#(index + 1).\#(screenshot.fileExtension)""#)
            line("Content-Type: \(screenshot.mimeType)")
            line("")
            body.append(screenshot.data)
            line("")
        }
        line("--\(boundary)--")
        return body
    }

    /// The body and its `Content-Type` under a boundary that occurs nowhere in the content.
    static func encoded(_ submission: FeedbackSubmission) -> (body: Data, contentType: String) {
        while true {
            let form = MultipartFormData()
            if let body = form.encode(submission) { return (body, form.contentType) }
        }
    }
}
