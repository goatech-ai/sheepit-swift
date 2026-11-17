import XCTest
@testable import SheepitKit

/// S3d — experiment attribution on the wire and in the persisted queue (ingest correctness design
/// §2.3). Serialization, decode safety and the manager's identity comparison, below the client.
/// The through-the-client half is `ExperimentAttributionClientTests`.
final class ExperimentAttributionWireTests: XCTestCase {
    private static let experimentA = "11111111-1111-4111-8111-111111111111"
    private static let experimentB = "22222222-2222-4222-8222-222222222222"

    private func event(receipt: AssignmentReceipt? = nil, userId: String? = "user-1") -> EnrichedEvent {
        EnrichedEvent(
            eventId: UUID().uuidString, eventName: "outcome", eventProperties: nil,
            deviceId: "device-1", anonymousId: "anon-1", sessionId: "session-1", userId: userId,
            platform: "ios", sdkVersion: SDKDefaults.sdkVersion, locale: "en_US", timezone: "UTC",
            timestamp: "2026-09-14T10:00:00.000Z", snapshot: nil, assignmentReceipt: receipt
        )
    }

    /// The event's `context` exactly as `Transport` would send it, through the real encoder.
    private func wireContext(_ event: EnrichedEvent) throws -> [String: Any] {
        let data = try JSONEncoder().encode(Transport.wireEvent(event))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(object["context"] as? [String: Any])
    }

    private func sdkAssignment(kind: String?) throws -> SDKExperimentAssignment {
        let kindField = kind.map { #","subject_kind":"\#($0)""# } ?? ""
        let json = #"{"variant_key":"treatment","payload":{},"experiment_id":"\#(Self.experimentA)","#
            + #""bucketing_version":1,"assignment_revision":"42"\#(kindField)}"#
        return try JSONDecoder().decode(SDKExperimentAssignment.self, from: Data(json.utf8))
    }

    // MARK: - Receipt wire and queue compatibility

    func testOpaqueReceiptAndSwitchStatusReplaceBothLegacyMaps() throws {
        let context = try wireContext(event(receipt: AssignmentReceipt(token: "receipt-captured", identityChanged: true)))
        XCTAssertNil(context["assignment_token"])
        XCTAssertEqual(context["assignment_status"] as? String, "identity_changed")
        XCTAssertNil(context["experiments"])
        XCTAssertNil(context["experiment_assignments"])
    }

    func testMissingReceiptSendsNoClaims() throws {
        let context = try wireContext(event())
        XCTAssertNil(context["assignment_token"])
        XCTAssertNil(context["assignment_status"])
        XCTAssertNil(context["experiments"])
        XCTAssertNil(context["experiment_assignments"])
    }

    func testLegacyMapsIncludingMalformedAnd500EntriesAreIgnoredOnReplay() throws {
        let original = event(receipt: AssignmentReceipt(token: "receipt-captured"))
        let data = try JSONEncoder().encode(original)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let size = IngestChunking.encodedSize(original)
        for legacy: Any in [NSNull(), ["broken"], Dictionary(uniqueKeysWithValues: (0..<500).map {
            ("experiment-\($0)", ["variantKey": "treatment", "subjectStatus": "identity_changed"])
        })] {
            object["assignments"] = legacy
            let restored = try JSONDecoder().decode(EnrichedEvent.self, from: JSONSerialization.data(withJSONObject: object))
            XCTAssertEqual(restored.assignmentReceipt?.token, "receipt-captured")
            XCTAssertEqual(IngestChunking.encodedSize(restored), size)
            let encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(restored)) as? [String: Any])
            XCTAssertNil(encoded["assignments"], "old maps never return to disk")
        }
    }

    func testQueuePersistedBeforeReceiptsRetainsEveryEventAndTimestamp() throws {
        let storage = InMemoryStorage()
        storage.set(Data(Self.legacyQueueJSON.utf8), forKey: StorageKeys.offlineQueue)
        let queue = OfflineQueue(storage: storage)
        XCTAssertEqual(queue.peek().map(\.eventId), ["e1", "e2"])
        XCTAssertEqual(queue.peek().first?.timestamp, "2026-09-13T10:00:00.000Z")
        XCTAssertTrue(queue.peek().allSatisfy { $0.assignmentReceipt == nil })
    }

    /// A receipt is bound to the device row it was issued for: a re-stamped event names another, and the
    /// server resolves that pairing as `subject_mismatch`. Both queues, same rule.
    func testDeviceRestampedEventsShipNoToken() throws {
        let queue = EventQueue(maxSize: 10)
        queue.add(event(receipt: AssignmentReceipt(token: "receipt-for-device-1")))
        queue.restampDeviceId(from: "device-1", to: "replacement")
        let live = try XCTUnwrap(queue.drain().first)
        XCTAssertEqual(live.deviceId, "replacement")
        XCTAssertNil(live.assignmentReceipt?.token)
        let offline = OfflineQueue(storage: InMemoryStorage())
        offline.enqueue([event(receipt: AssignmentReceipt(token: "receipt-for-device-1"))])
        offline.restampDeviceId(from: "device-1", to: "replacement")
        let persisted = try XCTUnwrap(offline.peek().first)
        XCTAssertEqual(persisted.deviceId, "replacement")
        XCTAssertNil(persisted.assignmentReceipt?.token)
    }

    func testReceiptSurvivesOfflineRestartAndDeviceOnlyRestamp() throws {
        let storage = InMemoryStorage()
        let original = event(receipt: AssignmentReceipt(token: "receipt-before-c5", identityChanged: true))
        let offline = OfflineQueue(storage: storage)
        offline.enqueue([original])
        let restored = try XCTUnwrap(OfflineQueue(storage: storage).peek().first)
        let queue = EventQueue(maxSize: 10)
        queue.add(restored)
        queue.restampDeviceId(from: "device-1", to: "replacement")
        let rewritten = try XCTUnwrap(queue.drain().first)
        XCTAssertEqual(rewritten.deviceId, "replacement")
        XCTAssertEqual(rewritten.assignmentReceipt, original.assignmentReceipt)
        XCTAssertEqual(rewritten.eventId, original.eventId)
        XCTAssertEqual(rewritten.timestamp, original.timestamp)
        XCTAssertEqual(rewritten.userId, original.userId)
    }

    // MARK: - ExperimentManager

    /// A7b — the measured 2026-10-28 crossover: `/v1/config` derives `subject_kind` from the
    /// subject it bucketed, so a user-unit experiment on an anonymous device arrives as `"device"`.
    /// Crediting that entry to the device after `identify()` put one person in both arms once the
    /// refetched config re-bucketed them by user. Every entry is marked until that config lands.
    func testEveryEntryIsMarkedAfterAnIdentitySwitchWhateverItsKind() throws {
        let manager = ExperimentManager(storage: InMemoryStorage())
        manager.setAssignments([
            "user_exp": try sdkAssignment(kind: "user"),
            "device_exp": try sdkAssignment(kind: "device"),
            "unknown_kind_exp": try sdkAssignment(kind: nil),
        ], appliedUnderUserId: "user-a")
        manager.beginIdentitySwitch(to: "user-b")

        let sameUser = manager.receipt(eventUserId: "user-a").receipt
        XCTAssertEqual(sameUser.status, "identity_changed", "an in-flight identity switch marks the whole receipt")
        XCTAssertEqual(manager.receipt(eventUserId: "user-b").receipt.status, "identity_changed")
        let captured = manager.capture()
        XCTAssertEqual(captured.assignments.keys.sorted(), ["device_exp", "unknown_kind_exp", "user_exp"])
        XCTAssertEqual(captured.assignments["device_exp"]?.subjectKind, "device")
        XCTAssertEqual(captured.assignments["user_exp"]?.experimentId, Self.experimentA)
        XCTAssertEqual(captured.assignments["user_exp"]?.assignmentRevision, "42")
    }

    /// The measured path itself: anonymous config, then `identify()` before its refetch lands.
    func testAnAnonymousDeviceEntryIsMarkedOnceTheEventCarriesAUser() throws {
        let manager = ExperimentManager(storage: InMemoryStorage())
        manager.setAssignments(["device_exp": try sdkAssignment(kind: "device")], appliedUnderUserId: nil)

        XCTAssertNil(manager.receipt(eventUserId: nil).receipt.status,
                     "anonymous event under the anonymous set: resolved by the server")
        manager.beginIdentitySwitch(to: "user-a")
        XCTAssertEqual(manager.receipt(eventUserId: "user-a").receipt.status,
                       "identity_changed")
    }

    func testAnEventWithNoUserUnderAnIdentifiedSetIsMarked() throws {
        let manager = ExperimentManager(storage: InMemoryStorage())
        manager.setAssignments(["user_exp": try sdkAssignment(kind: "user")], appliedUnderUserId: "user-a")

        XCTAssertEqual(manager.receipt(eventUserId: nil).receipt.status,
                       "identity_changed")
    }

    func testAnUnknownKindIsTreatedAsUserBucketed() throws {
        let manager = ExperimentManager(storage: InMemoryStorage())
        manager.setAssignments(["team_exp": try sdkAssignment(kind: "team")], appliedUnderUserId: "user-a")

        XCTAssertEqual(manager.receipt(eventUserId: "user-b").receipt.status,
                       "identity_changed")
    }

    /// A cached body from before the fetch label existed: no event's user can match it.
    /// No identity switch: an identified launch applies its cache `.unknown` until its POST answers.
    func testAnUnknownAppliedIdentityMarksUserEntriesOnEveryEvent() throws {
        let manager = ExperimentManager(storage: InMemoryStorage())
        manager.setAssignments([
            "user_exp": try sdkAssignment(kind: "user"),
            "device_exp": try sdkAssignment(kind: "device"),
        ], appliedUnder: .unknown)

        for eventUser in [nil, "user-a"] as [String?] {
            XCTAssertEqual(manager.receipt(eventUserId: eventUser).receipt.status, "identity_changed", "\(String(describing: eventUser))")
            XCTAssertEqual(manager.capture().assignments.count, 2, "whole-receipt eligibility preserves both membership decisions")
        }
    }

    /// `identify()` calls `clearAssignments()`: the assignments AND the previous user stay.
    func testClearAssignmentsKeepsThePreviousAppliedUser() throws {
        let manager = ExperimentManager(storage: InMemoryStorage())
        manager.setAssignments(["user_exp": try sdkAssignment(kind: "user")], appliedUnderUserId: "user-a")

        manager.beginIdentitySwitch(to: "user-b")

        XCTAssertEqual(manager.receipt(eventUserId: "user-b").receipt.status,
                       "identity_changed")
    }

    /// DESIGN GUARD: passes on the old code, where nothing was ever snapshotted.
    func testClearForLogoutLeavesNothingToAttribute() throws {
        let manager = ExperimentManager(storage: InMemoryStorage())
        manager.setAssignments(["user_exp": try sdkAssignment(kind: "user")], appliedUnderUserId: "user-a")

        manager.clearForLogout()

        XCTAssertNil(manager.receipt(eventUserId: nil).receipt.token)
        XCTAssertEqual(manager.count(), 0)
    }

    func testIdentityChangeDiagnosticIsBoundedToOnePerAppliedSetAndCarriesNoUserId() throws {
        let bus = DiagnosticBus()
        let manager = ExperimentManager(storage: InMemoryStorage(), diagnostics: bus)
        let codes = { bus.getRecentDiagnostics().filter { $0.code == "experiment.identity_changed" } }

        manager.setAssignments(["user_exp": try sdkAssignment(kind: "user")], appliedUnderUserId: "alice-id")
        manager.reportIdentityChange(manager.receipt(eventUserId: "alice-id").receipt, set: manager.capture(), eventUserId: "alice-id")
        XCTAssertEqual(codes().count, 0)
        for _ in 0..<5 { manager.reportIdentityChange(manager.receipt(eventUserId: "bob-id").receipt, set: manager.capture(), eventUserId: "bob-id") }
        XCTAssertEqual(codes().count, 1, "one per applied set, not one per event")

        manager.setAssignments(["user_exp": try sdkAssignment(kind: "user")], appliedUnderUserId: "alice-id")
        manager.reportIdentityChange(manager.receipt(eventUserId: "carol-id").receipt, set: manager.capture(), eventUserId: "carol-id")
        XCTAssertEqual(codes().count, 2)

        let rendered = String(describing: codes().map { ($0.message, $0.data ?? [:]) })
        XCTAssertFalse(rendered.contains("alice-id") || rendered.contains("bob-id") || rendered.contains("carol-id"))
    }

    /// A set captured at an exposure's decision and stamped after a newer config was applied still
    /// marks its entries and reports them (`stale_set`), but must not use up the newer set's
    /// once-per-set diagnostic.
    func testAStaleCapturedSetDoesNotUseUpTheCurrentSetsIdentityChangeDiagnostic() throws {
        let bus = DiagnosticBus()
        let manager = ExperimentManager(storage: InMemoryStorage(), diagnostics: bus)
        let codes = { bus.getRecentDiagnostics().filter { $0.code == "experiment.identity_changed" } }
        manager.setAssignments(["user_exp": try sdkAssignment(kind: "user")], appliedUnderUserId: "alice-id")
        let stale = manager.capture()
        manager.setAssignments(["user_exp": try sdkAssignment(kind: "user")], appliedUnderUserId: "alice-id")

        let staleReceipt = manager.receipt(stale, eventUserId: "bob-id").receipt
        XCTAssertEqual(staleReceipt.status, "identity_changed")
        manager.reportIdentityChange(staleReceipt, set: stale, eventUserId: "bob-id")
        XCTAssertEqual(codes().count, 1, "the stale set's marked claim is reported")
        XCTAssertEqual(codes().last?.data?["stale_set"], AnyCodable(true))
        manager.reportIdentityChange(manager.receipt(eventUserId: "bob-id").receipt, set: manager.capture(), eventUserId: "bob-id")
        XCTAssertEqual(codes().count, 2, "the current set still reports its own identity change")
        XCTAssertEqual(codes().last?.data?["stale_set"], AnyCodable(false))
        manager.reportIdentityChange(manager.receipt(eventUserId: "bob-id").receipt, set: manager.capture(), eventUserId: "bob-id")
        XCTAssertEqual(codes().count, 2, "and only once")
    }

    // MARK: - Identity switch (A7b review of the sdk-js twin)

    /// An anonymous set, then a switch to `user-b`; returns the switch's token too.
    private func switchManager() throws -> (ExperimentManager, UInt64) {
        let manager = ExperimentManager(storage: InMemoryStorage())
        manager.setAssignments([
            "user_exp": try sdkAssignment(kind: "user"),
            "device_exp": try sdkAssignment(kind: "device"),
        ], appliedUnder: .fetchedUnder(nil))
        let token = manager.beginIdentitySwitch(to: "user-b")
        return (manager, token)
    }

    /// A failed bind can settle its switch, but an unknown config still cannot attribute a receipt.
    func testAFailedBindStillRequiresAKnownMatchingIdentityAfterTheNextConfig() throws {
        let (manager, token) = try switchManager()
        manager.identityBindSettledWithoutAck(token, afterFetch: 0)
        XCTAssertEqual(manager.receipt(eventUserId: "user-b").receipt.status,
                       "identity_changed", "still marked until a config lands")

        manager.setAssignments([
            "user_exp": try sdkAssignment(kind: "user"),
            "device_exp": try sdkAssignment(kind: "device"),
        ], appliedUnder: .unknown)

        XCTAssertEqual(manager.receipt(eventUserId: "user-b").receipt.status, "identity_changed", "unknown config remains ineligible for the whole receipt")
        XCTAssertEqual(manager.capture().assignments.count, 2)
    }

    /// A settle from an earlier switch's POST does not end the current switch, even one back to
    /// the same user (`identify(B); identify(A); identify(B)`, the first POST failing).
    func testASettleFromAnEarlierSwitchLeavesTheCurrentSwitchArmed() throws {
        for (secondSwitch, eventUser) in [(["user-c"], "user-c"), (["user-a", "user-b"], "user-b")] {
            let (manager, firstToken) = try switchManager()
            for user in secondSwitch { manager.beginIdentitySwitch(to: user) }
            manager.identityBindSettledWithoutAck(firstToken, afterFetch: 0)
            manager.setAssignments(["device_exp": try sdkAssignment(kind: "device")], appliedUnder: .unknown)

            XCTAssertEqual(manager.receipt(eventUserId: eventUser).receipt.status,
                           "identity_changed", "\(secondSwitch)")
        }
    }

    /// Early clear: a cached, seeded or unbound config applied before the bind is answered must not
    /// end the switch, or an unbound fetch sends resolved `d:` claims again (the 10-28 defect).
    func testAConfigAppliedBeforeTheBindIsAnsweredDoesNotEndTheSwitch() throws {
        let (manager, _) = try switchManager()
        for label in [ConfigIdentity.unknown, .fetchedUnder(nil), .fetchedUnder("user-a")] {
            manager.setAssignments(["device_exp": try sdkAssignment(kind: "device")], appliedUnder: label)
            XCTAssertEqual(manager.receipt(eventUserId: "user-b").receipt.status,
                           "identity_changed", "\(label)")
        }

        manager.setAssignments(["device_exp": try sdkAssignment(kind: "device")], appliedUnderUserId: "user-b")
        XCTAssertNil(manager.receipt(eventUserId: "user-b").receipt.status,
                     "the switched-to user's own config ends it")
    }

    /// Exposure loss: an exposure sent marked must not spend the dedup, or the arm never re-emits
    /// once its claims can be attributed. It is bounded to once per applied config while marked.
    func testAMarkedExposureDoesNotSpendTheDedupPastTheNextConfig() throws {
        let (manager, _) = try switchManager()
        // What `experiment()` + its `track` do: resolve, then stamp the exposure for the event's user.
        let read = { () -> Int in
            var fired = 0
            _ = manager.resolve(experimentKey: "device_exp") { key, variant, _, decided in
                fired += 1
                _ = manager.receipt(decided, eventUserId: "user-b", experimentKey: key, variant: variant)
            }
            return fired
        }
        XCTAssertEqual(read(), 1, "first read while marked fires")
        XCTAssertEqual(read(), 0, "and is deduped while the same config stands")

        manager.setAssignments(["device_exp": try sdkAssignment(kind: "device")], appliedUnder: .fetchedUnder("user-b"), assignmentToken: "receipt-user-b")
        XCTAssertEqual(read(), 1, "the attributable read after the switch ends fires again")
        XCTAssertEqual(read(), 0)
        manager.setAssignments(["device_exp": try sdkAssignment(kind: "device")], appliedUnder: .fetchedUnder("user-b"), assignmentToken: "receipt-user-b")
        XCTAssertEqual(read(), 0, "an unmarked exposure stays spent across configs")
    }

    /// The dedup drains when the wait ENDS, not on every apply: a config that keeps the switch armed
    /// does not re-send the marked exposure (each re-send was another `first`).
    func testAMarkedExposureIsNotReSentByAConfigThatKeepsTheWait() throws {
        let (manager, _) = try switchManager()
        let read = { () -> Int in
            var fired = 0
            _ = manager.resolve(experimentKey: "device_exp") { key, variant, _, decided in
                fired += 1
                _ = manager.receipt(decided, eventUserId: "user-b", experimentKey: key, variant: variant)
            }
            return fired
        }
        XCTAssertEqual(read(), 1)
        manager.setAssignments(["device_exp": try sdkAssignment(kind: "device")], appliedUnder: .unknown)
        XCTAssertEqual(read(), 0, "still waiting: no second marked exposure")
        manager.setAssignments(["device_exp": try sdkAssignment(kind: "device")], appliedUnder: .fetchedUnder("user-b"), assignmentToken: "receipt-user-b")
        XCTAssertEqual(read(), 1, "the wait ended")
    }

    /// The launch cache, whatever its label, never ends a switch whose bind settled unbound; only a
    /// server config does (a detached cache load can land after an immediate settle).
    func testTheLaunchCacheDoesNotEndASettledSwitch() throws {
        let (manager, token) = try switchManager()
        XCTAssertTrue(manager.identityBindSettledWithoutAck(token, afterFetch: 0))
        XCTAssertFalse(manager.identityBindSettledWithoutAck(token, afterFetch: 0), "a second settle is stale: no extra fetch")
        for label in [ConfigIdentity.unknown, .fetchedUnder(nil), .fetchedUnder("user-a")] {
            manager.setAssignments(["device_exp": try sdkAssignment(kind: "device")], appliedUnder: label, origin: .cache)
            XCTAssertEqual(manager.receipt(eventUserId: "user-b").receipt.status,
                           "identity_changed", "\(label)")
        }
        manager.setAssignments(["device_exp": try sdkAssignment(kind: "device")], appliedUnder: .unknown)
        XCTAssertEqual(manager.receipt(eventUserId: "user-b").receipt.status, "identity_changed")
    }

    /// Arming a switch does not clear the exposures: `identify()` arms it before storing the new
    /// user, and a read in between (still the previous user) must not re-fire as a `first`.
    func testArmingASwitchKeepsThePreviousUsersExposures() throws {
        let manager = ExperimentManager(storage: InMemoryStorage())
        manager.setAssignments(["device_exp": try sdkAssignment(kind: "device")], appliedUnderUserId: "user-a")
        let read = { () -> Int in
            var fired = 0
            _ = manager.resolve(experimentKey: "device_exp") { _, _, _, _ in fired += 1 }
            return fired
        }
        XCTAssertEqual(read(), 1)
        manager.beginIdentitySwitch(to: "user-b")
        XCTAssertEqual(read(), 0, "still user A's read: deduped")
        manager.clearExposures()
        XCTAssertEqual(read(), 1, "after the user is stored, the new user's read fires")
    }

    /// The launch cache does not end an awaited switch either, even labelled with the new user.
    func testTheLaunchCacheDoesNotEndAnAwaitedSwitch() throws {
        let (manager, _) = try switchManager()
        manager.setAssignments(["device_exp": try sdkAssignment(kind: "device")],
                               appliedUnder: .fetchedUnder("user-b"), origin: .cache)
        manager.setAssignments(["device_exp": try sdkAssignment(kind: "device")], appliedUnder: .unknown)

        XCTAssertEqual(manager.receipt(eventUserId: "user-b").receipt.status,
                       "identity_changed")
    }

    /// S2: a server fetch already in flight when the bind settled (numbered at or below the settle)
    /// does not end the switch; the next fetch started after it does.
    func testOnlyAFetchStartedAfterTheSettleEndsTheSwitch() throws {
        let (manager, token) = try switchManager()
        manager.identityBindSettledWithoutAck(token, afterFetch: 5)
        manager.setAssignments(["device_exp": try sdkAssignment(kind: "device")], appliedUnder: .unknown,
                               origin: .server(fetch: 5))
        XCTAssertEqual(manager.receipt(eventUserId: "user-b").receipt.status,
                       "identity_changed", "in flight at the settle")
        manager.setAssignments(["device_exp": try sdkAssignment(kind: "device")], appliedUnder: .unknown,
                               origin: .server(fetch: 6))
        XCTAssertEqual(manager.receipt(eventUserId: "user-b").receipt.status, "identity_changed")
    }

    /// S1: a marked user-kind exposure after the switch ended under one user is released when a
    /// late bind moves the applied label to another known user, not stranded for good.
    func testAMarkedExposureIsReleasedWhenTheLabelMovesToAnotherKnownUser() throws {
        let (manager, token) = try switchManager()
        manager.identityBindSettledWithoutAck(token, afterFetch: 0)
        manager.setAssignments(["user_exp": try sdkAssignment(kind: "user")], appliedUnderUserId: "user-a")
        let read = { () -> Int in
            var fired = 0
            _ = manager.resolve(experimentKey: "user_exp") { key, variant, _, decided in
                fired += 1
                _ = manager.receipt(decided, eventUserId: "user-b", experimentKey: key, variant: variant)
            }
            return fired
        }
        XCTAssertEqual(read(), 1, "marked: applied under user-a, event is user-b")
        XCTAssertEqual(read(), 0)
        manager.setAssignments(["user_exp": try sdkAssignment(kind: "user")], appliedUnder: .fetchedUnder("user-b"), assignmentToken: "receipt-user-b")
        XCTAssertEqual(read(), 1, "the late bind's config releases it")
    }

    /// A set captured before a switch was armed, stamped after it: the live switch marks it too.
    func testASetCapturedBeforeTheSwitchIsStampedUnderTheLiveSwitch() throws {
        let manager = ExperimentManager(storage: InMemoryStorage())
        manager.setAssignments(["device_exp": try sdkAssignment(kind: "device")], appliedUnderUserId: nil)
        let decided = manager.capture()
        manager.beginIdentitySwitch(to: "user-b")

        XCTAssertEqual(manager.receipt(decided, eventUserId: "user-b").receipt.status,
                       "identity_changed")
    }

    /// An exposure decided before a logout and tracked after it carries the logged-out user's set:
    /// every entry is unattributed, even though the event (now anonymous) matches its label.
    func testASetCapturedBeforeALogoutIsStampedUnattributed() throws {
        let manager = ExperimentManager(storage: InMemoryStorage())
        manager.setAssignments(["device_exp": try sdkAssignment(kind: "device")], appliedUnderUserId: nil)
        let decided = manager.capture()
        manager.clearForLogout()

        XCTAssertEqual(manager.receipt(decided, eventUserId: nil).receipt.status,
                       "identity_changed")
    }

    // MARK: - Fixtures

    /// Two events in the shape an SDK before this field wrote (S3b era, with `snapshot`).
    private static let legacyQueueJSON = #"""
    [{"eventId":"e1","eventName":"legacy_one","deviceId":"d","anonymousId":"a","sessionId":"s","userId":"u","platform":"ios","sdkVersion":"0.4.0","locale":"en_US","timezone":"UTC","timestamp":"2026-09-13T10:00:00.000Z","snapshot":{"appVersion":"1.0","osName":"iOS"}},{"eventId":"e2","eventName":"legacy_two","deviceId":"d","anonymousId":"a","sessionId":"s","platform":"ios","sdkVersion":"0.4.0","locale":"en_US","timezone":"UTC","timestamp":"2026-09-13T10:00:01.000Z"}]
    """#
}
