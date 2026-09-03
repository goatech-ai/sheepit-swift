import Foundation

/// Actor-based HTTP client for SDK API communication.
actor HTTPClient {
    private let session: URLSession
    private let apiKey: String
    private let environment: String
    private let baseURL: URL
    private let retryAttempts: Int
    private let retryBackoff: [TimeInterval]
    private let log: GTLogger

    /// - Parameter urlProtocolClasses: test-only seam. `URLProtocol.registerClass`
    ///   does not reach a session built from `URLSessionConfiguration.default`,
    ///   so stubs have to be threaded in here. Always nil in production.
    init(config: SheepitConfig, log: GTLogger, urlProtocolClasses: [AnyClass]? = nil) {
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForRequest = 30
        sessionConfig.timeoutIntervalForResource = 60
        if let urlProtocolClasses {
            sessionConfig.protocolClasses = urlProtocolClasses + (sessionConfig.protocolClasses ?? [])
        }

        self.session = URLSession(configuration: sessionConfig)
        self.apiKey = config.apiKey
        self.environment = config.environment
        // swiftlint:disable:next force_unwrapping
        self.baseURL = URL(string: config.apiUrl)!
        self.retryAttempts = config.retryAttempts
        self.retryBackoff = SDKDefaults.retryBackoff
        self.log = log
    }

    // MARK: - Public API

    func post<T: Decodable & Sendable>(
        path: String,
        body: some Encodable & Sendable,
        extraHeaders: [String: String] = [:]
    ) async throws -> T {
        let data = try await performRequest("POST", path: path, body: body, extraHeaders: extraHeaders)
        return try JSONDecoder().decode(ApiDataResponse<T>.self, from: data).data
    }

    func postRaw(
        path: String,
        body: some Encodable & Sendable,
        extraHeaders: [String: String] = [:]
    ) async throws -> Data {
        try await performRequest("POST", path: path, body: body, extraHeaders: extraHeaders)
    }

    func get<T: Decodable & Sendable>(
        path: String,
        extraHeaders: [String: String] = [:]
    ) async throws -> T {
        let data = try await performRequest("GET", path: path, body: Optional<Int>.none, extraHeaders: extraHeaders)
        return try JSONDecoder().decode(ApiDataResponse<T>.self, from: data).data
    }

    func getRaw(
        path: String,
        extraHeaders: [String: String] = [:]
    ) async throws -> (Data, HTTPURLResponse) {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        applyHeaders(to: &request, extraHeaders: extraHeaders)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SDKError.invalidResponse
        }
        return (data, httpResponse)
    }

    func patch(
        path: String,
        body: some Encodable & Sendable,
        extraHeaders: [String: String] = [:]
    ) async throws {
        _ = try await performRequest("PATCH", path: path, body: body, extraHeaders: extraHeaders)
    }

    // MARK: - Internal

    private func performRequest(
        _ method: String,
        path: String,
        body: (any Encodable & Sendable)?,
        extraHeaders: [String: String],
        attempt: Int = 0
    ) async throws -> Data {
        let url = baseURL.appendingPathComponent(path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        applyHeaders(to: &request, extraHeaders: extraHeaders)

        if let body {
            request.httpBody = try JSONEncoder().encode(AnyEncodableWrapper(body))
        }

        do {
            let (data, response) = try await session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw SDKError.invalidResponse
            }

            // 400: malformed — drop, don't retry
            if httpResponse.statusCode == 400 {
                let msg = String(data: data, encoding: .utf8) ?? "Bad request"
                throw SDKError.badRequest(msg)
            }

            // 429: rate limited — don't retry automatically. Surface the
            // server's Retry-After (seconds) so the caller can back off
            // for the requested window instead of guessing.
            if httpResponse.statusCode == 429 {
                let retryAfter = Self.parseRetryAfter(
                    httpResponse.value(forHTTPHeaderField: "Retry-After")
                )
                throw SDKError.rateLimited(retryAfter: retryAfter)
            }

            // 5xx: server error — retry
            if httpResponse.statusCode >= 500 {
                throw SDKError.serverError(httpResponse.statusCode)
            }

            // 2xx: success
            if (200...299).contains(httpResponse.statusCode) {
                return data
            }

            throw SDKError.httpError(httpResponse.statusCode)
        } catch let error as SDKError {
            // Only retry on server errors
            if case .serverError = error, attempt < retryAttempts - 1 {
                let delay = retryBackoff[min(attempt, retryBackoff.count - 1)]
                log.debug("Request failed (attempt \(attempt + 1)), retrying in \(delay)s")
                try await Task.sleep(for: .seconds(delay))
                return try await performRequest(method, path: path, body: body, extraHeaders: extraHeaders, attempt: attempt + 1)
            }
            throw error
        } catch {
            // Network errors — retry
            if attempt < retryAttempts - 1 {
                let delay = retryBackoff[min(attempt, retryBackoff.count - 1)]
                log.debug("Network error (attempt \(attempt + 1)), retrying in \(delay)s")
                try await Task.sleep(for: .seconds(delay))
                return try await performRequest(method, path: path, body: body, extraHeaders: extraHeaders, attempt: attempt + 1)
            }
            throw SDKError.networkError(error)
        }
    }

    /// RFC 7231 §7.1.3 allows `Retry-After` in two forms: delay-seconds
    /// ("120") or an HTTP-date ("Wed, 21 Oct 2015 07:28:00 GMT"). Parsing
    /// only the first silently yields nil for the second, so a
    /// date-emitting proxy would collapse to the default back-off.
    static func parseRetryAfter(_ header: String?) -> TimeInterval? {
        guard let header = header?.trimmingCharacters(in: .whitespaces), !header.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(header) {
            return max(0, seconds)
        }
        guard let date = imfFixdateFormatter.date(from: header) else { return nil }
        return max(0, date.timeIntervalSinceNow)
    }

    private func applyHeaders(to request: inout URLRequest, extraHeaders: [String: String]) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(environment, forHTTPHeaderField: "X-Environment")
        for (key, value) in extraHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
    }
}

/// IMF-fixdate parser for `Retry-After`. Fixed locale + zone: the
/// device's own locale must not change how a wire format is read.
private let imfFixdateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter
}()

// MARK: - SDK Errors

public enum SDKError: Error, LocalizedError, Sendable {
    case invalidResponse
    case badRequest(String)
    /// HTTP 429. `retryAfter` is the server's `Retry-After` header in
    /// seconds, when it sent one.
    case rateLimited(retryAfter: TimeInterval?)
    case serverError(Int)
    case httpError(Int)
    case networkError(Error)
    case notInitialized

    public var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Invalid server response"
        case .badRequest(let msg): return "Bad request: \(msg)"
        case .rateLimited(let retryAfter):
            guard let retryAfter else { return "Rate limited" }
            return "Rate limited (retry after \(Int(retryAfter))s)"
        case .serverError(let code): return "Server error (\(code))"
        case .httpError(let code): return "HTTP error (\(code))"
        case .networkError(let err): return "Network error: \(err.localizedDescription)"
        case .notInitialized: return "Sheepit SDK not initialized"
        }
    }
}

// MARK: - Type-erased Encodable

private struct AnyEncodableWrapper: Encodable, @unchecked Sendable {
    private let encode: (Encoder) throws -> Void

    init(_ value: any Encodable) {
        self.encode = { try value.encode(to: $0) }
    }

    func encode(to encoder: Encoder) throws {
        try encode(encoder)
    }
}
