import Foundation

/// Internal enriched event — flat structure that gets transformed to API format on flush.
struct EnrichedEvent: Codable, Sendable {
    let eventId: String
    let eventName: String
    let eventProperties: [String: AnyCodable]?
    let deviceId: String
    let anonymousId: String
    let sessionId: String
    let userId: String?
    let platform: String
    let sdkVersion: String
    let locale: String
    let timezone: String
    let timestamp: String
    /// App and device dimensions frozen at TRACK time (PILOT_CORRECTNESS_DESIGN.md §2.2).
    /// `Transport` used to read these from `Bundle`/`DeviceProfile`/`Locale` at FLUSH time,
    /// so an event that waited in the offline queue across an app update was filed under
    /// the new version.
    ///
    /// 🔴 Optional, and it must stay optional. `OfflineQueue.load()` decodes
    /// `[EnrichedEvent]` under ONE `try?`, so a single element that fails to decode drops
    /// the ENTIRE persisted queue. A queue written by an SDK that predates this field
    /// decodes it as `nil`, and `Transport` then OMITS those dimensions — it never fills
    /// them in from whatever app and OS happen to be running at flush.
    let snapshot: TrackSnapshot?
    /// Every experiment assignment active when this event was tracked, keyed by experiment key
    /// (the ingest correctness design, §2.3). Frozen here for the same reason as `snapshot`: an
    /// event flushed after a new `/v1/config`, an `identify()` or a relaunch must still name the
    /// arm it was produced under. `nil` when none were active, and for every event queued by an
    /// SDK that predates this field; `Transport` then sends no experiment context at all.
    ///
    /// 🔴 Optional for the decode-safety reason on `snapshot`.
    let assignments: [String: EventAssignment]?

    init(
        eventId: String,
        eventName: String,
        eventProperties: [String: AnyCodable]?,
        deviceId: String,
        anonymousId: String,
        sessionId: String,
        userId: String?,
        platform: String,
        sdkVersion: String,
        locale: String,
        timezone: String,
        timestamp: String,
        snapshot: TrackSnapshot? = nil,
        assignments: [String: EventAssignment]? = nil
    ) {
        self.eventId = eventId
        self.eventName = eventName
        self.eventProperties = eventProperties
        self.deviceId = deviceId
        self.anonymousId = anonymousId
        self.sessionId = sessionId
        self.userId = userId
        self.platform = platform
        self.sdkVersion = sdkVersion
        self.locale = locale
        self.timezone = timezone
        self.timestamp = timestamp
        self.snapshot = snapshot
        self.assignments = assignments
    }

    /// Every field copied except `deviceId`. Used ONLY by
    /// `EventQueue.restampDeviceId(from:to:)` — see its doc for why a queued event's
    /// device id is ever rewritten after enqueue. That restamp is the ONLY identity repair
    /// §2.2 allows: user, session, snapshot and assignments are copied verbatim, never
    /// refreshed.
    func withDeviceId(_ newDeviceId: String) -> EnrichedEvent {
        EnrichedEvent(
            eventId: eventId,
            eventName: eventName,
            eventProperties: eventProperties,
            deviceId: newDeviceId,
            anonymousId: anonymousId,
            sessionId: sessionId,
            userId: userId,
            platform: platform,
            sdkVersion: sdkVersion,
            locale: locale,
            timezone: timezone,
            timestamp: timestamp,
            snapshot: snapshot,
            assignments: assignments
        )
    }
}

/// The app/device half of an event's track-time snapshot. The identity half (user,
/// anonymous, device, session) plus locale and timezone are `EnrichedEvent`'s own fields.
///
/// Every field is optional for the decode-safety reason on `EnrichedEvent.snapshot`; a
/// field added here later must be optional too, or one old queued event drops the queue.
struct TrackSnapshot: Codable, Sendable, Equatable {
    let appVersion: String?
    let appBuild: String?
    let appNamespace: String?
    let buildChannel: String?
    let deviceModel: String?
    let osVersion: String?
    let osName: String?
    let deviceType: String?
    /// ISO 3166-1 alpha-2 only — see `countryCode(_:)`.
    let country: String?

    /// Snapshot the running app and device for an event being tracked now.
    ///
    /// - Parameter appVersion: `SheepitConfig.appVersion`. Audit L-005: a release-binding
    ///   host sets it to a commit SHA / build tag so events resolve to a `Release` row, so
    ///   it wins over `CFBundleShortVersionString`.
    static func capture(appVersion: String?) -> TrackSnapshot {
        let invariant = processInvariant
        // Bounded to `ingestContextSchema.app.version`/`build` (max 64): a host passing a
        // long release tag would otherwise lose every event it tracks.
        let bound = SDKDefaults.appVersionMaxLength
        return TrackSnapshot(
            appVersion: (appVersion ?? invariant.appVersion).map { DeviceProfile.bounded($0, bound) },
            appBuild: invariant.appBuild.map { DeviceProfile.bounded($0, bound) },
            appNamespace: invariant.appNamespace,
            buildChannel: invariant.buildChannel,
            deviceModel: invariant.deviceModel,
            osVersion: invariant.osVersion,
            osName: invariant.osName,
            deviceType: invariant.deviceType,
            // Per event, not cached: the user can change region while the app runs.
            country: countryCode(Locale.current.region?.identifier)
        )
    }

    /// `ingestContextSchema.device.country` is `.length(2)`, but `Locale.region` is not
    /// always a country: UN M.49 area codes are legal and real ("419" = Latin America,
    /// common on es-419 devices), and one would be rejected. An absent country is a
    /// missing dimension; a rejected context loses the event.
    static func countryCode(_ region: String?) -> String? {
        guard let region, region.utf16.count == 2 else { return nil }
        return region
    }

    /// Bundle, hardware and OS do not change under a running process, so they are
    /// computed once instead of on every `track()` (`deviceModel()` is two sysctl calls).
    private static let processInvariant = TrackSnapshot(
        appVersion: DeviceProfile.appVersion(),
        appBuild: DeviceProfile.buildNumber(),
        appNamespace: Bundle.main.bundleIdentifier,
        buildChannel: DeviceProfile.buildChannel(),
        deviceModel: DeviceProfile.deviceModel(),
        osVersion: DeviceProfile.osVersion(),
        osName: DeviceProfile.osName,
        deviceType: DeviceProfile.deviceType(),
        country: nil
    )
}

/// In-memory FIFO event queue with max capacity.
/// Mirrors packages/sdk-js/src/queue.ts
///
/// Every access is lock-guarded. `add(_:)` is called from whatever thread
/// the host app calls `SheepitClient.track()` on, while `drain()` and — since
/// the 429 re-queue path — `add(_:)` are also called from the `Transport`
/// actor's executor. Unsynchronized `Array` mutation across those two is a
/// genuine memory-corruption race, reproduced under ThreadSanitizer
/// (`Swift access race` → SEGV inside `Array.append`) during the review of
/// the transport error-classing change.
final class EventQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [EnrichedEvent] = []
    private let maxSize: Int
    private let diagnostics: DiagnosticBus?

    init(maxSize: Int = SDKDefaults.maxQueueSize, diagnostics: DiagnosticBus? = nil) {
        // Clamped to >= 1 HERE, not just in `SheepitConfig.init`: `add(_:)` below calls
        // `removeFirst()` once `count >= maxSize`, which traps on an empty array at
        // `maxSize == 0` — and `SheepitConfig.maxQueueSize` is a public `var`, so
        // `var cfg = ...; cfg.maxQueueSize = 0` reaches this initializer already unclamped
        // (2026-09 security follow-up round 3, finding MF-1). This is the actual consumer, so
        // it's the layer that has to hold regardless of what the config struct did.
        self.maxSize = max(1, maxSize)
        self.diagnostics = diagnostics
    }

    func add(_ event: EnrichedEvent) {
        lock.lock()
        var evicted: EnrichedEvent?
        if events.count >= maxSize {
            evicted = events.removeFirst()
        }
        events.append(event)
        lock.unlock()

        // Emitted OUTSIDE the lock: DiagnosticBus invokes subscribers
        // synchronously, and a subscriber that called back into the queue
        // would deadlock on this non-recursive lock.
        guard let evicted else { return }
        diagnostics?.emit(
            .warn,
            .transport,
            code: "queue.overflow_evicted",
            message: "Event queue full (\(maxSize)) — dropped the oldest event",
            data: [
                "max_size": AnyCodable(maxSize),
                "dropped_event": AnyCodable(evicted.eventName),
            ]
        )
    }

    func drain() -> [EnrichedEvent] {
        lock.lock()
        defer { lock.unlock() }
        let drained = events
        events.removeAll()
        return drained
    }

    /// The oldest `limit` events, removed; the rest stay queued. `Transport.flush()` takes no
    /// more than the offline queue can hold, so a failed flush persists everything it took.
    func drain(upTo limit: Int) -> [EnrichedEvent] {
        lock.lock()
        defer { lock.unlock() }
        let count = min(max(0, limit), events.count)
        let drained = Array(events.prefix(count))
        events.removeFirst(count)
        return drained
    }

    func size() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return events.count
    }

    /// Re-stamp every currently-queued event still carrying `oldDeviceId` to `newDeviceId`.
    ///
    /// `track()` stamps each event with whatever `context.deviceId` was at the moment it was
    /// enqueued. On a device's first-ever launch that id is a LOCALLY-minted placeholder —
    /// registration is a detached, awaited-nowhere `Task`, so any event enqueued before it
    /// resolves (the SDK's own `$session_start`, or an eager host `track()` call) captures
    /// that placeholder, not the server-assigned id `context.setDeviceId()` adopts once the
    /// round trip completes. Without this, such an event never joins `device_assignments`
    /// (written under the SERVER id) and its whole history is permanently orphaned — the
    /// exact defect D-1 exists to close, just one step later in the pipeline.
    ///
    /// Scoped to an EXACT match on `oldDeviceId` so it can never touch an event that already
    /// carries a different id — including one a 429 already re-queued under some other
    /// device's identity, or one enqueued AFTER the swap that already carries the new id.
    func restampDeviceId(from oldDeviceId: String, to newDeviceId: String) {
        guard oldDeviceId != newDeviceId else { return }
        lock.lock()
        defer { lock.unlock() }
        for index in events.indices where events[index].deviceId == oldDeviceId {
            events[index] = events[index].withDeviceId(newDeviceId)
        }
    }
}
