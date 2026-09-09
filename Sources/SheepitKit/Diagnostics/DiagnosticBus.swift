import Foundation

/// In-process diagnostics channel: a bounded ring buffer of structured
/// SDK events plus a fan-out to subscribers. Port of
/// `packages/sdk-js/src/diagnostic-bus.ts` + `diagnostics.ts`.
///
/// Host apps use it to see what the SDK is doing without turning on
/// `debug` logging — `sdk.getRecentDiagnostics()` for the buffer,
/// `sdk.diagnostics().subscribe { ... }` (or `SheepitConfig.onDiagnostic`)
/// for a live feed.

// MARK: - Event model

public enum DiagnosticSeverity: String, Sendable, Codable, CaseIterable {
    case debug
    case info
    case warn
    case error

    /// Ordering used by `SubscribeOptions.minSeverity`.
    var rank: Int {
        switch self {
        case .debug: return 0
        case .info: return 1
        case .warn: return 2
        case .error: return 3
        }
    }
}

public enum DiagnosticCategory: String, Sendable, Codable, CaseIterable {
    case transport
    case config
    case identity
    case lifecycle
    case flag
    case experiment
    case connectivity
}

public struct DiagnosticEvent: Sendable {
    public let timestamp: Date
    public let severity: DiagnosticSeverity
    public let category: DiagnosticCategory
    /// Machine-readable code, e.g. `"transport.flush_failed"`.
    public let code: String
    /// Human-readable description.
    public let message: String
    /// Structured payload.
    public let data: [String: AnyCodable]?
    /// Correlates with the API-side `X-Request-ID`.
    public let requestId: String?

    public init(
        timestamp: Date = Date(),
        severity: DiagnosticSeverity,
        category: DiagnosticCategory,
        code: String,
        message: String,
        data: [String: AnyCodable]? = nil,
        requestId: String? = nil
    ) {
        self.timestamp = timestamp
        self.severity = severity
        self.category = category
        self.code = code
        self.message = message
        self.data = data
        self.requestId = requestId
    }
}

public typealias DiagnosticListener = @Sendable (DiagnosticEvent) -> Void

public struct SubscribeOptions: Sendable {
    /// Only receive events at or above this severity. Default `.debug` (all).
    public var minSeverity: DiagnosticSeverity
    /// Only receive events in these categories. `nil` = all.
    public var categories: [DiagnosticCategory]?

    public init(minSeverity: DiagnosticSeverity = .debug, categories: [DiagnosticCategory]? = nil) {
        self.minSeverity = minSeverity
        self.categories = categories
    }
}

// MARK: - Bus

public final class DiagnosticBus: @unchecked Sendable {
    public static let defaultBufferSize = 100
    public static let maxBufferSize = 10_000
    public static let maxSubscribers = 100

    private struct Subscription {
        let id: UInt64
        let fn: DiagnosticListener
        let minRank: Int
        let categories: [DiagnosticCategory]?
    }

    /// One lock guards buffer + listeners. `emit` is called from the
    /// flush task, the connectivity monitor, and the lifecycle observer,
    /// so this type must be safe from any thread.
    private let lock = NSLock()
    private var buffer: [DiagnosticEvent?]
    private let maxSize: Int
    private var writeIndex = 0
    private var count = 0
    private var counts: [DiagnosticSeverity: Int] = [:]
    private var subscriptions: [Subscription] = []
    private var nextSubscriptionId: UInt64 = 0

    public init(bufferSize: Int = DiagnosticBus.defaultBufferSize) {
        self.maxSize = min(DiagnosticBus.maxBufferSize, max(1, bufferSize))
        self.buffer = Array(repeating: nil, count: self.maxSize)
    }

    /// Record an event and fan it out. A throwing/crashing subscriber
    /// cannot be caught in Swift, so subscribers are invoked outside the
    /// lock to keep a slow one from deadlocking a concurrent `emit`.
    ///
    /// Deliberately NOT public: a host app that could emit would be able
    /// to inject events indistinguishable from SDK-authored ones, and a
    /// subscriber has no way to tell a real `transport.flush_failed` from
    /// a forged one. Narrowed before the first tag, while it is still
    /// free to do so.
    func emit(_ event: DiagnosticEvent) {
        lock.lock()
        buffer[writeIndex] = event
        writeIndex = (writeIndex + 1) % maxSize
        if count < maxSize { count += 1 }
        counts[event.severity, default: 0] += 1
        let targets = subscriptions.filter { sub in
            guard event.severity.rank >= sub.minRank else { return false }
            guard let categories = sub.categories else { return true }
            return categories.contains(event.category)
        }
        lock.unlock()

        for sub in targets { sub.fn(event) }
    }

    /// Convenience emitter used by the SDK internals.
    func emit(
        _ severity: DiagnosticSeverity,
        _ category: DiagnosticCategory,
        code: String,
        message: String,
        data: [String: AnyCodable]? = nil,
        requestId: String? = nil
    ) {
        emit(DiagnosticEvent(
            severity: severity,
            category: category,
            code: code,
            message: message,
            data: data,
            requestId: requestId
        ))
    }

    /// Subscribe to the live feed. Returns a cancel closure; dropping it
    /// without calling leaves the subscription active.
    @discardableResult
    public func subscribe(
        _ fn: @escaping DiagnosticListener,
        options: SubscribeOptions = .init()
    ) -> @Sendable () -> Void {
        lock.lock()
        guard subscriptions.count < DiagnosticBus.maxSubscribers else {
            lock.unlock()
            return {}
        }
        let id = nextSubscriptionId
        nextSubscriptionId += 1
        subscriptions.append(Subscription(
            id: id,
            fn: fn,
            minRank: options.minSeverity.rank,
            categories: options.categories
        ))
        lock.unlock()

        return { [weak self] in
            guard let self else { return }
            self.lock.lock()
            self.subscriptions.removeAll { $0.id == id }
            self.lock.unlock()
        }
    }

    /// The buffered events, oldest first.
    public func getRecentDiagnostics() -> [DiagnosticEvent] {
        lock.lock()
        defer { lock.unlock() }
        guard count > 0 else { return [] }
        if count < maxSize {
            return buffer[0..<count].compactMap { $0 }
        }
        // Ring buffer is full — splice at the write head for chronological order.
        return (buffer[writeIndex...] + buffer[..<writeIndex]).compactMap { $0 }
    }

    /// Lifetime event counts per severity (not capped by the buffer).
    public func getCounts() -> [DiagnosticSeverity: Int] {
        lock.lock()
        defer { lock.unlock() }
        var result: [DiagnosticSeverity: Int] = [:]
        for severity in DiagnosticSeverity.allCases {
            result[severity] = counts[severity] ?? 0
        }
        return result
    }
}
