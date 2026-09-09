import XCTest
@testable import SheepitKit

/// The 429 re-queue path added a second concurrent writer to `EventQueue`
/// (the `Transport` actor's executor) alongside the host app's
/// `track()` thread. ThreadSanitizer caught the unguarded `Array`
/// mutation as a `Swift access race` that segfaulted inside
/// `Array.append`; `ConnectivityMonitor.isOnline` raced the same way
/// against `Transport.flush()`'s read.
///
/// Run these under `swift test --sanitize=thread` to exercise the
/// detector — without TSan they still assert that no events are lost or
/// duplicated, which is the user-visible consequence.
final class ConcurrencySafetyTests: XCTestCase {
    func testConcurrentAddAndDrainLosesNoEvents() {
        let queue = EventQueue(maxSize: 10_000)
        let drained = Box<[EnrichedEvent]>([])
        let drainLock = NSLock()
        let total = 2_000

        DispatchQueue.concurrentPerform(iterations: 16) { worker in
            for index in 0..<(total / 16) {
                queue.add(makeStubEvent(name: "w\(worker)_e\(index)"))
                if index % 25 == 0 {
                    let batch = queue.drain()
                    drainLock.lock()
                    drained.value.append(contentsOf: batch)
                    drainLock.unlock()
                }
            }
        }
        drained.value.append(contentsOf: queue.drain())

        XCTAssertEqual(drained.value.count, total, "no event may be lost or duplicated")
        XCTAssertEqual(Set(drained.value.map(\.eventId)).count, total, "and none duplicated")
    }

    func testConcurrentAddRespectsTheBound() {
        let queue = EventQueue(maxSize: 50)
        DispatchQueue.concurrentPerform(iterations: 500) { index in
            queue.add(makeStubEvent(name: "e\(index)"))
        }
        XCTAssertEqual(queue.size(), 50, "the bound must hold under concurrent writers")
    }

    func testConcurrentOfflineQueueEnqueueAndDrain() {
        let offline = OfflineQueue(storage: InMemoryStorage(), maxSize: 10_000)
        let drained = Box<Int>(0)
        let drainLock = NSLock()

        DispatchQueue.concurrentPerform(iterations: 8) { worker in
            for index in 0..<50 {
                offline.enqueue([makeStubEvent(name: "w\(worker)_e\(index)")])
            }
            let batch = offline.drain()
            drainLock.lock()
            drained.value += batch.count
            drainLock.unlock()
        }
        drained.value += offline.drain().count

        XCTAssertEqual(drained.value, 400)
        XCTAssertEqual(offline.size(), 0)
    }

    func testConnectivityIsReadableWhileCallbacksAreRegistered() {
        let monitor = ConnectivityMonitor()
        defer { monitor.destroy() }

        DispatchQueue.concurrentPerform(iterations: 200) { index in
            if index.isMultiple(of: 2) {
                monitor.onOnline {}
            } else {
                _ = monitor.isOnline
            }
        }
    }

    // MARK: - Config-sync vs read races
    //
    // ConfigSync applies `/v1/config` on its own async callback while the
    // host app reads flags/experiments/identity from its own thread. These
    // three types were `@unchecked Sendable` with no lock; ThreadSanitizer
    // reported the same `Swift access race` class as EventQueue.

    func testFlagManagerConcurrentApplyAndEvaluate() {
        let manager = FlagManager()
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            if index.isMultiple(of: 4) {
                manager.setEvaluatedFlags(["a": AnyCodable(true), "b": AnyCodable(index)])
            } else {
                _ = manager.evaluate(flagKey: "a", defaultValue: .bool(false)) { _, _ in }
                _ = manager.count()
            }
        }
    }

    // `inspect`/`knownFlagKeys` are diagnostic reads added alongside
    // `evaluate`/`count` above — same lock, same concurrent-writer shape.
    // Nothing here should fail today (the lock design already covers it);
    // the point is to stop a future "narrow the lock to speed up
    // inspect()" refactor from silently reintroducing the race.
    func testFlagManagerConcurrentInspectAndKnownFlagKeysWhileApplying() {
        // overrideFlag persists to the shared UserDefaults.standard key —
        // clean up so this doesn't leak into other test files' state.
        let overridesKey = "lp_debug_overrides"
        UserDefaults.standard.removeObject(forKey: overridesKey)
        defer { UserDefaults.standard.removeObject(forKey: overridesKey) }

        let manager = FlagManager()
        manager.setOverridesAllowed(true)
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            switch index % 4 {
            case 0:
                manager.setEvaluatedFlags(["a": AnyCodable(true), "b": AnyCodable(index)])
            case 1:
                manager.overrideFlag("a", value: .bool(index.isMultiple(of: 2)))
            case 2:
                _ = manager.inspect(flagKey: "a", defaultValue: .bool(false))
            default:
                _ = manager.knownFlagKeys()
            }
        }
    }

    func testExperimentManagerConcurrentApplyAndResolve() {
        let manager = ExperimentManager(storage: InMemoryStorage())
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            if index.isMultiple(of: 4) {
                manager.setAssignments([:])
            } else {
                _ = manager.resolve(experimentKey: "exp") { _, _ in }
                _ = manager.count()
            }
        }
    }

    func testContextManagerConcurrentIdentifyAndRead() {
        let context = ContextManager(storage: InMemoryStorage())
        DispatchQueue.concurrentPerform(iterations: 200) { index in
            switch index % 4 {
            case 0: context.setUserId("user_\(index)")
            case 1: context.updateUserTraits(["plan": "pro", "n": index])
            case 2: context.touchSession()
            default: _ = context.eventContext()
            }
        }
        XCTAssertFalse(context.eventContext().deviceId.isEmpty)
    }

    func testEventContextSnapshotIsInternallyConsistent() {
        // A snapshot must not stitch a pre-identify anonymousId onto a
        // post-identify userId.
        let context = ContextManager(storage: InMemoryStorage())
        context.setUserId("user_a")
        let before = context.eventContext()
        XCTAssertEqual(before.userId, "user_a")

        context.resetIdentity()
        let after = context.eventContext()
        XCTAssertNil(after.userId)
        XCTAssertNotEqual(after.anonymousId, before.anonymousId, "reset rotates the anonymous id")
        XCTAssertEqual(after.deviceId, before.deviceId, "but never the device id")
    }

    // MARK: - Exposure callbacks must not run under the lock
    //
    // `onExposure` reaches the host's `SheepitConfig.onEvent` closure,
    // which may call back into the SDK. Holding a non-recursive lock
    // across it would deadlock the app on its first flag read.

    func testFlagExposureCallbackCanReenterTheManager() {
        let manager = FlagManager()
        manager.setEvaluatedFlags(["a": AnyCodable(true), "b": AnyCodable("x")])

        let reentered = Box<FlagValue?>(nil)
        _ = manager.evaluate(flagKey: "a", defaultValue: .bool(false)) { _, _ in
            // A customer's onEvent closure reading another flag.
            reentered.value = manager.evaluate(flagKey: "b", defaultValue: .bool(false)) { _, _ in }
        }

        XCTAssertEqual(reentered.value, .string("x"), "re-entry must not deadlock")
    }

    func testExperimentExposureCallbackCanReenterTheManager() {
        let manager = ExperimentManager(storage: InMemoryStorage())
        let count = Box<Int>(-1)
        _ = manager.resolve(experimentKey: "missing") { _, _ in
            count.value = manager.count()
        }
        // Not enrolled → no exposure fires; prove the un-enrolled path
        // still releases the lock for a later caller.
        XCTAssertEqual(manager.count(), 0)
        XCTAssertEqual(count.value, -1)
    }

    // MARK: - Overflow is instrumented, not silent

    func testQueueOverflowEmitsADiagnostic() {
        let bus = DiagnosticBus()
        let queue = EventQueue(maxSize: 2, diagnostics: bus)

        queue.add(makeStubEvent(name: "a"))
        queue.add(makeStubEvent(name: "b"))
        XCTAssertTrue(bus.getRecentDiagnostics().isEmpty, "no eviction yet, no diagnostic")

        queue.add(makeStubEvent(name: "c"))

        let events = bus.getRecentDiagnostics()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].code, "queue.overflow_evicted")
        XCTAssertEqual(events[0].severity, .warn)
        XCTAssertEqual(events[0].data?["dropped_event"]?.value as? String, "a")
    }

    func testOfflineQueueTrimEmitsADiagnostic() {
        let bus = DiagnosticBus()
        let offline = OfflineQueue(storage: InMemoryStorage(), maxSize: 2, diagnostics: bus)

        offline.enqueue([makeStubEvent(name: "a"), makeStubEvent(name: "b")])
        XCTAssertTrue(bus.getRecentDiagnostics().isEmpty)

        offline.enqueue([makeStubEvent(name: "c"), makeStubEvent(name: "d")])

        let events = bus.getRecentDiagnostics()
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(events[0].code, "offline_queue.trimmed")
        XCTAssertEqual(events[0].data?["dropped_count"]?.value as? Int, 2)
        XCTAssertEqual(offline.size(), 2)
    }

    func testOverflowDiagnosticSubscriberCanReenterTheQueue() {
        // Emitting inside the queue's lock would deadlock here.
        let bus = DiagnosticBus()
        let queue = EventQueue(maxSize: 1, diagnostics: bus)
        bus.subscribe { _ in _ = queue.size() }

        queue.add(makeStubEvent(name: "a"))
        queue.add(makeStubEvent(name: "b"))

        XCTAssertEqual(queue.size(), 1)
    }

    // MARK: - destroy() latch

    func testAtomicFlagLetsExactlyOneCallerThrough() {
        let flag = AtomicFlag()
        let winners = Box<Int>(0)
        let lock = NSLock()

        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            if flag.testAndSet() {
                lock.lock()
                winners.value += 1
                lock.unlock()
            }
        }

        XCTAssertEqual(winners.value, 1, "concurrent destroy() must run teardown exactly once")
        XCTAssertTrue(flag.value)
        XCTAssertFalse(flag.testAndSet(), "the latch is one-way")
    }

    // MARK: - Retry-After parsing (RFC 7231 §7.1.3)

    func testRetryAfterAcceptsDelaySeconds() {
        XCTAssertEqual(HTTPClient.parseRetryAfter("120"), 120)
        XCTAssertEqual(HTTPClient.parseRetryAfter(" 30 "), 30)
        XCTAssertEqual(HTTPClient.parseRetryAfter("0"), 0)
        XCTAssertEqual(HTTPClient.parseRetryAfter("-5"), 0, "negative delays clamp to 0")
    }

    func testRetryAfterAcceptsHTTPDate() throws {
        let future = Date().addingTimeInterval(300)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"

        let parsed = try XCTUnwrap(HTTPClient.parseRetryAfter(formatter.string(from: future)))
        XCTAssertEqual(parsed, 300, accuracy: 2, "an HTTP-date must not collapse to the default")
    }

    func testRetryAfterInThePastClampsToZero() {
        let past = "Wed, 21 Oct 2015 07:28:00 GMT"
        XCTAssertEqual(HTTPClient.parseRetryAfter(past), 0)
    }

    func testRetryAfterRejectsGarbage() {
        XCTAssertNil(HTTPClient.parseRetryAfter(nil))
        XCTAssertNil(HTTPClient.parseRetryAfter(""))
        XCTAssertNil(HTTPClient.parseRetryAfter("   "))
        XCTAssertNil(HTTPClient.parseRetryAfter("soon"))
    }
}

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}
