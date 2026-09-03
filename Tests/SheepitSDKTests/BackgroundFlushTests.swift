import XCTest
@testable import SheepitSDK

/// Before `AppLifecycleObserver` existed, the periodic flush task simply
/// stopped being scheduled when the app suspended, so everything queued
/// since the last tick was lost when the process was later killed.
///
/// Coverage boundary: the package's tests run on macOS, where the
/// `#if canImport(UIKit)` NOTIFICATION REGISTRATION is compiled out — so
/// nothing here proves `didEnterBackgroundNotification` fires on a real
/// device; that needs an Xcode run. What IS covered:
///
///   - the observer's background action really drains the transport;
///   - the `beginTask`/`endTask` pairing, through the
///     `BackgroundTaskHost` seam, including the expiration race and
///     double-end — see `BackgroundTaskPairingTests` below;
///   - that the UIKit branch compiles, via `scripts/typecheck-ios.sh`.
final class BackgroundFlushTests: XCTestCase {
    func testBackgroundFlushDrainsTheQueue() async {
        StubURLProtocol.reset()
        StubURLProtocol.stub = .status(200, body: #"{"data":{"accepted":1}}"#)
        defer { StubURLProtocol.reset() }

        let harness = makeTransportHarness()
        harness.queue.add(makeStubEvent(name: "queued_before_background"))
        XCTAssertEqual(harness.queue.size(), 1)

        let observer = AppLifecycleObserver(
            log: GTLogger(debug: false),
            diagnostics: harness.diagnostics,
            onBackground: { [transport = harness.transport] in await transport.flush() }
        )

        await observer.performBackgroundFlush()

        XCTAssertEqual(harness.queue.size(), 0, "backgrounding must drain the in-memory queue")
        XCTAssertEqual(harness.offlineQueue.size(), 0)
        XCTAssertNotNil(harness.clock.date, "a successful background flush records lastFlushAt")
        XCTAssertEqual(StubURLProtocol.requestCount, 1)
    }

    func testBackgroundFlushEmitsLifecycleDiagnostics() async {
        StubURLProtocol.reset()
        StubURLProtocol.stub = .status(200, body: #"{"data":{"accepted":0}}"#)
        defer { StubURLProtocol.reset() }

        let bus = DiagnosticBus()
        let observer = AppLifecycleObserver(
            log: GTLogger(debug: false),
            diagnostics: bus,
            onBackground: {}
        )

        await observer.performBackgroundFlush()

        let codes = bus.getRecentDiagnostics().map(\.code)
        XCTAssertEqual(
            codes,
            ["lifecycle.did_enter_background", "lifecycle.background_flush_complete"]
        )
    }

    func testUnsentEventsSurviveABackgroundFlushFailure() async {
        StubURLProtocol.reset()
        StubURLProtocol.stub = .failure(URLError(.networkConnectionLost))
        defer { StubURLProtocol.reset() }

        let harness = makeTransportHarness(retryAttempts: 1)
        harness.queue.add(makeStubEvent(name: "e"))

        let observer = AppLifecycleObserver(
            log: GTLogger(debug: false),
            diagnostics: harness.diagnostics,
            onBackground: { [transport = harness.transport] in await transport.flush() }
        )
        await observer.performBackgroundFlush()

        XCTAssertEqual(
            harness.offlineQueue.size(),
            1,
            "a failed background flush must persist, not silently drop"
        )
    }

    func testRegisterAndDestroyAreSafeToCallRepeatedly() {
        let observer = AppLifecycleObserver(
            log: GTLogger(debug: false),
            diagnostics: nil,
            onBackground: {}
        )
        observer.register()
        observer.register()
        observer.destroy()
        observer.destroy()
    }
}

/// The begin/end pairing is what gets an app killed when it leaks and
/// traps when it double-ends. Before the `BackgroundTaskHost` seam
/// existed the only automated check on it was "it compiles".
final class BackgroundTaskPairingTests: XCTestCase {
    func testWindowIsTakenSynchronouslyBeforeAnySuspension() {
        // On the iOS 16 floor there is no `MainActor.assumeIsolated`, so an
        // actor hop here would hand control back to UIKit and let the app
        // suspend before the window was ever requested — skipping the flush
        // entirely. beginBackgroundWindow() must be callable synchronously.
        let host = FakeBackgroundTaskHost()
        let observer = makeObserver(host: host, onBackground: {})

        let token = observer.beginBackgroundWindow()

        XCTAssertEqual(host.begun, ["ai.goatech.sdk.background-flush"])
        XCTAssertTrue(token.isActive)
        token.end()
        XCTAssertTrue(host.isBalanced)
    }

    func testWindowIsTakenAndAlwaysGivenBack() async {
        let host = FakeBackgroundTaskHost()
        let observer = makeObserver(host: host, onBackground: {})

        await observer.runBackgroundFlushInTask()

        XCTAssertEqual(host.begun, ["ai.goatech.sdk.background-flush"])
        XCTAssertEqual(host.ended.count, 1, "the window must be handed back exactly once")
        XCTAssertTrue(host.isBalanced, "a leaked background task gets the app killed")
    }

    func testExpirationBeforeCompletionEndsExactlyOnce() async {
        let host = FakeBackgroundTaskHost()
        // The system reclaims the window mid-flush.
        let observer = makeObserver(host: host, onBackground: {
            host.fireExpiration()
        })

        await observer.runBackgroundFlushInTask()

        XCTAssertEqual(
            host.ended.count,
            1,
            "expiration then completion must not end the same task twice"
        )
        XCTAssertTrue(host.isBalanced)
    }

    func testDoubleExpirationEndsExactlyOnce() async {
        let host = FakeBackgroundTaskHost()
        let observer = makeObserver(host: host, onBackground: {
            host.fireExpiration()
            host.fireExpiration()
        })

        await observer.runBackgroundFlushInTask()

        XCTAssertEqual(host.ended.count, 1)
    }

    func testFlushStillRunsWhenTheSystemRefusesAWindow() async {
        // beginTask returning nil is the "already suspended / over budget"
        // case; losing the events there would be worse than a late flush.
        let host = FakeBackgroundTaskHost(grantsWindow: false)
        let flushed = FlagBox()
        let observer = makeObserver(host: host, onBackground: {
            flushed.value = true
        })

        await observer.runBackgroundFlushInTask()

        XCTAssertTrue(flushed.value, "a refused window must not skip the flush")
        XCTAssertTrue(host.ended.isEmpty, "nothing was granted, so nothing to end")
    }

    func testMacOSDefaultHostGrantsNothingButStillFlushes() async {
        // The production default on a platform without the API.
        let flushed = FlagBox()
        let observer = AppLifecycleObserver(
            log: GTLogger(debug: false),
            diagnostics: nil,
            backgroundTaskHost: { NoBackgroundTaskHost() },
            onBackground: { flushed.value = true }
        )

        await observer.runBackgroundFlushInTask()
        XCTAssertTrue(flushed.value)
    }

    private func makeObserver(
        host: BackgroundTaskHost,
        onBackground: @escaping @Sendable () async -> Void
    ) -> AppLifecycleObserver {
        AppLifecycleObserver(
            log: GTLogger(debug: false),
            diagnostics: nil,
            backgroundTaskHost: { host },
            onBackground: onBackground
        )
    }
}

private final class FakeBackgroundTaskHost: BackgroundTaskHost, @unchecked Sendable {
    private(set) var begun: [String] = []
    private(set) var ended: [UInt64] = []
    private var expirationHandler: (() -> Void)?
    private var nextToken: UInt64 = 1
    private let grantsWindow: Bool

    init(grantsWindow: Bool = true) {
        self.grantsWindow = grantsWindow
    }

    /// Every granted window was handed back.
    var isBalanced: Bool { begun.count == ended.count }

    func beginTask(name: String, expirationHandler: @escaping () -> Void) -> UInt64? {
        guard grantsWindow else { return nil }
        begun.append(name)
        self.expirationHandler = expirationHandler
        defer { nextToken += 1 }
        return nextToken
    }

    func endTask(_ token: UInt64) {
        ended.append(token)
    }

    /// Simulate the system reclaiming the window.
    func fireExpiration() {
        expirationHandler?()
    }
}

private final class FlagBox: @unchecked Sendable {
    var value = false
}
