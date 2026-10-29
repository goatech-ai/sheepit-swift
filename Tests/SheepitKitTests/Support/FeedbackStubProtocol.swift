import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import SheepitKit

/// Canned responses for `https://feedback.invalid`, its own host so no other suite's stub or late
/// teardown flush can answer (or record) a feedback request. `POST /v1/feedback/sdk` pops the next
/// scripted response (201 with id `fb-<n>` when none is left); every other path answers 200 `{}`.
final class FeedbackStubProtocol: URLProtocol, @unchecked Sendable {
    enum Response {
        case status(Int, body: String = "{}", headers: [String: String] = [:])
        case failure(Error)
    }

    struct Recorded {
        let headers: [String: String]
        let body: Data
    }

    static let host = "feedback.invalid"
    static let apiUrl = "https://\(host)"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var script: [Response] = []
    nonisolated(unsafe) private static var recorded: [Recorded] = []
    nonisolated(unsafe) private static var _responseDelay: TimeInterval = 0
    nonisolated(unsafe) private static var inFlight = 0
    nonisolated(unsafe) private static var _maxInFlight = 0

    static func reset() {
        lock.lock(); script = []; recorded = []; _responseDelay = 0; inFlight = 0; _maxInFlight = 0; lock.unlock()
    }

    /// Feedback responses are held this long, so overlapping requests would overlap here.
    static var responseDelay: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return _responseDelay }
        set { lock.lock(); _responseDelay = newValue; lock.unlock() }
    }

    /// The most feedback requests ever open at once since `reset()`.
    static var maxInFlight: Int {
        lock.lock(); defer { lock.unlock() }; return _maxInFlight
    }

    static func enqueue(_ responses: Response...) {
        lock.lock(); script.append(contentsOf: responses); lock.unlock()
    }

    static var feedbackRequests: [Recorded] {
        lock.lock(); defer { lock.unlock() }; return recorded
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == host }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        let response: Response
        var delay: TimeInterval = 0
        if url.path == SDKEndpoints.feedbackSubmit {
            Self.lock.lock()
            Self.inFlight += 1
            Self._maxInFlight = max(Self._maxInFlight, Self.inFlight)
            delay = Self._responseDelay
            Self.recorded.append(Recorded(headers: request.allHTTPHeaderFields ?? [:], body: Self.body(of: request)))
            let count = Self.recorded.count
            response = Self.script.isEmpty
                ? .status(201, body: #"{"data":{"id":"fb-\#(count)","createdAt":"2026-10-28T00:00:00.000Z","attachments":[]}}"#)
                : Self.script.removeFirst()
            Self.lock.unlock()
        } else {
            response = .status(200)
        }
        let isFeedback = url.path == SDKEndpoints.feedbackSubmit
        DispatchQueue.global().asyncAfter(deadline: .now() + delay) { [self] in
            if isFeedback {
                Self.lock.lock(); Self.inFlight -= 1; Self.lock.unlock()
            }
            respond(response, url: url)
        }
    }

    private func respond(_ response: Response, url: URL) {
        switch response {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .status(let code, let body, let headers):
            guard let http = HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: headers) else { return }
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        var data = Data()
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

/// The `payload` part's JSON object out of a recorded multipart body.
func feedbackPayload(in body: Data) throws -> [String: Any] {
    let marker = Data(#"name="payload""#.utf8)
    let start = try XCTUnwrap(body.range(of: marker), "no payload part")
    let headerEnd = try XCTUnwrap(body.range(of: Data("\r\n\r\n".utf8), in: start.upperBound..<body.endIndex))
    let partEnd = try XCTUnwrap(body.range(of: Data("\r\n--".utf8), in: headerEnd.upperBound..<body.endIndex))
    let json = body.subdata(in: headerEnd.upperBound..<partEnd.lowerBound)
    return try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
}

func makeTempDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(
        "sheepit-feedback-tests-\(UUID().uuidString)", isDirectory: true
    )
}

/// A one-pixel PNG / JPEG, produced by ImageIO so the dimension check can read them.
enum FeedbackImages {
    static func png(width: Int = 1, height: Int = 1) -> Data { encode(width: width, height: height, type: "public.png") }
    static func jpeg(width: Int = 1, height: Int = 1) -> Data { encode(width: width, height: height, type: "public.jpeg") }

    static func cgImage(width: Int, height: Int, noise: Bool = false, alpha: Bool = false) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: (alpha ? CGImageAlphaInfo.premultipliedLast : CGImageAlphaInfo.noneSkipLast).rawValue
        )!
        if noise, let pixels = context.data?.bindMemory(to: UInt32.self, capacity: width * height) {
            var seed: UInt32 = 0x1234_5678
            for index in 0..<(width * height) {
                seed = seed &* 1_664_525 &+ 1_013_904_223
                pixels[index] = seed | 0xFF00_0000
            }
        } else if !alpha {
            context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return context.makeImage()!
    }

    private static func encode(width: Int, height: Int, type: String) -> Data {
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output as CFMutableData, type as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cgImage(width: width, height: height), nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }
}
