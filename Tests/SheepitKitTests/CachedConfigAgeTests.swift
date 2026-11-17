import XCTest
@testable import SheepitKit

/// The cached `/v1/config` at launch, by age (`CachedConfigLimits`, `LaunchConfigCache`): applied
/// whatever its age by default, reported stale past `configStaleAfter`, deleted past a host-set
/// `configOfflineMaxAge` and only then, never by a failed fetch.
///
/// 🔴 0.8.0 deleted any cache older than 24 hours at launch, and 0.9.0 to 0.10.1 any older than 7
/// days, so a device that could not reach the server (the pilot's app, off its VPN) read every flag
/// at its compiled-in default and moved members out of their experiment arms. Every age here is set
/// on an injected clock.
final class CachedConfigAgeTests: XCTestCase {
    private static let hour: TimeInterval = 3600
    private static let launch = Date(timeIntervalSince1970: 1_800_000_000)
    private static let body = #"""
    {"data":{"config_version":"7","etag":"\"v7\"","flags":{"native_home":true},"experiments":{
      "pricing_test":{"variant_key":"treatment","payload":{},"experiment_id":"11111111-1111-4111-8111-111111111111","subject_kind":"user","bucketing_version":1,"assignment_revision":"7"}}}}
    """#
    /// 0.9.0 to 0.10.1's default, now only by configuration.
    private static let sevenDayLimit = CachedConfigLimits(staleAfter: 86_400, offlineMaxAge: 7 * 24 * 3600)
    private static let newerBody = #"{"data":{"config_version":"8","etag":"\"v8\"","flags":{"native_home":false},"experiments":{}}}"#

    override func setUp() {
        super.setUp()
        AttributionCaptureProtocol.reset()
    }

    override func tearDown() {
        AttributionCaptureProtocol.reset()
        super.tearDown()
    }

    // MARK: - Helpers

    private struct Applied {
        let flags: [String: AnyCodable]
        let identity: ConfigIdentity
    }

    private func seed(_ storage: StorageProvider, ageHours: Double?, label: ServerHeldUser? = .known(nil), body: String = body) throws {
        storage.set(Data(body.utf8), forKey: StorageKeys.sdkConfig)
        if let ageHours {
            storage.set(String(Self.launch.timeIntervalSince1970 - ageHours * Self.hour), forKey: StorageKeys.sdkConfigCachedAt)
        }
        if let label {
            storage.set(try JSONEncoder().encode(label), forKey: StorageKeys.sdkConfigFetchedUnder)
        }
    }

    private func makeSync(
        storage: StorageProvider,
        clock: LockedBox<Date>,
        limits: CachedConfigLimits = .default,
        gate: ConfigResetGate = ConfigResetGate(),
        freshness: ConfigFreshnessRecorder = ConfigFreshnessRecorder(),
        identity: @escaping @Sendable () -> (identity: ConfigIdentity, epoch: UInt64) = { (.fetchedUnder(nil), 0) },
        protocolClass: AnyClass = AttributionCaptureProtocol.self,
        applied: LockedBox<[Applied]>
    ) -> ConfigSync {
        ConfigSync(
            http: HTTPClient(
                config: SheepitConfig(apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64),
                                      apiUrl: "https://stub.invalid", retryAttempts: 1),
                log: Logger(debug: false),
                urlProtocolClasses: [protocolClass]),
            storage: storage,
            refreshInterval: 3600,
            log: Logger(debug: false),
            resetGate: gate,
            limits: limits,
            now: { clock.get() },
            freshness: freshness,
            identityProvider: identity,
            onConfig: { response, identity, _ in
                applied.mutate { $0.append(Applied(flags: response.flags, identity: identity)) }
            }
        )
    }

    /// Runs only the launch cache load: `start()` loads synchronously, then `stop()` cancels the
    /// refresh loop. The loop's launch fetch may still reach the stub, which answers 304 by default.
    private func launch(_ sync: ConfigSync) async {
        await sync.start(deviceIdGetter: { "device-1" })
        await sync.stop()
    }

    // MARK: - Age bands

    func testACacheUnder24HoursIsAppliedAndNotStale() async throws {
        let storage = InMemoryStorage()
        try seed(storage, ageHours: 3)
        let applied = LockedBox<[Applied]>([])
        let freshness = ConfigFreshnessRecorder()
        await launch(makeSync(storage: storage, clock: LockedBox(Self.launch), freshness: freshness, applied: applied))

        XCTAssertEqual(applied.get().first?.flags["native_home"]?.value as? Bool, true)
        let status = try XCTUnwrap(freshness.snapshot(now: Self.launch, staleAfter: CachedConfigLimits.default.staleAfter))
        XCTAssertEqual(status.source, .cache)
        XCTAssertEqual(status.age, 3 * Self.hour, accuracy: 0.001)
        XCTAssertFalse(status.isStale)
    }

    /// The 0.8.0 failure: 30 hours old, device offline. The flags must stay what they were.
    func testACacheBetween24HoursAndTheOfflineLimitIsAppliedReportedStaleAndKept() async throws {
        let storage = InMemoryStorage()
        try seed(storage, ageHours: 30)
        let applied = LockedBox<[Applied]>([])
        let freshness = ConfigFreshnessRecorder()
        await launch(makeSync(storage: storage, clock: LockedBox(Self.launch), freshness: freshness,
                              protocolClass: OfflineURLProtocol.self, applied: applied))

        XCTAssertEqual(applied.get().count, 1, "a 30 h cache must be applied while offline")
        XCTAssertEqual(applied.get().first?.flags["native_home"]?.value as? Bool, true)
        XCTAssertNotNil(storage.data(forKey: StorageKeys.sdkConfig), "a cache inside the offline limit was deleted")
        let status = try XCTUnwrap(freshness.snapshot(now: Self.launch, staleAfter: CachedConfigLimits.default.staleAfter))
        XCTAssertEqual(status.source, .cache)
        XCTAssertTrue(status.isStale)
        XCTAssertEqual(status.fetchedAt, Self.launch.addingTimeInterval(-30 * Self.hour))
    }

    /// A host-set 7-day limit (0.9.0 to 0.10.1's default): one hour inside it is applied.
    func testACacheAtSixDays23HoursIsAppliedUnderASevenDayLimit() async throws {
        let storage = InMemoryStorage()
        try seed(storage, ageHours: 7 * 24 - 1)
        let applied = LockedBox<[Applied]>([])
        await launch(makeSync(storage: storage, clock: LockedBox(Self.launch), limits: Self.sevenDayLimit,
                              protocolClass: OfflineURLProtocol.self, applied: applied))

        XCTAssertEqual(applied.get().count, 1)
    }

    /// 🔴 The default has no limit (founder decision 2026-11-09): a 30-day cache is applied, reported
    /// stale, and kept on disk. 0.10.1 deleted it at launch and every flag read its default.
    func testA30DayCacheIsAppliedReportedStaleAndKeptUnderTheDefault() async throws {
        let storage = InMemoryStorage()
        try seed(storage, ageHours: 30 * 24)
        let applied = LockedBox<[Applied]>([])
        let freshness = ConfigFreshnessRecorder()
        await launch(makeSync(storage: storage, clock: LockedBox(Self.launch), freshness: freshness,
                              protocolClass: OfflineURLProtocol.self, applied: applied))

        XCTAssertEqual(applied.get().count, 1, "a 30-day cache was not applied under the default")
        XCTAssertEqual(applied.get().first?.flags["native_home"]?.value as? Bool, true)
        XCTAssertNotNil(storage.data(forKey: StorageKeys.sdkConfig), "a 30-day cache was deleted under the default")
        let status = try XCTUnwrap(freshness.snapshot(now: Self.launch, staleAfter: CachedConfigLimits.default.staleAfter))
        XCTAssertEqual(status.source, .cache)
        XCTAssertTrue(status.isStale)
        XCTAssertEqual(status.age, 30 * 24 * Self.hour, accuracy: 0.001)
    }

    /// A finite limit set by the host is still honoured: past it the cache is deleted at launch.
    func testACacheOverAHostSetOfflineLimitIsNotAppliedAndIsDeleted() async throws {
        let storage = InMemoryStorage()
        try seed(storage, ageHours: 7 * 24 + 1)
        let applied = LockedBox<[Applied]>([])
        let freshness = ConfigFreshnessRecorder()
        await launch(makeSync(storage: storage, clock: LockedBox(Self.launch), limits: Self.sevenDayLimit,
                              freshness: freshness, protocolClass: OfflineURLProtocol.self, applied: applied))

        XCTAssertTrue(applied.get().isEmpty, "a cache past the offline limit was applied")
        XCTAssertNil(storage.data(forKey: StorageKeys.sdkConfig), "a cache past the offline limit was kept on disk")
        XCTAssertNil(storage.string(forKey: StorageKeys.sdkConfigCachedAt))
        XCTAssertNil(storage.data(forKey: StorageKeys.sdkConfigFetchedUnder))
        XCTAssertNil(freshness.current)
    }

    // MARK: - Unusable stamps (unchanged from 0.8.0)

    func testACacheWithNoTimestampIsNotAppliedAndIsDeleted() async throws {
        let storage = InMemoryStorage()
        try seed(storage, ageHours: nil)
        let applied = LockedBox<[Applied]>([])
        await launch(makeSync(storage: storage, clock: LockedBox(Self.launch),
                              protocolClass: OfflineURLProtocol.self, applied: applied))

        XCTAssertTrue(applied.get().isEmpty)
        XCTAssertNil(storage.data(forKey: StorageKeys.sdkConfig))
    }

    /// Under a host-set limit a future stamp (clock skew at write) cannot be checked against it.
    func testAFutureDatedCacheIsNotAppliedAndIsDeletedUnderAHostSetLimit() async throws {
        let storage = InMemoryStorage()
        try seed(storage, ageHours: -1)
        let applied = LockedBox<[Applied]>([])
        await launch(makeSync(storage: storage, clock: LockedBox(Self.launch), limits: Self.sevenDayLimit,
                              protocolClass: OfflineURLProtocol.self, applied: applied))

        XCTAssertTrue(applied.get().isEmpty, "a future stamp makes the age negative: it would never pass the limit")
        XCTAssertNil(storage.data(forKey: StorageKeys.sdkConfig))
    }

    /// With no limit (the default) a future stamp is applied, and reported stale: its age is unknown
    /// until a fetch replaces the entry.
    func testAFutureDatedCacheIsAppliedAndReportedStaleUnderTheDefault() async throws {
        let storage = InMemoryStorage()
        try seed(storage, ageHours: -2)
        let applied = LockedBox<[Applied]>([])
        let freshness = ConfigFreshnessRecorder()
        await launch(makeSync(storage: storage, clock: LockedBox(Self.launch), freshness: freshness,
                              protocolClass: OfflineURLProtocol.self, applied: applied))

        XCTAssertEqual(applied.get().count, 1, "a future-dated cache was dropped under the default")
        XCTAssertNotNil(storage.data(forKey: StorageKeys.sdkConfig))
        let status = try XCTUnwrap(freshness.snapshot(now: Self.launch, staleAfter: CachedConfigLimits.default.staleAfter))
        XCTAssertEqual(status.source, .cache)
        XCTAssertTrue(status.isStale, "a stamp later than the device clock has an unknown age: it must read stale")
        XCTAssertEqual(status.age, 0)
    }

    func testAnInfiniteTimestampIsNotApplied() async throws {
        let storage = InMemoryStorage()
        try seed(storage, ageHours: nil)
        storage.set("inf", forKey: StorageKeys.sdkConfigCachedAt)
        let applied = LockedBox<[Applied]>([])
        await launch(makeSync(storage: storage, clock: LockedBox(Self.launch),
                              protocolClass: OfflineURLProtocol.self, applied: applied))

        XCTAssertTrue(applied.get().isEmpty)
        XCTAssertNil(storage.data(forKey: StorageKeys.sdkConfig))
    }

    // MARK: - Reset and identity guards

    /// "Session expired" at launch, on a 3-day-old cache: a `reset()` between the cache read and
    /// its apply leaves nothing applied and no freshness recorded.
    func testAResetBetweenTheReadAndTheApplyAppliesNothing() async throws {
        let storage = ReadHookStorage()
        try seed(storage, ageHours: 72, label: .known("user-a"))
        let gate = ConfigResetGate()
        let freshness = ConfigFreshnessRecorder()
        let applied = LockedBox<[Applied]>([])
        let resetDone = LockedBox(false)
        storage.onFirstRead(of: StorageKeys.sdkConfigFetchedUnder) {
            DispatchQueue.global().async {
                gate.reset {
                    applied.set([])
                    freshness.clear()
                    storage.removeObject(forKey: StorageKeys.sdkConfig)
                }
                resetDone.set(true)
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        await launch(makeSync(storage: storage, clock: LockedBox(Self.launch), gate: gate, freshness: freshness,
                              identity: { (.fetchedUnder("user-a"), 0) },
                              protocolClass: OfflineURLProtocol.self, applied: applied))
        let deadline = Date().addingTimeInterval(5)
        while !resetDone.get(), Date() < deadline { try await Task.sleep(for: .milliseconds(5)) }

        XCTAssertTrue(resetDone.get(), "precondition: the reset ran")
        XCTAssertTrue(applied.get().isEmpty, "the logged-out user's cached config was applied after reset()")
        XCTAssertNil(freshness.current, "freshness describes a config that reset() removed")
    }

    /// A 5-day-old body whose stored label is not what the server is known to hold is applied as
    /// `.unknown`, and its user-bucketed assignment is then marked `identity_changed` on events.
    func testAnOldCacheUnderAMismatchedLabelIsAppliedAsUnknownAndUnattributed() async throws {
        let storage = InMemoryStorage()
        try seed(storage, ageHours: 5 * 24, label: .known("user-b"))
        let applied = LockedBox<[Applied]>([])
        await launch(makeSync(storage: storage, clock: LockedBox(Self.launch),
                              identity: { (.fetchedUnder("user-a"), 0) },
                              protocolClass: OfflineURLProtocol.self, applied: applied))

        let first = try XCTUnwrap(applied.get().first)
        XCTAssertEqual(first.identity, .unknown)

        let manager = ExperimentManager(storage: InMemoryStorage(), diagnostics: DiagnosticBus())
        let decoded = try JSONDecoder().decode(ApiDataResponse<SDKConfigResponse>.self, from: Data(Self.body.utf8))
        manager.setAssignments(decoded.data.experiments, appliedUnder: first.identity)
        XCTAssertEqual(manager.receipt(eventUserId: "user-a").receipt.status,
                       "identity_changed")
    }

    // MARK: - Fetch outcomes

    /// Offline (transport error) and a 5xx: neither may delete the cache.
    func testAFailedFetchKeepsTheCache() async throws {
        for protocolClass: AnyClass in [OfflineURLProtocol.self, AttributionCaptureProtocol.self] {
            AttributionCaptureProtocol.reset()
            AttributionCaptureProtocol.failNextConfigRequests(10)
            let storage = InMemoryStorage()
            try seed(storage, ageHours: 48)
            let stampBefore = storage.string(forKey: StorageKeys.sdkConfigCachedAt)
            let applied = LockedBox<[Applied]>([])
            let freshness = ConfigFreshnessRecorder()
            let sync = makeSync(storage: storage, clock: LockedBox(Self.launch), freshness: freshness,
                                protocolClass: protocolClass, applied: applied)
            await launch(sync)
            await sync.refresh(deviceId: "device-1")

            XCTAssertEqual(storage.data(forKey: StorageKeys.sdkConfig), Data(Self.body.utf8), "\(protocolClass)")
            XCTAssertEqual(storage.string(forKey: StorageKeys.sdkConfigCachedAt), stampBefore, "\(protocolClass)")
            XCTAssertEqual(applied.get().count, 1, "\(protocolClass): only the cache was applied")
            XCTAssertEqual(freshness.current?.source, .cache, "\(protocolClass)")
        }
    }

    func testASuccessfulFetchReplacesTheCache() async throws {
        let storage = InMemoryStorage()
        try seed(storage, ageHours: 48)
        let clock = LockedBox(Self.launch)
        let applied = LockedBox<[Applied]>([])
        let freshness = ConfigFreshnessRecorder()
        let sync = makeSync(storage: storage, clock: clock, freshness: freshness, applied: applied)
        await launch(sync)

        AttributionCaptureProtocol.serveConfig(Self.newerBody)
        clock.set(Self.launch.addingTimeInterval(60))
        await sync.refresh(deviceId: "device-1")

        XCTAssertEqual(storage.data(forKey: StorageKeys.sdkConfig), Data(Self.newerBody.utf8))
        XCTAssertEqual(storage.string(forKey: StorageKeys.sdkConfigCachedAt),
                       String(Self.launch.addingTimeInterval(60).timeIntervalSince1970))
        XCTAssertEqual(applied.get().last?.flags["native_home"]?.value as? Bool, false)
        XCTAssertEqual(freshness.current, ConfigFreshnessRecorder.Entry(source: .server, fetchedAt: Self.launch.addingTimeInterval(60)))
    }

    /// 🔴 A long-lived process polling into 304s must keep the stamp current. Otherwise its next
    /// offline launch measures the age from the last 200, which can be past the offline limit.
    func testA304MovesTheStampToNow() async throws {
        let storage = InMemoryStorage()
        let clock = LockedBox(Self.launch)
        let applied = LockedBox<[Applied]>([])
        let freshness = ConfigFreshnessRecorder()
        let sync = makeSync(storage: storage, clock: clock, freshness: freshness, applied: applied)
        AttributionCaptureProtocol.serveConfig(Self.body)
        await sync.refresh(deviceId: "device-1") // 200, ETag held

        let later = Self.launch.addingTimeInterval(6 * 24 * Self.hour)
        clock.set(later)
        await sync.refresh(deviceId: "device-1") // 304 against "v7"

        XCTAssertEqual(AttributionCaptureProtocol.configIfNoneMatch.last, #""v7""#, "precondition: a conditional fetch")
        XCTAssertEqual(storage.string(forKey: StorageKeys.sdkConfigCachedAt), String(later.timeIntervalSince1970))
        XCTAssertEqual(freshness.current, ConfigFreshnessRecorder.Entry(source: .server, fetchedAt: later))
        XCTAssertEqual(applied.get().count, 1, "a 304 applies nothing")
    }

    /// A 304 to a request that sent no validator confirms nothing: the stub answers 304 to every
    /// request until it is given a body.
    func testA304ToAnUnconditionalRequestLeavesTheStamp() async throws {
        let storage = InMemoryStorage()
        try seed(storage, ageHours: 48)
        let stampBefore = storage.string(forKey: StorageKeys.sdkConfigCachedAt)
        let sync = makeSync(storage: storage, clock: LockedBox(Self.launch), applied: LockedBox([]))
        await launch(sync)
        await sync.refresh(deviceId: "device-1")

        XCTAssertEqual(AttributionCaptureProtocol.configIfNoneMatch.last, .some(nil), "precondition: no validator sent")
        XCTAssertEqual(storage.string(forKey: StorageKeys.sdkConfigCachedAt), stampBefore)
    }

    /// 🔴 The identify latch. `identify("user-b")` whose POST committed but whose answer was lost,
    /// or was refused while `/v1/config` still answers: the row's state is `.unknown`, no
    /// unconditional refetch is owed, and every poll 304s against user-a's ETag (the ETag carries no
    /// user). Re-stamping there kept user-a's body fresh forever, so offline launches kept applying
    /// it past `configOfflineMaxAge`. The stamp must stay at the last 200.
    func testA304AfterAnIdentifyWithAnUnknownOutcomeLeavesTheStamp() async throws {
        try await assertA304LeavesTheStamp(after: (.unknown, 1))
    }

    /// The row is known to hold another user than the body was fetched for. In the client this
    /// state also owes an unconditional refetch (`needsUnconditional`); this pins the label compare
    /// on its own.
    func testA304UnderAnotherKnownUserLeavesTheStamp() async throws {
        try await assertA304LeavesTheStamp(after: (.fetchedUnder("user-b"), 1))
    }

    /// 🔴 The most reachable shape: an identified launch sets the row's state to `.unknown` BEFORE
    /// its identify POST, and that POST does not move the epoch again (`ContextManager`), so the
    /// launch 200 is stored under the label `.unknown` with its ETag kept. If the POST commits
    /// without answering, label and current state are `.unknown` forever, and `.unknown == .unknown`
    /// must not count as a match.
    func testA304WithBothTheLabelAndTheRowUnknownLeavesTheStamp() async throws {
        let storage = InMemoryStorage()
        let clock = LockedBox(Self.launch)
        let freshness = ConfigFreshnessRecorder()
        let sync = makeSync(storage: storage, clock: clock, freshness: freshness,
                            identity: { (.unknown, 0) }, applied: LockedBox([]))
        AttributionCaptureProtocol.serveConfig(Self.body)
        await sync.refresh(deviceId: "device-1") // 200 stored under the label `.unknown`, ETag kept

        clock.set(Self.launch.addingTimeInterval(6 * 24 * Self.hour))
        await sync.refresh(deviceId: "device-1") // 304

        XCTAssertEqual(AttributionCaptureProtocol.configIfNoneMatch.last, #""v7""#, "precondition: a conditional fetch")
        let label = try storage.data(forKey: StorageKeys.sdkConfigFetchedUnder)
            .map { try JSONDecoder().decode(ServerHeldUser.self, from: $0) }
        XCTAssertEqual(label?.configIdentity, .unknown, "precondition: the body is labelled unknown")
        XCTAssertEqual(storage.string(forKey: StorageKeys.sdkConfigCachedAt), String(Self.launch.timeIntervalSince1970),
                       "a 304 freshened a body labelled for an unknown row")
        XCTAssertEqual(freshness.current?.fetchedAt, Self.launch)
    }

    /// A newer SDK's body with keys this one does not know still decodes, so it is applied, not
    /// deleted as unreadable.
    func testABodyWithUnknownExtraKeysIsAppliedNotDeleted() async throws {
        let storage = InMemoryStorage()
        try seed(storage, ageHours: 1, body: #"{"data":{"config_version":"9","etag":"\"v9\"","flags":{"native_home":true},"experiments":{},"added_later":{"x":1}},"meta":1}"#)
        let applied = LockedBox<[Applied]>([])
        await launch(makeSync(storage: storage, clock: LockedBox(Self.launch),
                              protocolClass: OfflineURLProtocol.self, applied: applied))

        XCTAssertEqual(applied.get().count, 1)
        XCTAssertNotNil(storage.data(forKey: StorageKeys.sdkConfig))
    }

    private func assertA304LeavesTheStamp(
        after moved: (identity: ConfigIdentity, epoch: UInt64),
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let storage = InMemoryStorage()
        let clock = LockedBox(Self.launch)
        let held = LockedBox<(identity: ConfigIdentity, epoch: UInt64)>((.fetchedUnder("user-a"), 0))
        let freshness = ConfigFreshnessRecorder()
        let sync = makeSync(storage: storage, clock: clock, freshness: freshness,
                            identity: { held.get() }, applied: LockedBox([]))
        AttributionCaptureProtocol.serveConfig(Self.body)
        await sync.refresh(deviceId: "device-1") // 200 for user-a, ETag "v7" held

        held.set(moved)
        clock.set(Self.launch.addingTimeInterval(6 * 24 * Self.hour))
        await sync.refresh(deviceId: "device-1") // 304 against user-a's "v7"

        XCTAssertEqual(AttributionCaptureProtocol.configIfNoneMatch.last, #""v7""#,
                       "precondition: the poll sent user-a's validator", file: file, line: line)
        XCTAssertEqual(storage.string(forKey: StorageKeys.sdkConfigCachedAt), String(Self.launch.timeIntervalSince1970),
                       "a 304 freshened a body the row is not known to hold", file: file, line: line)
        XCTAssertEqual(freshness.current?.fetchedAt, Self.launch, file: file, line: line)
    }

    func testAnUnreadableCachedBodyIsDeleted() async throws {
        let storage = InMemoryStorage()
        try seed(storage, ageHours: 1, body: "not json")
        let applied = LockedBox<[Applied]>([])
        await launch(makeSync(storage: storage, clock: LockedBox(Self.launch),
                              protocolClass: OfflineURLProtocol.self, applied: applied))

        XCTAssertTrue(applied.get().isEmpty)
        XCTAssertNil(storage.data(forKey: StorageKeys.sdkConfig), "a body that can never be applied stayed on disk")
    }

    func testANaNTimestampIsNotApplied() async throws {
        let storage = InMemoryStorage()
        try seed(storage, ageHours: nil)
        storage.set("nan", forKey: StorageKeys.sdkConfigCachedAt)
        let applied = LockedBox<[Applied]>([])
        await launch(makeSync(storage: storage, clock: LockedBox(Self.launch),
                              protocolClass: OfflineURLProtocol.self, applied: applied))

        XCTAssertTrue(applied.get().isEmpty)
        XCTAssertNil(storage.data(forKey: StorageKeys.sdkConfig))
    }

    func testA304AfterAResetWritesNoStamp() async throws {
        let storage = InMemoryStorage()
        let gate = ConfigResetGate()
        let freshness = ConfigFreshnessRecorder()
        let sync = makeSync(storage: storage, clock: LockedBox(Self.launch), gate: gate, freshness: freshness,
                            applied: LockedBox([]))
        AttributionCaptureProtocol.serveConfig(Self.body)
        await sync.refresh(deviceId: "device-1")
        AttributionCaptureProtocol.onConfigRequest = {
            gate.reset {
                storage.removeObject(forKey: StorageKeys.sdkConfig)
                storage.removeObject(forKey: StorageKeys.sdkConfigCachedAt)
                freshness.clear()
            }
        }
        await sync.refresh(deviceId: "device-1")
        AttributionCaptureProtocol.onConfigRequest = nil

        XCTAssertNil(storage.string(forKey: StorageKeys.sdkConfigCachedAt), "a 304 landing after reset() wrote a stamp")
        XCTAssertNil(freshness.current)
    }

    // MARK: - Pre-change behaviour by configuration

    /// `configOfflineMaxAge: 86_400` is 0.8.0: a 25-hour cache is deleted at launch.
    func testTheTwentyFourHourLimitOf080IsAvailableThroughConfiguration() async throws {
        let config = SheepitConfig(apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64),
                                   configOfflineMaxAge: 86_400)
        let limits = CachedConfigLimits(staleAfter: config.configStaleAfter, offlineMaxAge: config.configOfflineMaxAge)
        XCTAssertEqual(limits, CachedConfigLimits(staleAfter: 86_400, offlineMaxAge: 86_400))

        let storage = InMemoryStorage()
        try seed(storage, ageHours: 25)
        let applied = LockedBox<[Applied]>([])
        await launch(makeSync(storage: storage, clock: LockedBox(Self.launch), limits: limits,
                              protocolClass: OfflineURLProtocol.self, applied: applied))

        XCTAssertTrue(applied.get().isEmpty)
        XCTAssertNil(storage.data(forKey: StorageKeys.sdkConfig))
    }
}
