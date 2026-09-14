import Network
import XCTest
@testable import SheepitKit

/// `/v1/config` must never be answered from the URL cache (S3d).
///
/// A resolved config 200 carries `Cache-Control: private, max-age=60, stale-while-revalidate=300`,
/// and `HTTPClient`'s session is `URLSessionConfiguration.default`, so it has the shared
/// `URLCache`. Measured with a loopback server: a second default-policy GET within 60 s was served
/// from the cache without reaching the server. That would let the unconditional refetch after
/// `identify()` return the previous row's body and label it with the new user.
///
/// A real socket, not a `URLProtocol` stub: a stub protocol decides for itself whether to use a
/// cached response, so it cannot show what the cache does to a real request.
final class ConfigCacheBypassTests: XCTestCase {
    private static let body = #"{"data":{"config_version":"7","etag":"\"v7\"","flags":{},"experiments":{}}}"#

    func testEveryConfigRequestReachesTheNetworkDespiteCacheableHeaders() async throws {
        let server = try LoopbackConfigServer(body: Self.body)
        let port = try await server.start()
        defer { server.stop() }
        let sync = ConfigSync(
            http: HTTPClient(
                config: SheepitConfig(
                    apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64),
                    apiUrl: "http://127.0.0.1:\(port)",
                    retryAttempts: 1),
                log: Logger(debug: false)),
            storage: InMemoryStorage(),
            refreshInterval: 3600,
            log: Logger(debug: false),
            identityProvider: { (.fetchedUnder("user-a"), 0) },
            onConfig: { _, _ in }
        )

        await sync.refetchUnconditionally(deviceId: "device-1")
        await sync.refetchUnconditionally(deviceId: "device-1")

        XCTAssertEqual(server.requestCount, 2,
                       "a config request answered from the URL cache can carry the previous row's body")
    }
}

/// A one-response-per-connection HTTP server on 127.0.0.1 that answers every request with a
/// cacheable `/v1/config`-shaped 200, and counts the requests that actually arrive.
final class LoopbackConfigServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "sheepit.tests.loopback-config")
    private let body: String
    private let lock = NSLock()
    private var requests = 0

    init(body: String) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.body = body
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    func start() async throws -> UInt16 {
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        let listener = self.listener
        return try await withCheckedThrowingContinuation { continuation in
            let resumed = LockedBox(false)
            listener.stateUpdateHandler = { state in
                guard !resumed.get() else { return }
                switch state {
                case .ready:
                    resumed.set(true)
                    continuation.resume(returning: listener.port?.rawValue ?? 0)
                case .failed(let error):
                    resumed.set(true)
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.cancel()
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, _, _ in
            guard let self, let data, !data.isEmpty else {
                connection.cancel()
                return
            }
            self.lock.lock()
            self.requests += 1
            self.lock.unlock()
            let payload = Data(self.body.utf8)
            let head = "HTTP/1.1 200 OK\r\n"
                + "Content-Type: application/json\r\n"
                + "Cache-Control: private, max-age=60, stale-while-revalidate=300\r\n"
                + "Vary: Authorization, X-Environment, X-Device-ID\r\n"
                + "ETag: \"v7\"\r\n"
                + "Content-Length: \(payload.count)\r\n"
                + "Connection: close\r\n\r\n"
            connection.send(content: Data(head.utf8) + payload, completion: .contentProcessed { _ in
                connection.cancel()
            })
        }
    }
}
