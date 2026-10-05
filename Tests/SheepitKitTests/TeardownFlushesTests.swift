import XCTest
@testable import SheepitKit

/// `TeardownFlushes.drain` must fail a test, not hang the run, when a destroyed client's final
/// flush never finishes.
final class TeardownFlushesTests: XCTestCase {
    func testAStuckFlushFailsInsteadOfHanging() async {
        TeardownFlushes.install()
        let stuck = Task<Void, Never> { try? await Task.sleep(for: .seconds(60)) }
        SheepitClient.teardownFlushHookForTesting.value?(stuck)

        let started = Date()
        let reported = LockedBox<[String]>([])
        await TeardownFlushes.drain(context: name, timeout: .milliseconds(300)) { message in
            reported.mutate { $0.append(message) }
        }

        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "drain must give up at its timeout")
        XCTAssertTrue(stuck.isCancelled, "the stuck flush is cancelled")
        XCTAssertEqual(reported.get().count, 1)
        XCTAssertTrue(reported.get().first?.contains("1 of 1 final flush") == true, reported.get().first ?? "")
        XCTAssertTrue(reported.get().first?.contains("testAStuckFlushFailsInsteadOfHanging") == true)
    }

    func testFinishedFlushesDrainSilently() async {
        TeardownFlushes.install()
        SheepitClient.teardownFlushHookForTesting.value?(Task {})
        let reported = LockedBox<[String]>([])
        await TeardownFlushes.drain(context: name, timeout: .seconds(5)) { message in reported.mutate { $0.append(message) } }
        XCTAssertEqual(reported.get(), [])
    }
}
