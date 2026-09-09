import Foundation
@testable import SheepitKit

/// Shared fixtures for tests that drive a real `Transport` against a
/// stubbed network. Used by `TransportErrorClassingTests` and
/// `BackgroundFlushTests`.

struct TransportHarness {
    let transport: Transport
    let queue: EventQueue
    let offlineQueue: OfflineQueue
    let diagnostics: DiagnosticBus
    let clock: LastFlushClock
}

/// Build a `Transport` wired to `StubURLProtocol` rather than the network.
/// `retryAttempts: 1` skips `HTTPClient`'s backoff ladder, which would
/// otherwise make 5xx and network-error tests sleep for seconds.
func makeTransportHarness(retryAttempts: Int = 3) -> TransportHarness {
    let config = SheepitConfig(
        apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))",
        apiUrl: "https://stub.invalid",
        retryAttempts: retryAttempts
    )
    let log = Logger(debug: false)
    let queue = EventQueue(maxSize: 100)
    let offlineQueue = OfflineQueue(storage: InMemoryStorage())
    let diagnostics = DiagnosticBus()
    let clock = LastFlushClock()
    return TransportHarness(
        transport: Transport(
            http: HTTPClient(config: config, log: log, urlProtocolClasses: [StubURLProtocol.self]),
            queue: queue,
            offlineQueue: offlineQueue,
            connectivity: ConnectivityMonitor(),
            log: log,
            appVersion: "test",
            diagnostics: diagnostics,
            lastFlushClock: clock
        ),
        queue: queue,
        offlineQueue: offlineQueue,
        diagnostics: diagnostics,
        clock: clock
    )
}

func makeStubEvent(name: String) -> EnrichedEvent {
    EnrichedEvent(
        eventId: UUID().uuidString,
        eventName: name,
        eventProperties: nil,
        deviceId: "device-1",
        anonymousId: "anon-1",
        sessionId: "session-1",
        userId: nil,
        platform: "ios",
        sdkVersion: SDKDefaults.sdkVersion,
        locale: "en_US",
        timezone: "UTC",
        timestamp: ISO8601DateFormatter().string(from: Date())
    )
}

/// Canned responses for `https://stub.invalid`. Injected through
/// `HTTPClient(config:log:urlProtocolClasses:)` — global
/// `URLProtocol.registerClass` does NOT reach a session built from
/// `URLSessionConfiguration.default`, so tests relying on it silently hit
/// the real network and pass for the wrong reason.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Stub {
        case status(Int, body: String, headers: [String: String] = [:])
        case failure(Error)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var _stub: Stub = .status(200, body: "{}")
    nonisolated(unsafe) private static var _requestCount = 0

    static var stub: Stub {
        get { lock.lock(); defer { lock.unlock() }; return _stub }
        set { lock.lock(); _stub = newValue; lock.unlock() }
    }

    static var requestCount: Int {
        lock.lock(); defer { lock.unlock() }; return _requestCount
    }

    static func reset() {
        lock.lock()
        _stub = .status(200, body: "{}")
        _requestCount = 0
        lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "stub.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        StubURLProtocol.lock.lock()
        StubURLProtocol._requestCount += 1
        let stub = StubURLProtocol._stub
        StubURLProtocol.lock.unlock()

        switch stub {
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        case .status(let code, let body, let headers):
            guard let url = request.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: code,
                      httpVersion: "HTTP/1.1",
                      headerFields: headers
                  ) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
