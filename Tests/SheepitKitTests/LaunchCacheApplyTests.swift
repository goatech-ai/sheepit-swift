import XCTest
@testable import SheepitKit

/// The launch cache is in memory before `create(config:)` returns, and nothing a failed fetch does
/// takes it away (SheepitKit 0.10.2, founder decision 2026-11-09).
///
/// 🔴 Why these exist: the pilot's app reaches Sheepit only inside its VPN. Off it, every launch
/// read every flag at its default. Two causes: the cache was applied from a `Task` after the client
/// was handed back, so a flag read on the next line raced it and an app that reads its flags once at
/// launch kept the defaults all session; and a cache older than 7 days was deleted at launch.
/// `CachedConfigAgeTests` drives `ConfigSync` directly and could see neither.
final class LaunchCacheApplyTests: XCTestCase {
    private static let hour: TimeInterval = 3600
    private static let body = #"""
    {"data":{"config_version":"7","etag":"\"v7\"","flags":{"native_home":true},"experiments":{
      "home_layout":{"variant_key":"native","payload":{},"experiment_id":"33333333-3333-4333-8333-333333333333","subject_kind":"device","bucketing_version":1,"assignment_revision":"7"}}}}
    """#

    override func setUp() {
        super.setUp()
        SharedSDKStorage.clear()
        TeardownFlushes.install()
        StatusURLProtocol.reset()
        AttributionCaptureProtocol.reset()
    }

    override func tearDown() async throws {
        await TeardownFlushes.drain(context: name)
        SharedSDKStorage.clear()
        StatusURLProtocol.reset()
        AttributionCaptureProtocol.reset()
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func seedCache(stampedAt stamp: Date) throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: SharedSDKStorage.suite))
        defaults.set(Data(Self.body.utf8), forKey: SharedSDKStorage.slot(StorageKeys.sdkConfig))
        defaults.set(String(stamp.timeIntervalSince1970), forKey: SharedSDKStorage.slot(StorageKeys.sdkConfigCachedAt))
    }

    private func cachedBodyOnDisk() throws -> Data? {
        try XCTUnwrap(UserDefaults(suiteName: SharedSDKStorage.suite)).data(forKey: SharedSDKStorage.slot(StorageKeys.sdkConfig))
    }

    private func makeConfig(diagnostics: DiagnosticCapture? = nil) -> SheepitConfig {
        SheepitConfig(
            apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64),
            apiUrl: "https://stub.invalid",
            flushInterval: 3600,
            configRefreshInterval: 3600,
            retryAttempts: 1,
            // Real crash handlers in the test process crash a later test with signal 11.
            crashes: CrashConfig(enabled: false),
            onDiagnostic: diagnostics.map { sink in { sink.append($0) } })
    }

    private func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { return false }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return true
    }

    // MARK: - Applied before create returns

    /// 🔴 The founder's case: `create(config:)` against a host that cannot be reached, and a flag read
    /// on the very next line, with no await, while the app's launch keeps every cooperative thread
    /// busy. Before 0.10.2 the cache was applied from a `Task`, which then could not run until the
    /// read was over: the flag read its default. On an idle machine that `Task` usually won the race,
    /// which is why no earlier test saw it.
    func testAFlagReadOnTheLineAfterCreateAnswersWithTheCache() throws {
        try seedCache(stampedAt: Date().addingTimeInterval(-3 * Self.hour))
        let diagnostics = DiagnosticCapture()
        let pool = CooperativePoolBlocker()
        let occupied = pool.occupyEveryThread()
        let client = SheepitClient.create(config: makeConfig(diagnostics: diagnostics))
        // Scheduler-independent half: the apply ran on THIS thread, before create returned.
        let appliedHere = diagnostics.events.first { $0.code == "config.launch_cache_applied" }?.thread
        let flag = client.flag("native_home", default: .bool(false))
        let variant = client.experiment("home_layout").variant
        let freshness = client.status().configFreshness
        pool.release()
        client.destroy()

        XCTAssertTrue(occupied, "precondition: every cooperative thread was occupied")
        XCTAssertEqual(appliedHere, Thread.current, "the launch cache was not applied on the caller's thread before create returned")
        XCTAssertEqual(flag, .bool(true), "the flag read its default, not the cached value")
        XCTAssertEqual(variant, "native", "the experiment arm was not applied")
        XCTAssertEqual(freshness?.source, .cache)
    }

    /// 30 days old, and every kind of failed fetch: a transport error, a 5xx and a 403. The cached
    /// values answer before create returns, stay after the fetch fails, and nothing is deleted.
    func testA30DayCacheSurvivesEveryFailedFetch() async throws {
        let launch = Date(timeIntervalSince1970: 1_800_000_000)
        let cases: [(String, AnyClass, Int)] = [
            ("network error", OfflineURLProtocol.self, 0),
            ("500", StatusURLProtocol.self, 500),
            ("403", StatusURLProtocol.self, 403),
        ]
        for entry in cases {
            let label = entry.0, status = entry.2
            let protocolClass: AnyClass = entry.1
            SharedSDKStorage.clear()
            StatusURLProtocol.reset()
            StatusURLProtocol.status = status
            try seedCache(stampedAt: launch.addingTimeInterval(-30 * 24 * Self.hour))
            let client = SheepitClient.createForTesting(config: makeConfig(), now: { launch },
                                                        urlProtocolClasses: [protocolClass])
            defer { client.destroy() }

            XCTAssertEqual(client.flag("native_home", default: .bool(false)), .bool(true), "\(label): before the fetch")
            // A whole fetch, failed and handled, before the assertions: no timing involved.
            await client.refreshConfigForTesting()
            if protocolClass == StatusURLProtocol.self {
                XCTAssertGreaterThan(StatusURLProtocol.configRequests, 0, "\(label): precondition: the fetch was answered")
            }

            XCTAssertEqual(client.flag("native_home", default: .bool(false)), .bool(true), "\(label): after the fetch")
            XCTAssertEqual(client.experiment("home_layout").variant, "native", label)
            XCTAssertEqual(try cachedBodyOnDisk(), Data(Self.body.utf8), "\(label): the cache was deleted")
            let freshness = try XCTUnwrap(client.status().configFreshness, label)
            XCTAssertEqual(freshness.source, .cache, label)
            XCTAssertTrue(freshness.isStale, label)
        }
    }

    /// A finite limit the host sets is still honoured through the client: deleted before create
    /// returns, and reported with its reason.
    func testAHostSetOfflineLimitStillDeletesAnOlderCache() throws {
        let launch = Date(timeIntervalSince1970: 1_800_000_000)
        try seedCache(stampedAt: launch.addingTimeInterval(-8 * 24 * Self.hour))
        let diagnostics = DiagnosticCapture()
        var config = makeConfig(diagnostics: diagnostics)
        config.configOfflineMaxAge = 7 * 24 * Self.hour
        let client = SheepitClient.createForTesting(config: config, now: { launch },
                                                    urlProtocolClasses: [OfflineURLProtocol.self])
        defer { client.destroy() }

        XCTAssertEqual(client.flag("native_home", default: .bool(false)), .bool(false))
        XCTAssertNil(try cachedBodyOnDisk(), "a cache past the host's limit was kept")
        let dropped = try XCTUnwrap(diagnostics.events.first { $0.code == "config.launch_cache_dropped" })
        XCTAssertEqual(dropped.data?["reason"]?.value as? String, "past_max_age")
        XCTAssertEqual(dropped.data?["offline_max_age_s"]?.value as? Double, 604_800)
    }

    /// 🔴 A finite limit larger than `Int.max` (`.greatestFiniteMagnitude` passes validation) must
    /// not trap on any drop path: `Int(limit)` in the drop diagnostic crashed `create()`.
    func testAHugeFiniteOfflineLimitDoesNotTrapOnADrop() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: SharedSDKStorage.suite))
        defaults.set(Data(Self.body.utf8), forKey: SharedSDKStorage.slot(StorageKeys.sdkConfig))
        let diagnostics = DiagnosticCapture()
        var config = makeConfig(diagnostics: diagnostics)
        config.configOfflineMaxAge = .greatestFiniteMagnitude
        let client = SheepitClient.createForTesting(config: config, now: { Date() }, urlProtocolClasses: [OfflineURLProtocol.self])
        defer { client.destroy() }

        let dropped = try XCTUnwrap(diagnostics.events.first { $0.code == "config.launch_cache_dropped" })
        XCTAssertEqual(dropped.data?["reason"]?.value as? String, "unstamped")
        XCTAssertEqual(dropped.data?["offline_max_age_s"]?.value as? Double, .greatestFiniteMagnitude)
    }

    /// Bug-fix observability: a launch on an old cache says how old, so a device running for weeks on
    /// one is visible to the host's `onDiagnostic`.
    func testALaunchOnAnOldCacheIsReportedWithItsAge() throws {
        let launch = Date(timeIntervalSince1970: 1_800_000_000)
        try seedCache(stampedAt: launch.addingTimeInterval(-30 * 24 * Self.hour))
        let diagnostics = DiagnosticCapture()
        let client = SheepitClient.createForTesting(config: makeConfig(diagnostics: diagnostics), now: { launch },
                                                    urlProtocolClasses: [OfflineURLProtocol.self])
        defer { client.destroy() }

        let applied = try XCTUnwrap(diagnostics.events.first { $0.code == "config.launch_cache_applied" },
                                    "the launch apply was not reported")
        XCTAssertEqual(applied.severity, .info)
        // 30 days in ms is past `Int32.max`: a 32-bit `Int` (watchOS arm64_32) saturates.
        XCTAssertEqual((applied.data?["config_age_ms"]?.value as? Int).map(Int64.init),
                       min(30 * 24 * 3_600_000, Int64(Int.max)))
        XCTAssertEqual(applied.data?["stale"]?.value as? Bool, true)
        XCTAssertEqual(applied.data?["age_unknown"]?.value as? Bool, false)
        XCTAssertEqual(applied.data?["config_version"]?.value as? String, "7")
    }

    /// 🔴 watchOS is arm64_32: `Int` is 32-bit, so `Int(age * 1000)` trapped inside `create()` for a
    /// cache older than ~24.8 days, which 0.10.2 now applies. The host here is 64-bit, so the age is
    /// pushed past `Int64` too: the same unchecked conversion traps, the saturating one reports
    /// `Int.max`, and the launch completes.
    func testALaunchOnAnAbsurdlyOldCacheDoesNotTrap() throws {
        let launch = Date(timeIntervalSince1970: 1e17)
        try seedCache(stampedAt: Date(timeIntervalSince1970: 1_000))
        let diagnostics = DiagnosticCapture()
        let client = SheepitClient.createForTesting(config: makeConfig(diagnostics: diagnostics), now: { launch },
                                                    urlProtocolClasses: [OfflineURLProtocol.self])
        defer { client.destroy() }

        XCTAssertEqual(client.flag("native_home", default: .bool(false)), .bool(true), "the cache was not applied")
        let applied = try XCTUnwrap(diagnostics.events.first { $0.code == "config.launch_cache_applied" })
        XCTAssertEqual(applied.data?["config_age_ms"]?.value as? Int, Int.max)
    }

    func testTheSaturatingConversionNeverTraps() {
        XCTAssertEqual(Int(saturating: 1e20), .max)
        XCTAssertEqual(Int(saturating: -1e20), .min)
        XCTAssertEqual(Int(saturating: .infinity), .max)
        XCTAssertEqual(Int(saturating: -.infinity), .min)
        XCTAssertEqual(Int(saturating: .nan), 0)
        XCTAssertEqual(Int(saturating: Double(Int.max)), .max)
        // Past `Int32.max`: truncated on a 64-bit `Int`, saturated on a 32-bit one.
        XCTAssertEqual(Int64(Int(saturating: 2_592_000_000.7)), min(2_592_000_000, Int64(Int.max)))
        XCTAssertEqual(Int(saturating: 2_000_000_000.7), 2_000_000_000)
    }

    /// A stamp later than the device clock is applied under the default, reported stale, with no age.
    func testAFutureDatedCacheIsAppliedAndReportedStaleThroughTheClient() throws {
        let launch = Date(timeIntervalSince1970: 1_800_000_000)
        try seedCache(stampedAt: launch.addingTimeInterval(5 * Self.hour))
        let diagnostics = DiagnosticCapture()
        let client = SheepitClient.createForTesting(config: makeConfig(diagnostics: diagnostics), now: { launch },
                                                    urlProtocolClasses: [OfflineURLProtocol.self])
        defer { client.destroy() }

        XCTAssertEqual(client.flag("native_home", default: .bool(false)), .bool(true))
        let freshness = try XCTUnwrap(client.status().configFreshness)
        XCTAssertTrue(freshness.isStale)
        let applied = try XCTUnwrap(diagnostics.events.first { $0.code == "config.launch_cache_applied" })
        XCTAssertEqual(applied.data?["age_unknown"]?.value as? Bool, true)
        XCTAssertNil(applied.data?["config_age_ms"])
    }

    /// An exposure under a cache of unknown age carries `config_source` and NO `config_age_ms`:
    /// its clamped age reads 0, which an analysis would take for a config fetched that instant.
    func testAnExposureUnderAFutureDatedCacheCarriesNoAge() async throws {
        let launch = Date(timeIntervalSince1970: 1_800_000_000)
        try seedCache(stampedAt: launch.addingTimeInterval(5 * Self.hour))
        // (config_source, whether config_age_ms was present) of the first `$flag_exposure`.
        let sent = LockedBox<(String?, Bool)?>(nil)
        var config = makeConfig()
        config.onEvent = { name, properties in
            guard name == "$flag_exposure", sent.get() == nil else { return }
            sent.set((properties?["config_source"] as? String, properties?["config_age_ms"] != nil))
        }
        let client = SheepitClient.createForTesting(config: config, now: { launch },
                                                    urlProtocolClasses: [OfflineURLProtocol.self])
        defer { client.destroy() }

        XCTAssertEqual(client.flag("native_home", default: .bool(false)), .bool(true), "precondition")
        let arrived = await waitUntil { sent.get() != nil }
        XCTAssertTrue(arrived, "no $flag_exposure was sent")
        XCTAssertEqual(sent.get()?.0, "cache")
        XCTAssertEqual(sent.get()?.1, false, "an unknown age was sent as a number")
    }

    /// `reset()` right after create still clears synchronously what the launch applied.
    func testResetAfterTheLaunchApplyClearsItSynchronously() throws {
        try seedCache(stampedAt: Date().addingTimeInterval(-Self.hour))
        let client = SheepitClient.create(config: makeConfig())
        defer { client.destroy() }
        XCTAssertEqual(client.flag("native_home", default: .bool(false)), .bool(true), "precondition")

        client.reset()

        XCTAssertEqual(client.flag("native_home", default: .bool(false)), .bool(false))
        XCTAssertNil(client.status().configFreshness)
        XCTAssertNil(try cachedBodyOnDisk())
    }

    // MARK: - Another user

    /// 🔴 With no age limit the cache must not outlive the user it was evaluated for: identify() from
    /// one known user to another deletes the persisted copy (memory keeps answering until the new
    /// user's refetch), so an offline relaunch reads defaults, not the previous user's flags.
    func testIdentifyingAnotherKnownUserDropsThePersistedCacheOnly() throws {
        let launch = Date(timeIntervalSince1970: 1_800_000_000)
        try seedCache(stampedAt: launch.addingTimeInterval(-30 * 24 * Self.hour))
        let first = SheepitClient.createForTesting(config: makeConfig(), now: { launch },
                                                   urlProtocolClasses: [OfflineURLProtocol.self])
        first.identify(userId: "user-a")
        XCTAssertNotNil(try cachedBodyOnDisk(), "anonymous to known must keep the cache")
        XCTAssertFalse(first.configPersistHeldForTesting, "anonymous to known held the disk writes")
        first.identify(userId: "user-a")
        XCTAssertFalse(first.configPersistHeldForTesting, "the same user held the disk writes")
        XCTAssertNotNil(try cachedBodyOnDisk(), "the same user dropped the cache")

        // 🔴 Gone by the time the new user is persisted: a process killed between the two would
        // otherwise relaunch as user B over user A's body.
        let onDiskWhenUserSet = LockedBox<Bool?>(nil)
        first.identifyUserIdSetHookForTesting.value = { [weak self] _ in
            onDiskWhenUserSet.set((try? self?.cachedBodyOnDisk()) != nil)
        }
        first.identify(userId: "user-b")
        first.identifyUserIdSetHookForTesting.value = nil
        XCTAssertEqual(onDiskWhenUserSet.get(), false, "the new user was persisted with the previous user's config still on disk")
        XCTAssertNil(try cachedBodyOnDisk(), "the previous user's config stayed on disk")
        XCTAssertTrue(first.configPersistHeldForTesting, "a known-to-known identify did not hold the disk writes")
        XCTAssertEqual(first.flag("native_home", default: .bool(false)), .bool(true),
                       "memory must keep answering until the new user's config lands")
        first.destroy()

        let relaunched = SheepitClient.createForTesting(config: makeConfig(), now: { launch },
                                                        urlProtocolClasses: [OfflineURLProtocol.self])
        defer { relaunched.destroy() }
        XCTAssertEqual(relaunched.flag("native_home", default: .bool(false)), .bool(false),
                       "an offline relaunch applied user A's flags to user B")
    }

    // MARK: - ConfigSync bookkeeping

    private static let newerBody = #"{"data":{"config_version":"8","etag":"\"v8\"","flags":{"native_home":false},"experiments":{}}}"#

    private func makeSync(
        storage: StorageProvider,
        gate: ConfigResetGate = ConfigResetGate(),
        clock: LockedBox<Date> = LockedBox(Date()),
        freshness: ConfigFreshnessRecorder = ConfigFreshnessRecorder(),
        identity: @escaping @Sendable () -> (identity: ConfigIdentity, epoch: UInt64) = { (.fetchedUnder(nil), 0) },
        currentDeviceId: (@Sendable () -> String)? = nil,
        applied: LockedBox<Int>
    ) -> ConfigSync {
        ConfigSync(
            http: HTTPClient(
                config: SheepitConfig(apiKey: "lp_pub_tst_" + String(repeating: "a", count: 64),
                                      apiUrl: "https://stub.invalid", retryAttempts: 1),
                log: Logger(debug: false),
                urlProtocolClasses: [AttributionCaptureProtocol.self]),
            storage: storage,
            refreshInterval: 3600,
            log: Logger(debug: false),
            resetGate: gate,
            now: { clock.get() },
            freshness: freshness,
            identityProvider: identity,
            currentDeviceId: currentDeviceId,
            onConfig: { _, _, _ in applied.mutate { $0 += 1 } }
        )
    }

    /// A server body applied first takes the launch slot: a launch apply after it must not put the
    /// cache back over it, whatever is on disk by then.
    func testALaunchApplyAfterAServerBodyAppliesNothing() async throws {
        let storage = InMemoryStorage()
        let applied = LockedBox(0)
        let sync = makeSync(storage: storage, applied: applied)
        AttributionCaptureProtocol.serveConfig(Self.body)
        await sync.refresh(deviceId: "device-1")
        XCTAssertEqual(applied.get(), 1, "precondition: the server body was applied")
        XCTAssertNotNil(storage.data(forKey: StorageKeys.sdkConfig), "precondition: and cached")

        sync.applyLaunchCache(deviceId: "device-1")

        XCTAssertEqual(applied.get(), 1, "the launch cache was applied over a newer server body")
    }

    /// The launch apply runs once: `ConfigSync.start()` after `SheepitClient.start()` applied it is a
    /// no-op, so `onConfig` / `onApplied` fire once.
    func testTheLaunchApplyRunsOnce() async throws {
        let storage = InMemoryStorage()
        storage.set(Data(Self.body.utf8), forKey: StorageKeys.sdkConfig)
        storage.set(String(Date().timeIntervalSince1970), forKey: StorageKeys.sdkConfigCachedAt)
        let applied = LockedBox(0)
        let sync = makeSync(storage: storage, applied: applied)

        sync.applyLaunchCache(deviceId: "device-1")
        XCTAssertEqual(applied.get(), 1)
        await sync.start(deviceIdGetter: { "device-1" })
        await sync.stop()

        XCTAssertEqual(applied.get(), 1, "the launch cache was applied twice")
    }

    /// The device check never blocks the CURRENT device: after a swap, a fetch for the fresh id is
    /// written with its stamp; only an answer for the id the client left is discarded.
    func testAfterASwapTheFreshDevicesBodyIsPersistedAndTheLeftOnesIsNot() async throws {
        let storage = InMemoryStorage()
        let current = LockedBox("device-1")
        let applied = LockedBox(0)
        let sync = makeSync(storage: storage, currentDeviceId: { current.get() }, applied: applied)
        AttributionCaptureProtocol.configResolution = { _, _ in "resolved" }
        AttributionCaptureProtocol.honorIfNoneMatch = false
        AttributionCaptureProtocol.serveConfig(Self.body)

        current.set("device-2")
        await sync.refresh(deviceId: "device-1")
        XCTAssertEqual(applied.get(), 0, "a body for the device the client left was applied")
        XCTAssertNil(storage.data(forKey: StorageKeys.sdkConfig), "a body for the device the client left was written")

        await sync.refresh(deviceId: "device-2")
        XCTAssertEqual(applied.get(), 1, "the current device's body was not applied")
        XCTAssertNotNil(storage.data(forKey: StorageKeys.sdkConfig), "the current device's body was not written")
        XCTAssertEqual(storage.string(forKey: StorageKeys.sdkConfigResolvedFor), "device-2")
    }

    /// A response already on the wire when identify() moved to another user is applied to memory
    /// only: written to disk, it would put the previous user's body back after the drop.
    func testAResponseInFlightAcrossAUserChangeIsNotPersisted() async throws {
        let storage = InMemoryStorage()
        storage.set(Data(Self.body.utf8), forKey: StorageKeys.sdkConfig)
        storage.set(String(Date().timeIntervalSince1970), forKey: StorageKeys.sdkConfigCachedAt)
        let epoch = LockedBox<UInt64>(0)
        let applied = LockedBox(0)
        let sync = makeSync(storage: storage, identity: { (.fetchedUnder("user-a"), epoch.get()) }, applied: applied)
        AttributionCaptureProtocol.serveConfig(Self.body)
        AttributionCaptureProtocol.onConfigRequest = {
            // What `dispatchIdentify` does for user-a -> user-b, while the request is on the wire.
            epoch.set(1)
            sync.dropPersistedCacheForUserChange(newUserId: "user-b")
        }
        await sync.refresh(deviceId: "device-1")
        AttributionCaptureProtocol.onConfigRequest = nil

        XCTAssertEqual(applied.get(), 1, "precondition: the body was applied to memory")
        XCTAssertNil(storage.data(forKey: StorageKeys.sdkConfig), "the previous user's body was written back to disk")
    }

    /// The drop runs BEFORE the identify moves the epoch (it precedes `setUserId`), so a response
    /// landing in between still reads the previous user's label, with the epoch unchanged. Only
    /// the new user's label is written: the body stays in memory only.
    func testAResponseLandingBeforeTheEpochMovesIsNotPersistedEither() async throws {
        let storage = InMemoryStorage()
        let applied = LockedBox(0)
        let sync = makeSync(storage: storage, identity: { (.fetchedUnder("user-a"), 0) }, applied: applied)
        AttributionCaptureProtocol.serveConfig(Self.body)
        AttributionCaptureProtocol.onConfigRequest = {
            sync.dropPersistedCacheForUserChange(newUserId: "user-b")
        }
        await sync.refresh(deviceId: "device-1")
        AttributionCaptureProtocol.onConfigRequest = nil

        XCTAssertEqual(applied.get(), 1, "precondition: the body was applied to memory")
        XCTAssertNil(storage.data(forKey: StorageKeys.sdkConfig), "the previous user's body was written back before the epoch moved")
    }

    /// 🔴 Round-2 BLOCKER 1. `ServerHeldUser` labels the server ROW, which can hold a THIRD user:
    /// identify("C") with a slow POST, then identify("A"); C's POST answers, so the row reads
    /// `.known("C")` and a refetch starts labelled C. Then identify("B"): the hold is taken, and C's
    /// response lands before the epoch moves. The old deny-list refused only the app's previous
    /// user (A), so C's body was written, and every offline relaunch as B applied it for good.
    func testAThirdUsersBodyLandingAfterAUserChangeIsNotPersisted() async throws {
        let storage = InMemoryStorage()
        let applied = LockedBox(0)
        let sync = makeSync(storage: storage, identity: { (.fetchedUnder("user-c"), 0) }, applied: applied)
        AttributionCaptureProtocol.serveConfig(Self.body)
        AttributionCaptureProtocol.onConfigRequest = {
            // identify("B") while the app's user is A: the drop runs before the epoch moves.
            sync.dropPersistedCacheForUserChange(newUserId: "user-b")
        }
        await sync.refresh(deviceId: "device-1")
        AttributionCaptureProtocol.onConfigRequest = nil

        XCTAssertEqual(applied.get(), 1, "precondition: the body was applied to memory")
        XCTAssertNil(storage.data(forKey: StorageKeys.sdkConfig), "a third user's body was persisted for the new user")
        XCTAssertNil(storage.string(forKey: StorageKeys.sdkConfigResolvedFor), "its C5 stamp was persisted")
        XCTAssertTrue(sync.persistHeldForTesting, "the third user's body ended the hold")
    }

    /// A held body writes neither the body nor its C5 stamp, so the two on disk always describe the
    /// same response. The in-memory C5 record is NOT held: a later `unknown_device` still fires C5.
    func testAHeldResolvedBodyWritesNoStampButStillArmsC5() async throws {
        let storage = InMemoryStorage()
        let applied = LockedBox(0)
        let sync = makeSync(storage: storage, identity: { (.unknown, 0) }, applied: applied)
        let fired = LockedBox<[String]>([])
        sync.onResolvedDeviceUnknown.value = { deviceId, _ in
            fired.mutate { $0.append(deviceId) }
            return .notCurrent
        }
        storage.set("device-1", forKey: StorageKeys.sdkConfigResolvedFor)
        sync.dropPersistedCacheForUserChange(newUserId: "user-b")
        XCTAssertNil(storage.string(forKey: StorageKeys.sdkConfigResolvedFor), "the drop left the stamp")
        let resolution = LockedBox("resolved")
        AttributionCaptureProtocol.configResolution = { _, _ in resolution.get() }
        AttributionCaptureProtocol.honorIfNoneMatch = false
        AttributionCaptureProtocol.serveConfig(Self.body)

        await sync.refresh(deviceId: "device-1")
        XCTAssertEqual(applied.get(), 1, "precondition: the resolved body was applied to memory")
        XCTAssertNil(storage.data(forKey: StorageKeys.sdkConfig), "precondition: and held off the disk")
        XCTAssertNil(storage.string(forKey: StorageKeys.sdkConfigResolvedFor), "a held body wrote its C5 stamp")

        resolution.set("unknown_device")
        await sync.refresh(deviceId: "device-1")
        XCTAssertEqual(fired.get(), ["device-1"], "the persist hold disarmed C5 in memory")
    }

    /// After a user change the row may still hold the previous user until the new user's POST
    /// commits: a body fetched while it is unknown stays off the disk; the first body fetched for a
    /// known row is written and ends the hold.
    func testAfterAUserChangeOnlyABodyForAKnownRowIsPersisted() async throws {
        let storage = InMemoryStorage()
        let identity = LockedBox<ConfigIdentity>(.unknown)
        let applied = LockedBox(0)
        let sync = makeSync(storage: storage, identity: { (identity.get(), 0) }, applied: applied)
        sync.dropPersistedCacheForUserChange(newUserId: "user-b")
        AttributionCaptureProtocol.serveConfig(Self.body)
        AttributionCaptureProtocol.honorIfNoneMatch = false

        await sync.refresh(deviceId: "device-1")
        XCTAssertEqual(applied.get(), 1, "precondition: applied to memory")
        XCTAssertNil(storage.data(forKey: StorageKeys.sdkConfig), "a body for an unknown row was persisted after a user change")

        identity.set(.fetchedUnder(nil))
        await sync.refresh(deviceId: "device-1")
        XCTAssertNil(storage.data(forKey: StorageKeys.sdkConfig), "a body for an anonymous row was persisted for the new user")

        identity.set(.fetchedUnder("user-b"))
        await sync.refresh(deviceId: "device-1")
        XCTAssertNotNil(storage.data(forKey: StorageKeys.sdkConfig), "the new user's confirmed body was not persisted")
        XCTAssertFalse(sync.persistHeldForTesting, "the new user's body did not end the hold")

        identity.set(.unknown)
        storage.removeObject(forKey: StorageKeys.sdkConfig)
        await sync.refresh(deviceId: "device-1")
        XCTAssertNotNil(storage.data(forKey: StorageKeys.sdkConfig), "the hold outlived the confirmed body")
    }

    /// An unresolved answer to an OLDER request, landing after a newer resolved body was applied,
    /// says nothing about the device now: it must not switch the 304 re-stamp off for the process.
    func testAStaleUnresolvedAnswerDoesNotLatchTheRestampOff() async throws {
        let storage = InMemoryStorage()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = LockedBox(start)
        let applied = LockedBox(0)
        let sync = makeSync(storage: storage, clock: clock, applied: applied)
        // The first request to arrive is answered unresolved, slowly; the second resolved, at once.
        AttributionCaptureProtocol.configResolution = { _, _ in
            AttributionCaptureProtocol.configRequestCount == 1 ? "unknown_device" : "resolved"
        }
        AttributionCaptureProtocol.scriptConfig([(Self.body, 0.4), (Self.body, 0)])
        AttributionCaptureProtocol.serveConfig(Self.body)
        async let older: Void = sync.refresh(deviceId: "device-1")
        let firstArrived = await waitUntil { AttributionCaptureProtocol.configRequestCount >= 1 }
        XCTAssertTrue(firstArrived, "precondition: the older request reached the server first")
        await sync.refresh(deviceId: "device-1")
        await older
        XCTAssertEqual(applied.get(), 1, "precondition: only the newer, resolved body was applied")

        clock.set(start.addingTimeInterval(10 * Self.hour))
        await sync.refresh(deviceId: "device-1")
        XCTAssertEqual(AttributionCaptureProtocol.configIfNoneMatch.last ?? nil, #""v7""#, "precondition: a conditional request")

        XCTAssertEqual(storage.string(forKey: StorageKeys.sdkConfigCachedAt), String(clock.get().timeIntervalSince1970),
                       "a stale unresolved answer stopped the 304 from confirming the cache")
    }

    /// The server answers 304 before it looks the device up, so once a 2xx said the device is
    /// unresolved, a 304 confirms nothing: re-stamping would keep a body the server can no longer
    /// evaluate for this device reported fresh, with no age limit to end it.
    func testA304AfterAnUnresolvedAnswerDoesNotRestampTheCache() async throws {
        let storage = InMemoryStorage()
        let clock = LockedBox(Date(timeIntervalSince1970: 1_800_000_000))
        let freshness = ConfigFreshnessRecorder()
        let applied = LockedBox(0)
        let sync = makeSync(storage: storage, clock: clock, freshness: freshness, applied: applied)
        let resolution = LockedBox("resolved")
        AttributionCaptureProtocol.configResolution = { _, _ in resolution.get() }
        AttributionCaptureProtocol.serveConfig(Self.body)
        await sync.refresh(deviceId: "device-1")
        let stamp = storage.string(forKey: StorageKeys.sdkConfigCachedAt)
        XCTAssertEqual(applied.get(), 1, "precondition: a resolved body was applied")

        // The row is gone: a changed body answers unresolved and is refused.
        resolution.set("unknown_device")
        AttributionCaptureProtocol.serveConfig(Self.newerBody)
        await sync.refresh(deviceId: "device-1")
        XCTAssertEqual(applied.get(), 1, "precondition: the unresolved body was refused")

        // The validator matches again: 304, ten hours later.
        AttributionCaptureProtocol.serveConfig(Self.body)
        clock.set(clock.get().addingTimeInterval(10 * Self.hour))
        await sync.refresh(deviceId: "device-1")
        XCTAssertEqual(AttributionCaptureProtocol.configIfNoneMatch.last ?? nil, #""v7""#, "precondition: a conditional request")

        XCTAssertEqual(storage.string(forKey: StorageKeys.sdkConfigCachedAt), stamp,
                       "a 304 re-stamped a cache the server answered unresolved for")
        XCTAssertEqual(freshness.current?.fetchedAt, Date(timeIntervalSince1970: 1_800_000_000))
    }

    /// An unresolved answer refused over the applied body leaves that body applied, and reported
    /// stale: it can no longer be evaluated for this device. The next applied body clears it.
    /// (sdk-js reports the same in `status()`, but not for `lookup_error`, and also sends it as the
    /// `config_stale` exposure property, which SheepitKit does not.)
    func testARefusedUnresolvedAnswerReportsTheKeptBodyStale() async throws {
        let storage = InMemoryStorage()
        let clock = LockedBox(Date(timeIntervalSince1970: 1_800_000_000))
        let freshness = ConfigFreshnessRecorder()
        let applied = LockedBox(0)
        let sync = makeSync(storage: storage, clock: clock, freshness: freshness, applied: applied)
        let resolution = LockedBox("resolved")
        AttributionCaptureProtocol.configResolution = { _, _ in resolution.get() }
        AttributionCaptureProtocol.honorIfNoneMatch = false
        AttributionCaptureProtocol.serveConfig(Self.body)
        await sync.refresh(deviceId: "device-1")
        XCTAssertEqual(freshness.snapshot(now: clock.get(), staleAfter: 86_400)?.isStale, false, "precondition")

        resolution.set("unknown_device")
        await sync.refresh(deviceId: "device-1")
        XCTAssertEqual(applied.get(), 1, "precondition: the unresolved body was refused")
        XCTAssertEqual(freshness.snapshot(now: clock.get(), staleAfter: 86_400)?.isStale, true,
                       "a body the server can no longer evaluate for this device was reported fresh")

        resolution.set("resolved")
        await sync.refresh(deviceId: "device-1")
        XCTAssertEqual(freshness.snapshot(now: clock.get(), staleAfter: 86_400)?.isStale, false,
                       "a newly applied body was still reported stale")
    }

    /// The stale mark needs no body: an unresolved 2xx that fails to decode still says the server
    /// can no longer evaluate the applied body for this device.
    func testAnUndecodableUnresolvedAnswerStillReportsTheKeptBodyStale() async throws {
        let storage = InMemoryStorage()
        let clock = LockedBox(Date(timeIntervalSince1970: 1_800_000_000))
        let freshness = ConfigFreshnessRecorder()
        let applied = LockedBox(0)
        let sync = makeSync(storage: storage, clock: clock, freshness: freshness, applied: applied)
        let resolution = LockedBox("resolved")
        AttributionCaptureProtocol.configResolution = { _, _ in resolution.get() }
        AttributionCaptureProtocol.honorIfNoneMatch = false
        AttributionCaptureProtocol.serveConfig(Self.body)
        await sync.refresh(deviceId: "device-1")
        XCTAssertEqual(freshness.snapshot(now: clock.get(), staleAfter: 86_400)?.isStale, false, "precondition")

        resolution.set("unknown_device")
        AttributionCaptureProtocol.serveConfig(#"{"data":{"flags":"not a config"}}"#)
        await sync.refresh(deviceId: "device-1")
        XCTAssertEqual(applied.get(), 1, "precondition: nothing else was applied")
        XCTAssertEqual(freshness.snapshot(now: clock.get(), staleAfter: 86_400)?.isStale, true,
                       "an undecodable unresolved answer left the kept body reported fresh")
    }
}

/// Keeps the threads of Swift's cooperative pool blocked until `release()`, as a busy app launch
/// does, so a `Task` created meanwhile cannot start. Called from a synchronous test, which runs on
/// the main thread.
///
/// The pool is as wide as the active cores. The blockers run at high priority, which a `Task`
/// created on the main thread inherits: blockers at the default priority leave it room to run.
/// `occupyEveryThread()` waits a bounded time and says whether every blocker started.
final class CooperativePoolBlocker: @unchecked Sendable {
    private let started = DispatchSemaphore(value: 0)
    private let gate = DispatchSemaphore(value: 0)
    private let width = ProcessInfo.processInfo.activeProcessorCount
    private var launched = 0

    func occupyEveryThread() -> Bool {
        for _ in 0..<width {
            Task.detached(priority: .high) { [started, gate] in Self.hold(started: started, gate: gate) }
            launched += 1
        }
        for _ in 0..<launched where started.wait(timeout: .now() + 5) == .timedOut {
            return false
        }
        return true
    }

    func release() {
        for _ in 0..<launched { gate.signal() }
    }

    private static func hold(started: DispatchSemaphore, gate: DispatchSemaphore) {
        started.signal()
        gate.wait()
    }
}

/// Collects diagnostics from `onDiagnostic`, which runs on the emitting thread.
final class DiagnosticCapture: @unchecked Sendable {
    private let lock = NSLock()
    struct Captured {
        let code: String
        let severity: DiagnosticSeverity
        let data: [String: AnyCodable]?
        /// The thread `onDiagnostic` ran on, which is the emitting thread.
        let thread: Thread
    }

    private var stored: [Captured] = []

    func append(_ event: DiagnosticEvent) {
        lock.lock(); defer { lock.unlock() }
        stored.append(Captured(code: event.code, severity: event.severity, data: event.data, thread: Thread.current))
    }

    var events: [Captured] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

/// Answers every request with `status` and an empty body, counting `/v1/config` requests.
final class StatusURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _status = 500
    nonisolated(unsafe) private static var _configRequests = 0

    static var status: Int {
        get { lock.lock(); defer { lock.unlock() }; return _status }
        set { lock.lock(); _status = newValue; lock.unlock() }
    }

    static var configRequests: Int {
        lock.lock(); defer { lock.unlock() }
        return _configRequests
    }

    static func reset() {
        lock.lock(); defer { lock.unlock() }
        _status = 500
        _configRequests = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url else { return }
        if url.path.hasSuffix("/v1/config") {
            Self.lock.lock()
            Self._configRequests += 1
            Self.lock.unlock()
        }
        let response = HTTPURLResponse(url: url, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil)
        if let response { client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed) }
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
