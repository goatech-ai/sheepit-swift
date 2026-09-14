import Foundation

/// One experiment assignment as it stood when an event was TRACKED (the ingest correctness design,
/// §2.3). Stored on `EnrichedEvent.assignments` and serialized by `Transport.context(for:)` into
/// `context.experiments` and `context.experiment_assignments`.
///
/// It carries the subject KIND only, never the subject value: the server resolves `u:`/`d:` from
/// the event's own `context.user.id` / `context.device.id` at ingest.
///
/// 🔴 Every field is optional, and one added later must be too. `OfflineQueue.load()` decodes
/// `[EnrichedEvent]` under ONE `try?`, so a single persisted event that fails to decode drops the
/// whole queue. A missing field means the entry is incomplete, and `Transport` omits an
/// incomplete entry from `experiment_assignments` (unattributed, not control).
struct EventAssignment: Codable, Sendable, Equatable {
    let variantKey: String?
    let experimentId: String?
    /// `"user"` or `"device"`, as `/v1/config` delivered it.
    let subjectKind: String?
    let bucketingVersion: Int?
    let assignmentRevision: String?
    /// `nil`, or `EventAssignment.identityChanged`. The ingest API rejects the whole event for any
    /// other value, so nothing else may ever be written here.
    let subjectStatus: String?

    /// The event's user is not the user the assignment set was applied under (an `identify()` or
    /// logout landed before the next `/v1/config`), so a user-bucketed arm cannot be credited to
    /// this event's user.
    static let identityChanged = "identity_changed"
}
