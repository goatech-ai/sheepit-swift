import Foundation
@testable import SheepitKit

/// Test doubles shared by the attribution and config reset suites.

/// In-memory storage that runs a hook the first time a key is read, before the read returns.
final class ReadHookStorage: StorageProvider, @unchecked Sendable {
    private let inner = InMemoryStorage()
    private let lock = NSLock()
    private var hooks: [String: @Sendable () -> Void] = [:]

    func onFirstRead(of key: String, _ hook: @escaping @Sendable () -> Void) {
        lock.lock()
        hooks[key] = hook
        lock.unlock()
    }

    func string(forKey key: String) -> String? { inner.string(forKey: key) }
    func set(_ value: String?, forKey key: String) { inner.set(value, forKey: key) }
    func set(_ value: Data?, forKey key: String) { inner.set(value, forKey: key) }
    func removeObject(forKey key: String) { inner.removeObject(forKey: key) }

    func data(forKey key: String) -> Data? {
        lock.lock()
        let hook = hooks.removeValue(forKey: key)
        lock.unlock()
        hook?()
        return inner.data(forKey: key)
    }
}

final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
    func set(_ newValue: Value) { lock.lock(); value = newValue; lock.unlock() }
    func mutate(_ body: (inout Value) -> Void) { lock.lock(); body(&value); lock.unlock() }
}

/// A scripted stand-in for the API on `https://stub.invalid`:
///   - `/v1/config`: 500 for the next `failNextConfigRequests` requests, else 304 until `serveConfig` is called; then the body, or 304 when the request's
///     `If-None-Match` equals the body's ETag (`honorIfNoneMatch`), which is what the real route
///     does after `identify()`. `scriptConfig` answers requests in order with per-request delays.
///   - `/v1/devices/register`: the minted `registerDeviceId`, or `{}` (unreadable) when unset;
///     held until `releaseHeldRegister()` while `holdRegister` is set.
///   - `/v1/devices/:id/identify`: the reply set for that user — a status, a lost response, or
///     held until `releaseHeldIdentify()` — and 200 otherwise. Keyed by user, so a retry of the
///     same request gets the same answer.
///   - `/v1/ingest`: a 202 that accounts for every event; bodies are recorded.
///   - anything else: 200 `{}`.
final class AttributionCaptureProtocol: URLProtocol, @unchecked Sendable {
    enum IdentifyReply {
        case status(Int)
        case lost
        case hold
        /// 400 when the request carries `attributes`, `otherwise` when it carries none.
        case rejectAttributes(otherwise: Int)
    }

    private struct State {
        var ingestBodies: [Data] = []
        var configRequests = 0
        var configIfNoneMatch: [String?] = []
        var configResponse: String?
        var configScript: [(String, TimeInterval)] = []
        var configHook: (@Sendable () -> Void)?
        var honorIfNoneMatch = true
        var identifyReplies: [String: IdentifyReply] = [:]
        var heldIdentify: [(Int) -> Void] = []
        var identifyUserIds: [String] = []
        var registerDeviceId: String?
        var failConfigRequests = 0
        var holdRegister = false
        var heldRegister: [() -> Void] = []
        var registerRequests = 0
        var identifyAttributes: [[String: Any]?] = []
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var state = State()

    private static func with<T>(_ body: (inout State) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        return body(&state)
    }

    static func reset() { with { $0 = State() } }
    static func serveConfig(_ body: String) { with { $0.configResponse = body } }
    static func scriptConfig(_ script: [(String, TimeInterval)]) { with { $0.configScript = script } }
    static func failNextConfigRequests(_ count: Int) { with { $0.failConfigRequests = count } }
    static func setIdentifyReply(_ reply: IdentifyReply, for userId: String) {
        with { $0.identifyReplies[userId] = reply }
    }

    static var onConfigRequest: (@Sendable () -> Void)? {
        get { with { $0.configHook } }
        set { with { $0.configHook = newValue } }
    }
    static var honorIfNoneMatch: Bool {
        get { with { $0.honorIfNoneMatch } }
        set { with { $0.honorIfNoneMatch = newValue } }
    }
    static var registerDeviceId: String? {
        get { with { $0.registerDeviceId } }
        set { with { $0.registerDeviceId = newValue } }
    }
    static var configRequestCount: Int { with { $0.configRequests } }
    static var configIfNoneMatch: [String?] { with { $0.configIfNoneMatch } }
    static var identifyUserIds: [String] { with { $0.identifyUserIds } }
    /// The `attributes` of each identify request, in order; nil when a request sent none.
    static var identifyAttributes: [[String: Any]?] { with { $0.identifyAttributes } }
    static var registerRequestCount: Int { with { $0.registerRequests } }
    /// While set, `/v1/devices/register` requests are not answered until `releaseHeldRegister()`.
    static var holdRegister: Bool {
        get { with { $0.holdRegister } }
        set { with { $0.holdRegister = newValue } }
    }

    static func releaseHeldRegister() {
        let held = with { state -> [() -> Void] in
            state.holdRegister = false
            defer { state.heldRegister = [] }
            return state.heldRegister
        }
        held.forEach { $0() }
    }

    /// Answers every held identify request with `status`, and every later one for a still-held
    /// user too.
    static func releaseHeldIdentify(status: Int = 200) {
        let held = with { state -> [(Int) -> Void] in
            for (userId, reply) in state.identifyReplies {
                if case .hold = reply { state.identifyReplies[userId] = .status(status) }
            }
            defer { state.heldIdentify = [] }
            return state.heldIdentify
        }
        held.forEach { $0(status) }
    }

    /// The last sent copy of the event with this name, across every captured request.
    static func event(named name: String) -> [String: Any]? {
        with { $0.ingestBodies }.flatMap(batch).last { $0["event"] as? String == name }
    }

    private static func batch(_ body: Data) -> [[String: Any]] {
        let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        return object?["batch"] as? [[String: Any]] ?? []
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "stub.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
        }
        let path = request.url?.path ?? ""
        let ifNoneMatch = request.value(forHTTPHeaderField: "If-None-Match")

        if path.hasSuffix(SDKEndpoints.config) {
            let (reply, delay, hook) = Self.with { state -> ((Int, String), TimeInterval, (@Sendable () -> Void)?) in
                state.configRequests += 1
                state.configIfNoneMatch.append(ifNoneMatch)
                if state.failConfigRequests > 0 {
                    state.failConfigRequests -= 1
                    return ((500, #"{"error":{"code":"INTERNAL","message":"stub"}}"#), 0, state.configHook)
                }
                if !state.configScript.isEmpty {
                    let (scripted, delay) = state.configScript.removeFirst()
                    return ((200, scripted), delay, state.configHook)
                }
                guard let config = state.configResponse else { return ((304, ""), 0, state.configHook) }
                if state.honorIfNoneMatch, let ifNoneMatch,
                   config.contains(#""etag":"\#(ifNoneMatch.replacingOccurrences(of: "\"", with: "\\\""))""#) {
                    return ((304, ""), 0, state.configHook)
                }
                return ((200, config), 0, state.configHook)
            }
            hook?()
            if delay > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { self.respond(reply.0, reply.1) }
            } else {
                respond(reply.0, reply.1)
            }
        } else if path.hasSuffix("/v1/devices/register") {
            let answer = {
                if let minted = Self.registerDeviceId {
                    self.respond(201, #"{"data":{"device_id":"\#(minted)","anonymous_id":"anon","flag_assignments":{},"#
                        + #""experiment_assignments":{},"config":{"flush_interval_ms":5000,"flush_size":20}}}"#)
                } else {
                    self.respond(200, "{}")
                }
            }
            let held = Self.with { state -> Bool in
                state.registerRequests += 1
                guard state.holdRegister else { return false }
                state.heldRegister.append(answer)
                return true
            }
            if !held { answer() }
        } else if path.hasSuffix("/identify") {
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
            let userId = json?["user_id"] as? String ?? ""
            let attributes = json?["attributes"] as? [String: Any]
            let reply = Self.with { state -> IdentifyReply in
                state.identifyUserIds.append(userId)
                state.identifyAttributes.append(attributes)
                return state.identifyReplies[userId] ?? .status(200)
            }
            switch reply {
            case .status(let status):
                respond(status, #"{"data":{}}"#)
            case .lost:
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            case .hold:
                Self.with { $0.heldIdentify.append { status in self.respond(status, #"{"data":{}}"#) } }
            case .rejectAttributes(let otherwise):
                if attributes != nil {
                    respond(400, #"{"error":{"code":"INVALID_ATTRIBUTES","message":"stub"}}"#)
                } else {
                    respond(otherwise, #"{"data":{}}"#)
                }
            }
        } else if path.hasSuffix(SDKEndpoints.ingest) {
            let count = Self.batch(body).count
            Self.with { $0.ingestBodies.append(body) }
            respond(202, #"{"data":{"accepted":\#(count)}}"#)
        } else {
            respond(200, "{}")
        }
    }

    private func respond(_ status: Int, _ body: String) {
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
