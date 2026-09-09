import XCTest
@testable import SheepitKit

final class EventQueueTests: XCTestCase {
    func testAddAndDrain() {
        let queue = EventQueue(maxSize: 100)
        let event = makeEvent(name: "test_event")

        queue.add(event)
        XCTAssertEqual(queue.size(), 1)

        let drained = queue.drain()
        XCTAssertEqual(drained.count, 1)
        XCTAssertEqual(drained[0].eventName, "test_event")
        XCTAssertEqual(queue.size(), 0)
    }

    func testMaxSizeDropsOldest() {
        let queue = EventQueue(maxSize: 3)

        queue.add(makeEvent(name: "event_1"))
        queue.add(makeEvent(name: "event_2"))
        queue.add(makeEvent(name: "event_3"))
        queue.add(makeEvent(name: "event_4"))

        XCTAssertEqual(queue.size(), 3)
        let drained = queue.drain()
        XCTAssertEqual(drained[0].eventName, "event_2")
        XCTAssertEqual(drained[2].eventName, "event_4")
    }

    func testDrainEmptyQueue() {
        let queue = EventQueue()
        let drained = queue.drain()
        XCTAssertTrue(drained.isEmpty)
    }

    private func makeEvent(name: String) -> EnrichedEvent {
        EnrichedEvent(
            eventId: UUID().uuidString,
            eventName: name,
            eventProperties: nil,
            deviceId: "device_1",
            anonymousId: "anon_1",
            sessionId: "session_1",
            userId: nil,
            platform: "ios",
            sdkVersion: "0.1.0",
            locale: "en_US",
            timezone: "America/New_York",
            timestamp: ISO8601DateFormatter().string(from: Date())
        )
    }
}
