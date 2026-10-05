import Foundation
import XCTest
@testable import SheepitKit

/// Collects the final flush every `destroy()` starts (`SheepitClient.teardownFlushHookForTesting`)
/// so a suite can await them in `tearDown` before the next test resets its URL-protocol stub.
/// `destroy()`'s flush is fire-and-forget; without this, a test's late flush is recorded by the
/// next test's stub. Install in `setUp`, `drain(context: name)` in an async `tearDown`.
///
/// Bounded: a flush still running after `timeout` fails the test with a diagnostic and is
/// cancelled, instead of hanging the whole run. `report` replaces the `XCTFail` only so the
/// helper's own test can observe the diagnostic.
enum TeardownFlushes {
    private static let pending = LockedBox<[Task<Void, Never>]>([])

    static func install() {
        pending.set([])
        SheepitClient.teardownFlushHookForTesting.value = { task in pending.mutate { $0.append(task) } }
    }

    static func drain(
        context: String,
        timeout: Duration = .seconds(10),
        file: StaticString = #filePath,
        line: UInt = #line,
        report: ((String) -> Void)? = nil
    ) async {
        SheepitClient.teardownFlushHookForTesting.value = nil
        let tasks = pending.get()
        pending.set([])
        guard !tasks.isEmpty else { return }

        let finished = LockedBox([Bool](repeating: false, count: tasks.count))
        let settled = LockedBox(false)
        let allDone: Bool = await withCheckedContinuation { continuation in
            Task {
                for (index, task) in tasks.enumerated() {
                    await task.value
                    finished.mutate { $0[index] = true }
                }
                let first = settled.claim()
                if first { continuation.resume(returning: true) }
            }
            Task {
                try? await Task.sleep(for: timeout)
                let first = settled.claim()
                if first { continuation.resume(returning: false) }
            }
        }
        guard !allDone else { return }
        let stuck = finished.get().enumerated().filter { !$0.element }.map { $0.offset + 1 }
        for index in stuck { tasks[index - 1].cancel() }
        let message = "TeardownFlushes: \(stuck.count) of \(tasks.count) final flush(es) started by destroy() in "
            + "\(context) did not finish within \(timeout) (destroy order: \(stuck)). A client is "
            + "probably flushing to a host that neither answers nor refuses — point it at a stub "
            + "or at http://127.0.0.1:1."
        if let report { report(message) } else { XCTFail(message, file: file, line: line) }
    }
}

private extension LockedBox where Value == Bool {
    /// Sets the flag; true only for the first caller.
    func claim() -> Bool {
        var first = false
        mutate { if !$0 { $0 = true; first = true } }
        return first
    }
}
