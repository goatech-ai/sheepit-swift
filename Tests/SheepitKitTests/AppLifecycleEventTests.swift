import XCTest
@testable import SheepitKit

/// Coverage for `$app_install` / `$app_update` — DEVICE_CONTEXT_AND_AUDIENCE_ANALYTICS.md
/// § 8, decision 7.
///
/// Two layers, deliberately: `AppLifecycleEventDecider` is pure and tested directly so the
/// decision logic itself is verified independent of whether the XCTest host bundle happens
/// to carry a `CFBundleShortVersionString` (it may or may not — see
/// `CrashContextDeviceProfileTests.swift`'s own comment). The end-to-end `SheepitClient`
/// tests below exercise the real wiring and are guarded with `XCTSkipIf` for the same
/// reason.
final class AppLifecycleEventDeciderTests: XCTestCase {
    func testAFreshInstallEmitsInstall() {
        XCTAssertEqual(
            AppLifecycleEventDecider.decide(storedVersion: nil, currentVersion: "1.0", didMintDeviceId: true),
            .install
        )
    }

    /// The regression that actually bites customers (decision 7): an EXISTING install —
    /// one that already had a device id before this launch — must not report a fake
    /// install the day it upgrades to a version of the SDK that ships this feature.
    func testAnExistingInstallUpgradingSuppressesInstall() {
        XCTAssertEqual(
            AppLifecycleEventDecider.decide(storedVersion: nil, currentVersion: "1.0", didMintDeviceId: false),
            .none,
            "an install with no version marker yet but a PRE-EXISTING device id must not " +
            "report $app_install — it is upgrading, not installing"
        )
    }

    func testAVersionChangeEmitsUpdate() {
        XCTAssertEqual(
            AppLifecycleEventDecider.decide(storedVersion: "1.0", currentVersion: "1.1", didMintDeviceId: false),
            .update(previousVersion: "1.0", currentVersion: "1.1")
        )
    }

    func testTheSameVersionEmitsNothing() {
        XCTAssertEqual(
            AppLifecycleEventDecider.decide(storedVersion: "1.0", currentVersion: "1.0", didMintDeviceId: false),
            .none
        )
    }

    /// A marker already present means SOME launch has already run this bookkeeping, so it
    /// can never be a fresh install regardless of `didMintDeviceId` — covers the
    /// (unreachable in practice, but not type-excluded) case where a marker survives
    /// without a device id.
    func testAStoredMarkerWinsOverDidMintDeviceIdEvenIfTrue() {
        XCTAssertEqual(
            AppLifecycleEventDecider.decide(storedVersion: "1.0", currentVersion: "1.0", didMintDeviceId: true),
            .none
        )
    }
}

/// End-to-end wiring through a real `SheepitClient`. Must control `StorageKeys.deviceId`
/// and `StorageKeys.installedAppVersion` directly in the REAL `ai.goatech.sdk` suite —
/// `SheepitClient` hardcodes that suite, never `InMemoryStorage` — the same pattern
/// `BeginWorkDiskAndDestroyRaceTests` and `IsFirstSessionPropertyTests` use.
final class AppInstallAndUpdateEmissionTests: XCTestCase {
    private let suiteName = "ai.goatech.sdk"

    private func restoring(_ key: String, to value: String?, _ body: () -> Void) {
        let defaults = UserDefaults(suiteName: suiteName)!
        let original = defaults.string(forKey: key)
        defer {
            if let original {
                defaults.set(original, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        body()
    }

    private func makeClient(_ recorder: EventLifecycleRecorder, appVersion: String? = nil) -> SheepitClient {
        SheepitClient.create(
            config: SheepitConfig(
                apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))",
                apiUrl: "https://stub.invalid",
                onEvent: { name, props in recorder.record(name, props) },
                crashes: CrashConfig(enabled: false),
                appVersion: appVersion
            )
        )
    }

    func testAFreshInstallEmitsAppInstallEndToEnd() throws {
        try XCTSkipIf(DeviceProfile.appVersion() == nil, "no CFBundleShortVersionString in this XCTest host")
        let defaults = UserDefaults(suiteName: suiteName)!
        let originalDeviceId = defaults.string(forKey: StorageKeys.deviceId)
        let originalMarker = defaults.string(forKey: StorageKeys.installedAppVersion)
        defer {
            if let originalDeviceId { defaults.set(originalDeviceId, forKey: StorageKeys.deviceId) }
            else { defaults.removeObject(forKey: StorageKeys.deviceId) }
            if let originalMarker { defaults.set(originalMarker, forKey: StorageKeys.installedAppVersion) }
            else { defaults.removeObject(forKey: StorageKeys.installedAppVersion) }
        }
        defaults.removeObject(forKey: StorageKeys.deviceId)
        defaults.removeObject(forKey: StorageKeys.installedAppVersion)

        let recorder = EventLifecycleRecorder()
        let client = makeClient(recorder)
        defer { client.destroy() }

        XCTAssertEqual(recorder.count(of: "$app_install"), 1)
        XCTAssertEqual(recorder.count(of: "$app_update"), 0)
        XCTAssertEqual(
            defaults.string(forKey: StorageKeys.installedAppVersion),
            DeviceProfile.appVersion(),
            "the marker must be written so the NEXT launch does not report a second install"
        )
    }

    /// Pins the ACTUAL emission order on a fresh install, not the claim a stale comment
    /// used to make. `SheepitClient.start()` calls `emitAppInstallOrUpdateIfOwed()` before
    /// `emitSessionStartIfOwed()` textually, but `track("$app_install")` itself recurses
    /// into `emitSessionStartIfOwed()` before `queue.add()`-ing its own event — so
    /// `$session_start` is actually enqueued and delivered to `onEvent` FIRST. This is the
    /// review follow-up on commit `ff9e51ab` MUST FIX 2a: a comment claimed the opposite
    /// ("install-then-open ordering"), and nothing pinned the real sequence to catch it.
    func testSessionStartActuallyPrecedesAppInstallOnAFreshInstall() throws {
        try XCTSkipIf(DeviceProfile.appVersion() == nil, "no CFBundleShortVersionString in this XCTest host")
        let defaults = UserDefaults(suiteName: suiteName)!
        let originalDeviceId = defaults.string(forKey: StorageKeys.deviceId)
        let originalMarker = defaults.string(forKey: StorageKeys.installedAppVersion)
        defer {
            if let originalDeviceId { defaults.set(originalDeviceId, forKey: StorageKeys.deviceId) }
            else { defaults.removeObject(forKey: StorageKeys.deviceId) }
            if let originalMarker { defaults.set(originalMarker, forKey: StorageKeys.installedAppVersion) }
            else { defaults.removeObject(forKey: StorageKeys.installedAppVersion) }
        }
        defaults.removeObject(forKey: StorageKeys.deviceId)
        defaults.removeObject(forKey: StorageKeys.installedAppVersion)
        // `SheepitClient` hardcodes its `UserDefaults` suite, so a session left behind by
        // an earlier test would still be live (well within the 30-minute timeout) and no
        // $session_start would be owed — see `SessionStartEmissionTests.clearStoredSession`
        // for the same fix applied there.
        defaults.removeObject(forKey: StorageKeys.sessionId)
        defaults.removeObject(forKey: StorageKeys.sessionLastSeen)

        let recorder = EventLifecycleRecorder()
        let client = makeClient(recorder)
        defer { client.destroy() }

        let names = recorder.names
        guard let sessionStartIndex = names.firstIndex(of: "$session_start"),
              let appInstallIndex = names.firstIndex(of: "$app_install")
        else {
            return XCTFail("expected both events, got \(names)")
        }
        XCTAssertLessThan(
            sessionStartIndex, appInstallIndex,
            "$session_start is actually delivered before $app_install, despite the " +
            "opposite textual call order in start()"
        )
    }

    /// The regression that matters (decision 7): an install that already has a device id
    /// must write the marker and emit NOTHING — not `$app_install`, and not `$app_update`
    /// either, since there is nothing yet to diff against.
    func testAnExistingInstallUpgradingWritesTheMarkerWithoutEmitting() throws {
        try XCTSkipIf(DeviceProfile.appVersion() == nil, "no CFBundleShortVersionString in this XCTest host")
        let defaults = UserDefaults(suiteName: suiteName)!
        let originalDeviceId = defaults.string(forKey: StorageKeys.deviceId)
        let originalMarker = defaults.string(forKey: StorageKeys.installedAppVersion)
        defer {
            if let originalDeviceId { defaults.set(originalDeviceId, forKey: StorageKeys.deviceId) }
            else { defaults.removeObject(forKey: StorageKeys.deviceId) }
            if let originalMarker { defaults.set(originalMarker, forKey: StorageKeys.installedAppVersion) }
            else { defaults.removeObject(forKey: StorageKeys.installedAppVersion) }
        }
        // An existing install: a device id already on disk, from BEFORE this launch.
        defaults.set(UUID().uuidString, forKey: StorageKeys.deviceId)
        // ...upgrading to a version of the SDK that ships this feature for the first time.
        defaults.removeObject(forKey: StorageKeys.installedAppVersion)

        let recorder = EventLifecycleRecorder()
        let client = makeClient(recorder)
        defer { client.destroy() }

        XCTAssertEqual(
            recorder.count(of: "$app_install"), 0,
            "every existing install in the field upgrading to >=0.4.0 would otherwise " +
            "report a fake install the day it upgrades, corrupting install counts"
        )
        XCTAssertEqual(recorder.count(of: "$app_update"), 0)
        XCTAssertEqual(
            defaults.string(forKey: StorageKeys.installedAppVersion),
            DeviceProfile.appVersion(),
            "the marker must still be written (silently) so a REAL future update is detectable"
        )
    }

    func testAVersionChangeEmitsAppUpdateEndToEnd() throws {
        guard let currentVersion = DeviceProfile.appVersion() else {
            throw XCTSkip("no CFBundleShortVersionString in this XCTest host")
        }
        let defaults = UserDefaults(suiteName: suiteName)!
        let originalDeviceId = defaults.string(forKey: StorageKeys.deviceId)
        let originalMarker = defaults.string(forKey: StorageKeys.installedAppVersion)
        defer {
            if let originalDeviceId { defaults.set(originalDeviceId, forKey: StorageKeys.deviceId) }
            else { defaults.removeObject(forKey: StorageKeys.deviceId) }
            if let originalMarker { defaults.set(originalMarker, forKey: StorageKeys.installedAppVersion) }
            else { defaults.removeObject(forKey: StorageKeys.installedAppVersion) }
        }
        defaults.set(UUID().uuidString, forKey: StorageKeys.deviceId)
        let previousVersion = "\(currentVersion)-previous-test-marker"
        defaults.set(previousVersion, forKey: StorageKeys.installedAppVersion)

        let recorder = EventLifecycleRecorder()
        let client = makeClient(recorder)
        defer { client.destroy() }

        XCTAssertEqual(recorder.count(of: "$app_install"), 0)
        XCTAssertEqual(recorder.count(of: "$app_update"), 1)
        XCTAssertEqual(recorder.stringProperty("previous_version", on: "$app_update"), previousVersion)
        XCTAssertEqual(recorder.stringProperty("current_version", on: "$app_update"), currentVersion)
        XCTAssertEqual(defaults.string(forKey: StorageKeys.installedAppVersion), currentVersion)
    }

    /// MUST FIX 1 in the review of commit `ff9e51ab`: `emitAppInstallOrUpdateIfOwed()` used
    /// to read `DeviceProfile.appVersion()` (bare `CFBundleShortVersionString`) directly,
    /// ignoring `config.appVersion` entirely — the same host-provided override
    /// `Transport.buildPayload` (audit L-005) prefers for every other event's
    /// `app.version`, because a release-binding customer sets it to a commit SHA / build
    /// tag rather than the marketing version. This test needs NO `CFBundleShortVersionString`
    /// in the XCTest host at all: `config.appVersion` alone must decide the outcome, and a
    /// launch whose ONLY change is `config.appVersion` (not the bundle version) must still
    /// fire `$app_update` carrying the host-provided values — the exact release-upgrade
    /// scenario the event exists for.
    func testAppUpdateUsesTheHostProvidedConfigAppVersionNotTheBundleVersion() throws {
        let defaults = UserDefaults(suiteName: suiteName)!
        let originalDeviceId = defaults.string(forKey: StorageKeys.deviceId)
        let originalMarker = defaults.string(forKey: StorageKeys.installedAppVersion)
        defer {
            if let originalDeviceId { defaults.set(originalDeviceId, forKey: StorageKeys.deviceId) }
            else { defaults.removeObject(forKey: StorageKeys.deviceId) }
            if let originalMarker { defaults.set(originalMarker, forKey: StorageKeys.installedAppVersion) }
            else { defaults.removeObject(forKey: StorageKeys.installedAppVersion) }
        }
        // An existing install, so this is an update, not an install.
        defaults.set(UUID().uuidString, forKey: StorageKeys.deviceId)
        let previousVersion = "deadbee-previous-build-sha"
        defaults.set(previousVersion, forKey: StorageKeys.installedAppVersion)

        let recorder = EventLifecycleRecorder()
        // A release-binding commit SHA / build tag — deliberately NOT a plausible
        // `CFBundleShortVersionString`, so the assertion below fails loudly if the fix
        // regresses to reading the bundle version instead.
        let hostProvidedVersion = "cafebab-current-build-sha"
        let client = makeClient(recorder, appVersion: hostProvidedVersion)
        defer { client.destroy() }

        XCTAssertEqual(recorder.count(of: "$app_install"), 0)
        XCTAssertEqual(recorder.count(of: "$app_update"), 1)
        XCTAssertEqual(
            recorder.stringProperty("previous_version", on: "$app_update"), previousVersion
        )
        XCTAssertEqual(
            recorder.stringProperty("current_version", on: "$app_update"), hostProvidedVersion,
            "current_version must be the host-provided config.appVersion, matching what " +
            "Transport stamps as app.version on every other event in the same batch — not " +
            "the bundle's CFBundleShortVersionString"
        )
        XCTAssertEqual(
            defaults.string(forKey: StorageKeys.installedAppVersion), hostProvidedVersion,
            "the marker must be written under the host-provided version so the NEXT " +
            "launch's diff is against the same source"
        )
    }

    func testTheSameVersionEmitsNothingEndToEnd() throws {
        guard let currentVersion = DeviceProfile.appVersion() else {
            throw XCTSkip("no CFBundleShortVersionString in this XCTest host")
        }
        let defaults = UserDefaults(suiteName: suiteName)!
        let originalDeviceId = defaults.string(forKey: StorageKeys.deviceId)
        let originalMarker = defaults.string(forKey: StorageKeys.installedAppVersion)
        defer {
            if let originalDeviceId { defaults.set(originalDeviceId, forKey: StorageKeys.deviceId) }
            else { defaults.removeObject(forKey: StorageKeys.deviceId) }
            if let originalMarker { defaults.set(originalMarker, forKey: StorageKeys.installedAppVersion) }
            else { defaults.removeObject(forKey: StorageKeys.installedAppVersion) }
        }
        defaults.set(UUID().uuidString, forKey: StorageKeys.deviceId)
        defaults.set(currentVersion, forKey: StorageKeys.installedAppVersion)

        let recorder = EventLifecycleRecorder()
        let client = makeClient(recorder)
        defer { client.destroy() }

        XCTAssertEqual(recorder.count(of: "$app_install"), 0)
        XCTAssertEqual(recorder.count(of: "$app_update"), 0)
    }
}

/// `onEvent` fires on whatever thread called `track()`, so this is lock-guarded rather
/// than actor-isolated — mirrors `EventNameRecorder` in `SessionEventTests.swift`, kept
/// separate (file-private there) rather than shared.
private final class EventLifecycleRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _names: [String] = []
    private var _propertiesByName: [String: [String: Any]] = [:]

    func record(_ name: String, _ properties: [String: Any]? = nil) {
        lock.lock(); defer { lock.unlock() }
        _names.append(name)
        if let properties { _propertiesByName[name] = properties }
    }

    func count(of name: String) -> Int {
        lock.lock(); defer { lock.unlock() }; return _names.filter { $0 == name }.count
    }

    /// The full emission order, in the order `record` was called. Added alongside the
    /// review follow-up on commit `ff9e51ab` MUST FIX 2a — before this, the recorder only
    /// exposed `count(of:)`, so nothing pinned emission order and a false ordering claim
    /// in `SheepitClient.start()`'s comments went unnoticed.
    var names: [String] {
        lock.lock(); defer { lock.unlock() }; return _names
    }

    func stringProperty(_ key: String, on name: String) -> String? {
        lock.lock(); defer { lock.unlock() }; return _propertiesByName[name]?[key] as? String
    }
}
