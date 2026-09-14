import XCTest
@testable import SheepitKit

/// S3d — experiment attribution on the wire and in the persisted queue (ingest correctness design
/// §2.3). Serialization, decode safety and the manager's identity comparison, below the client.
/// The through-the-client half is `ExperimentAttributionClientTests`.
final class ExperimentAttributionWireTests: XCTestCase {
    private static let experimentA = "11111111-1111-4111-8111-111111111111"
    private static let experimentB = "22222222-2222-4222-8222-222222222222"

    private func full(
        _ variant: String,
        kind: String,
        id: String = experimentA,
        status: String? = nil
    ) -> EventAssignment {
        EventAssignment(
            variantKey: variant, experimentId: id, subjectKind: kind,
            bucketingVersion: 1, assignmentRevision: "42", subjectStatus: status
        )
    }

    private func event(assignments: [String: EventAssignment]?, userId: String? = "user-1") -> EnrichedEvent {
        EnrichedEvent(
            eventId: UUID().uuidString, eventName: "outcome", eventProperties: nil,
            deviceId: "device-1", anonymousId: "anon-1", sessionId: "session-1", userId: userId,
            platform: "ios", sdkVersion: SDKDefaults.sdkVersion, locale: "en_US", timezone: "UTC",
            timestamp: "2026-09-14T10:00:00.000Z", snapshot: nil, assignments: assignments
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

    // MARK: - Wire

    func testUserAndDeviceEntriesCarryTheSubjectKindAndNeverASubjectValue() throws {
        let context = try wireContext(event(assignments: [
            "pricing_test": full("treatment", kind: "user"),
            "onboarding_test": full("b", kind: "device", id: Self.experimentB),
        ]))

        let entries = try XCTUnwrap(context["experiment_assignments"] as? [String: [String: Any]])
        XCTAssertEqual(Set(entries.keys), ["pricing_test", "onboarding_test"])
        let expectedKeys: Set = ["experiment_id", "variant_key", "subject_kind", "bucketing_version", "assignment_revision"]
        for (key, entry) in entries {
            XCTAssertEqual(Set(entry.keys), expectedKeys, "\(key): no `subject`, and no `subject_status` when unset")
        }
        XCTAssertEqual(entries["pricing_test"]?["subject_kind"] as? String, "user")
        XCTAssertEqual(entries["onboarding_test"]?["subject_kind"] as? String, "device")
        XCTAssertEqual(entries["pricing_test"]?["bucketing_version"] as? Int, 1)
        XCTAssertEqual(entries["pricing_test"]?["assignment_revision"] as? String, "42")

        // `experiments` is `[String: AnyCodable]`: the variant must arrive as a JSON string.
        let experiments = try XCTUnwrap(context["experiments"] as? [String: Any])
        XCTAssertEqual(experiments["pricing_test"] as? String, "treatment")
        XCTAssertEqual(experiments["onboarding_test"] as? String, "b")
    }

    func testIdentityChangedEntryIsSentWithItsStatusAndLeftOutOfExperiments() throws {
        let context = try wireContext(event(assignments: [
            "pricing_test": full("treatment", kind: "user", status: EventAssignment.identityChanged),
            "onboarding_test": full("b", kind: "device", id: Self.experimentB),
        ]))

        let experiments = try XCTUnwrap(context["experiments"] as? [String: Any])
        XCTAssertNil(experiments["pricing_test"],
                     "active_experiments has no status: sending it credits the new user to the old arm")
        XCTAssertEqual(experiments["onboarding_test"] as? String, "b")

        let entries = try XCTUnwrap(context["experiment_assignments"] as? [String: [String: Any]])
        XCTAssertEqual(entries["pricing_test"]?["subject_status"] as? String, "identity_changed")
        XCTAssertNil(entries["onboarding_test"]?["subject_status"])
    }

    func testEntriesMissingMetadataAreOmittedFromExperimentAssignments() throws {
        let variantOnly = EventAssignment(
            variantKey: "treatment", experimentId: nil, subjectKind: nil,
            bucketingVersion: nil, assignmentRevision: nil, subjectStatus: nil
        )
        let noRevision = EventAssignment(
            variantKey: "b", experimentId: Self.experimentB, subjectKind: "device",
            bucketingVersion: 1, assignmentRevision: nil, subjectStatus: nil
        )
        let context = try wireContext(event(assignments: [
            "cached_before_metadata": variantOnly,
            "no_revision": noRevision,
            "complete": full("c", kind: "device"),
        ]))

        let entries = try XCTUnwrap(context["experiment_assignments"] as? [String: [String: Any]])
        XCTAssertEqual(Set(entries.keys), ["complete"], "incomplete metadata is unattributed, not guessed")
        let experiments = try XCTUnwrap(context["experiments"] as? [String: Any])
        XCTAssertEqual(experiments["cached_before_metadata"] as? String, "treatment")

        let onlyIncomplete = try wireContext(event(assignments: ["cached_before_metadata": variantOnly]))
        XCTAssertNil(onlyIncomplete["experiment_assignments"], "an empty map is omitted, not sent as {}")
    }

    func testNoAssignmentsSendsNeitherKey() throws {
        for assignments in [nil, [:], ["x": full("t", kind: "user", status: EventAssignment.identityChanged)]]
            as [[String: EventAssignment]?]
        {
            let context = try wireContext(event(assignments: assignments))
            if assignments?.isEmpty == false {
                XCTAssertNil(context["experiments"], "only identity_changed entries leave experiments empty")
                XCTAssertNotNil(context["experiment_assignments"])
            } else {
                XCTAssertNil(context["experiments"])
                XCTAssertNil(context["experiment_assignments"])
            }
        }
    }

    func testTheTwoMapsNeverDisagreeOnAVariant() throws {
        let context = try wireContext(event(assignments: [
            "a": full("treatment", kind: "user"),
            "b": full("control", kind: "device", id: Self.experimentB),
            "c": full("x", kind: "user", status: EventAssignment.identityChanged),
        ]))
        let experiments = try XCTUnwrap(context["experiments"] as? [String: Any])
        let entries = try XCTUnwrap(context["experiment_assignments"] as? [String: [String: Any]])
        for (key, variant) in experiments {
            XCTAssertEqual(entries[key]?["variant_key"] as? String, variant as? String, key)
        }
    }

    /// `IngestChunking` budgets `Transport.wireEvent`, so the new bytes must be in what it measures.
    func testChunkingMeasuresTheAssignmentBytes() {
        let assignments = ["pricing_test": full("treatment", kind: "user")]
        let without = IngestChunking.encodedSize(event(assignments: nil))
        let with = IngestChunking.encodedSize(event(assignments: assignments))
        XCTAssertGreaterThan(with - without, 150, "one complete entry plus its experiments pair")
    }

    func testAnUnknownSubjectKindIsOmittedFromExperimentAssignments() throws {
        let context = try wireContext(event(assignments: [
            "team_exp": full("t", kind: "team"),
            "user_exp": full("u", kind: "user", id: Self.experimentB),
        ]))

        let entries = try XCTUnwrap(context["experiment_assignments"] as? [String: [String: Any]])
        XCTAssertEqual(Set(entries.keys), ["user_exp"], "the API rejects the whole event for any other kind")
    }

    // MARK: - Persisted queue

    /// A queue written by an SDK that predates `assignments`. DESIGN GUARD: passes on the old code
    /// too; it exists so the field can never become non-optional.
    func testQueuePersistedBeforeTheFieldStillDecodes() throws {
        let storage = InMemoryStorage()
        storage.set(Data(Self.legacyQueueJSON.utf8), forKey: StorageKeys.offlineQueue)

        let queue = OfflineQueue(storage: storage)

        XCTAssertEqual(queue.size(), 2)
        XCTAssertTrue(queue.peek().allSatisfy { $0.assignments == nil })
    }

    func testMixedQueueDecodesEveryEventAndKeepsTheirAssignments() throws {
        let storage = InMemoryStorage()
        let partial = EventAssignment(
            variantKey: "t", experimentId: nil, subjectKind: nil,
            bucketingVersion: nil, assignmentRevision: nil, subjectStatus: nil
        )
        let modern = event(assignments: [
            "pricing_test": full("treatment", kind: "user", status: EventAssignment.identityChanged),
            "partial": partial,
        ])
        let modernJSON = String(decoding: try JSONEncoder().encode(modern), as: UTF8.self)
        // A persisted entry written by a later SDK that dropped a field must decode too.
        let sparse = #"{"eventId":"e3","eventName":"sparse","deviceId":"d","anonymousId":"a","#
            + #""sessionId":"s","platform":"ios","sdkVersion":"0.4.0","locale":"en_US","timezone":"UTC","#
            + #""timestamp":"2026-09-14T10:00:00.000Z","assignments":{"k":{"variantKey":"v"}}}"#
        let legacy = Self.legacyQueueJSON.dropFirst().dropLast()
        storage.set(Data("[\(legacy),\(modernJSON),\(sparse)]".utf8), forKey: StorageKeys.offlineQueue)

        let events = OfflineQueue(storage: storage).peek()

        XCTAssertEqual(events.count, 4, "one undecodable element drops the whole queue")
        XCTAssertEqual(events[2].assignments?["pricing_test"],
                       full("treatment", kind: "user", status: EventAssignment.identityChanged))
        XCTAssertEqual(events[2].assignments?["partial"], partial)
        XCTAssertEqual(events[3].assignments?["k"]?.variantKey, "v")
    }

    func testRestampedQueuedEventKeepsItsAssignments() {
        let queue = EventQueue(maxSize: 10)
        let assignments = ["pricing_test": full("treatment", kind: "device")]
        let original = EnrichedEvent(
            eventId: "e1", eventName: "outcome", eventProperties: nil, deviceId: "local-uuid",
            anonymousId: "a", sessionId: "s", userId: nil, platform: "ios", sdkVersion: "0.4.0",
            locale: "en_US", timezone: "UTC", timestamp: "2026-09-14T10:00:00.000Z",
            snapshot: nil, assignments: assignments
        )
        queue.add(original)

        queue.restampDeviceId(from: "local-uuid", to: "dev_server")

        let restamped = queue.drain()
        XCTAssertEqual(restamped.first?.deviceId, "dev_server", "precondition: the restamp ran")
        XCTAssertEqual(restamped.first?.assignments, assignments)
    }

    // MARK: - ExperimentManager

    func testOnlyUserBucketedEntriesAreMarkedAfterAnIdentityChange() throws {
        let manager = ExperimentManager(storage: InMemoryStorage())
        manager.setAssignments([
            "user_exp": try sdkAssignment(kind: "user"),
            "device_exp": try sdkAssignment(kind: "device"),
            "unknown_kind_exp": try sdkAssignment(kind: nil),
        ], appliedUnderUserId: "user-a")

        let sameUser = try XCTUnwrap(manager.snapshot(eventUserId: "user-a"))
        XCTAssertTrue(sameUser.values.allSatisfy { $0.subjectStatus == nil })

        let otherUser = try XCTUnwrap(manager.snapshot(eventUserId: "user-b"))
        XCTAssertEqual(otherUser["user_exp"]?.subjectStatus, EventAssignment.identityChanged)
        XCTAssertNil(otherUser["device_exp"]?.subjectStatus, "identify() does not change the device")
        XCTAssertEqual(otherUser["unknown_kind_exp"]?.subjectStatus, EventAssignment.identityChanged,
                       "a kind-less entry may be user-bucketed, so it stays out of experiments")
        XCTAssertEqual(otherUser["user_exp"]?.experimentId, Self.experimentA)
        XCTAssertEqual(otherUser["user_exp"]?.assignmentRevision, "42")
    }

    func testAnEventWithNoUserUnderAnIdentifiedSetIsMarked() throws {
        let manager = ExperimentManager(storage: InMemoryStorage())
        manager.setAssignments(["user_exp": try sdkAssignment(kind: "user")], appliedUnderUserId: "user-a")

        XCTAssertEqual(manager.snapshot(eventUserId: nil)?["user_exp"]?.subjectStatus,
                       EventAssignment.identityChanged)
    }

    func testAnUnknownKindIsTreatedAsUserBucketed() throws {
        let manager = ExperimentManager(storage: InMemoryStorage())
        manager.setAssignments(["team_exp": try sdkAssignment(kind: "team")], appliedUnderUserId: "user-a")

        XCTAssertEqual(manager.snapshot(eventUserId: "user-b")?["team_exp"]?.subjectStatus,
                       EventAssignment.identityChanged)
    }

    /// A cached body from before the fetch label existed: no event's user can match it.
    func testAnUnknownAppliedIdentityMarksUserEntriesOnEveryEvent() throws {
        let manager = ExperimentManager(storage: InMemoryStorage())
        manager.setAssignments([
            "user_exp": try sdkAssignment(kind: "user"),
            "device_exp": try sdkAssignment(kind: "device"),
        ], appliedUnder: .unknown)

        for eventUser in [nil, "user-a"] as [String?] {
            let snapshot = try XCTUnwrap(manager.snapshot(eventUserId: eventUser))
            XCTAssertEqual(snapshot["user_exp"]?.subjectStatus, EventAssignment.identityChanged, "\(String(describing: eventUser))")
            XCTAssertNil(snapshot["device_exp"]?.subjectStatus)
        }
    }

    /// `identify()` calls `clearAssignments()`: the assignments AND the previous user stay.
    func testClearAssignmentsKeepsThePreviousAppliedUser() throws {
        let manager = ExperimentManager(storage: InMemoryStorage())
        manager.setAssignments(["user_exp": try sdkAssignment(kind: "user")], appliedUnderUserId: "user-a")

        manager.clearAssignments()

        XCTAssertEqual(manager.snapshot(eventUserId: "user-b")?["user_exp"]?.subjectStatus,
                       EventAssignment.identityChanged)
    }

    /// DESIGN GUARD: passes on the old code, where nothing was ever snapshotted.
    func testClearForLogoutLeavesNothingToAttribute() throws {
        let manager = ExperimentManager(storage: InMemoryStorage())
        manager.setAssignments(["user_exp": try sdkAssignment(kind: "user")], appliedUnderUserId: "user-a")

        manager.clearForLogout()

        XCTAssertNil(manager.snapshot(eventUserId: nil))
    }

    func testIdentityChangeDiagnosticIsBoundedToOnePerAppliedSetAndCarriesNoUserId() throws {
        let bus = DiagnosticBus()
        let manager = ExperimentManager(storage: InMemoryStorage(), diagnostics: bus)
        let codes = { bus.getRecentDiagnostics().filter { $0.code == "experiment.identity_changed" } }

        manager.setAssignments(["user_exp": try sdkAssignment(kind: "user")], appliedUnderUserId: "alice-id")
        _ = manager.snapshot(eventUserId: "alice-id")
        XCTAssertEqual(codes().count, 0)
        for _ in 0..<5 { _ = manager.snapshot(eventUserId: "bob-id") }
        XCTAssertEqual(codes().count, 1, "one per applied set, not one per event")

        manager.setAssignments(["user_exp": try sdkAssignment(kind: "user")], appliedUnderUserId: "alice-id")
        _ = manager.snapshot(eventUserId: "carol-id")
        XCTAssertEqual(codes().count, 2)

        let rendered = String(describing: codes().map { ($0.message, $0.data ?? [:]) })
        XCTAssertFalse(rendered.contains("alice-id") || rendered.contains("bob-id") || rendered.contains("carol-id"))
    }

    // MARK: - Fixtures

    /// Two events in the shape an SDK before this field wrote (S3b era, with `snapshot`).
    private static let legacyQueueJSON = #"""
    [{"eventId":"e1","eventName":"legacy_one","deviceId":"d","anonymousId":"a","sessionId":"s","userId":"u","platform":"ios","sdkVersion":"0.4.0","locale":"en_US","timezone":"UTC","timestamp":"2026-09-13T10:00:00.000Z","snapshot":{"appVersion":"1.0","osName":"iOS"}},{"eventId":"e2","eventName":"legacy_two","deviceId":"d","anonymousId":"a","sessionId":"s","platform":"ios","sdkVersion":"0.4.0","locale":"en_US","timezone":"UTC","timestamp":"2026-09-13T10:00:01.000Z"}]
    """#
}
