import XCTest
@testable import SheepitSDK

/// Port of `packages/sdk-js/src/__tests__/diagnostic-bus.test.ts`.
final class DiagnosticBusTests: XCTestCase {
    func testEmitAndReadBack() {
        let bus = DiagnosticBus()
        bus.emit(.warn, .transport, code: "transport.flush_failed", message: "nope")

        let recent = bus.getRecentDiagnostics()
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent[0].code, "transport.flush_failed")
        XCTAssertEqual(recent[0].severity, .warn)
        XCTAssertEqual(recent[0].category, .transport)
    }

    func testEmptyBufferReturnsEmptyArray() {
        XCTAssertTrue(DiagnosticBus().getRecentDiagnostics().isEmpty)
    }

    // MARK: - Bounds

    func testBufferIsBoundedAndKeepsTheNewest() {
        let bus = DiagnosticBus(bufferSize: 3)
        for index in 1...10 {
            bus.emit(.debug, .config, code: "c\(index)", message: "m")
        }

        let recent = bus.getRecentDiagnostics()
        XCTAssertEqual(recent.count, 3, "buffer must never exceed its bound")
        XCTAssertEqual(recent.map(\.code), ["c8", "c9", "c10"], "and must stay chronological")
    }

    func testBufferSizeIsClamped() {
        XCTAssertEqual(DiagnosticBus(bufferSize: 0).emitAndCount(5), 1, "0 clamps to 1")
        XCTAssertEqual(
            DiagnosticBus(bufferSize: DiagnosticBus.maxBufferSize + 5_000).emitAndCount(3),
            3,
            "over-large sizes clamp without dropping anything under the cap"
        )
        XCTAssertEqual(DiagnosticBus(bufferSize: -10).emitAndCount(4), 1, "negative clamps to 1")
    }

    func testPartiallyFilledBufferIsChronological() {
        let bus = DiagnosticBus(bufferSize: 5)
        for index in 1...3 { bus.emit(.debug, .config, code: "c\(index)", message: "m") }
        XCTAssertEqual(bus.getRecentDiagnostics().map(\.code), ["c1", "c2", "c3"])
    }

    func testCountsTrackLifetimeTotalsNotBufferContents() {
        let bus = DiagnosticBus(bufferSize: 2)
        for _ in 0..<5 { bus.emit(.error, .transport, code: "e", message: "m") }
        bus.emit(.info, .config, code: "i", message: "m")

        XCTAssertEqual(bus.getRecentDiagnostics().count, 2)
        XCTAssertEqual(bus.getCounts()[.error], 5, "counts survive buffer eviction")
        XCTAssertEqual(bus.getCounts()[.info], 1)
        XCTAssertEqual(bus.getCounts()[.warn], 0)
    }

    // MARK: - Subscribers

    func testSubscriberReceivesEvents() {
        let bus = DiagnosticBus()
        let received = Box<[String]>([])
        bus.subscribe { event in received.value.append(event.code) }

        bus.emit(.info, .identity, code: "identity.identified", message: "m")
        XCTAssertEqual(received.value, ["identity.identified"])
    }

    func testUnsubscribeStopsDelivery() {
        let bus = DiagnosticBus()
        let received = Box<[String]>([])
        let cancel = bus.subscribe { event in received.value.append(event.code) }

        bus.emit(.info, .config, code: "a", message: "m")
        cancel()
        bus.emit(.info, .config, code: "b", message: "m")

        XCTAssertEqual(received.value, ["a"], "cancelled subscribers stop receiving")
        XCTAssertEqual(bus.getRecentDiagnostics().count, 2, "but the buffer still records both")
    }

    func testMinSeverityFilter() {
        let bus = DiagnosticBus()
        let received = Box<[String]>([])
        bus.subscribe(
            { event in received.value.append(event.code) },
            options: .init(minSeverity: .warn)
        )

        bus.emit(.debug, .config, code: "d", message: "m")
        bus.emit(.info, .config, code: "i", message: "m")
        bus.emit(.warn, .config, code: "w", message: "m")
        bus.emit(.error, .config, code: "e", message: "m")

        XCTAssertEqual(received.value, ["w", "e"])
    }

    func testCategoryFilter() {
        let bus = DiagnosticBus()
        let received = Box<[String]>([])
        bus.subscribe(
            { event in received.value.append(event.code) },
            options: .init(categories: [.transport, .connectivity])
        )

        bus.emit(.info, .transport, code: "t", message: "m")
        bus.emit(.info, .flag, code: "f", message: "m")
        bus.emit(.info, .connectivity, code: "c", message: "m")

        XCTAssertEqual(received.value, ["t", "c"])
    }

    func testSubscriberCapIsEnforced() {
        let bus = DiagnosticBus()
        let received = Box<Int>(0)
        for _ in 0..<DiagnosticBus.maxSubscribers {
            bus.subscribe { _ in received.value += 1 }
        }
        // Over the cap: subscribe returns a no-op cancel and does not attach.
        bus.subscribe { _ in received.value += 1 }

        bus.emit(.info, .config, code: "c", message: "m")
        XCTAssertEqual(received.value, DiagnosticBus.maxSubscribers)
    }

    func testConcurrentEmitsDoNotExceedTheBound() {
        let bus = DiagnosticBus(bufferSize: 50)
        DispatchQueue.concurrentPerform(iterations: 500) { index in
            bus.emit(.debug, .transport, code: "c\(index)", message: "m")
        }
        XCTAssertEqual(bus.getRecentDiagnostics().count, 50)
        XCTAssertEqual(bus.getCounts()[.debug], 500)
    }

    // MARK: - Config wiring

    func testConfigOnDiagnosticIsWiredAtInit() {
        let received = Box<[String]>([])
        let config = SheepitConfig(
            apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))",
            onDiagnostic: { event in received.value.append(event.code) }
        )
        let bus = DiagnosticBus(bufferSize: config.diagnosticBufferSize)
        if let onDiagnostic = config.onDiagnostic { bus.subscribe(onDiagnostic) }

        bus.emit(.info, .config, code: "config.applied", message: "m")
        XCTAssertEqual(received.value, ["config.applied"])
    }
}

/// Reference box so the closures above can mutate captured state.
private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

private extension DiagnosticBus {
    /// Emit `n` events and return how many the buffer retained.
    func emitAndCount(_ n: Int) -> Int {
        for index in 0..<n { emit(.debug, .config, code: "c\(index)", message: "m") }
        return getRecentDiagnostics().count
    }
}
