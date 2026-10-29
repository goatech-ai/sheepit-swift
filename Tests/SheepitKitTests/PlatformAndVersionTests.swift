import XCTest
import SheepitCrashHandler
@testable import SheepitKit

/// PR12 (2026-10-21): SheepitKit stamps the device it runs on instead of a hardcoded `"ios"`,
/// and every stream (events, crashes, perf, registration) sends one app version.
///
/// Why each test exists:
/// - The API derives an application id from `platform` and a build id from platform +
///   version + build (`apps/api/src/lib/runtime-builds/derived-identity.ts`). A stream that
///   disagrees with the others on either field lands on a different build, and its crashes
///   never meet its sessions.
/// - Every platform value must be one the API accepts: an unknown value is refused by all four
///   ingest endpoints (a 400 on crash and perf, a rejected event, a device that never
///   registers and so receives no flags).
final class PlatformAndVersionTests: XCTestCase {
    // MARK: - Platform

    func testEachRuntimeMapsToTheDeviceItRunsOn() {
        let cases: [(DeviceProfile.Runtime, String)] = [
            (.macOS, "macos"),
            (.macCatalyst, "macos"),
            (.tvOS, "tvos"),
            (.watchOS, "watchos"),
            (.visionOS, "ipados"),
            (.uiKit(idiom: .phone, onMac: false), "ios"),
            (.uiKit(idiom: .pad, onMac: false), "ipados"),
            (.uiKit(idiom: .mac, onMac: false), "macos"),
            (.uiKit(idiom: .other, onMac: false), "ios"),
            // "Designed for iPad" on an Apple-silicon Mac reports idiom `.pad`: the device is a Mac.
            (.uiKit(idiom: .pad, onMac: true), "macos"),
            (.uiKit(idiom: .phone, onMac: true), "macos"),
        ]
        for (runtime, expected) in cases {
            XCTAssertEqual(DeviceProfile.wirePlatform(for: runtime), expected, "\(runtime)")
        }
    }

    /// The test host is a Mac; before PR12 it reported `ios` like every other Apple device.
    func testTheHostReportsItsOwnPlatform() {
        #if os(macOS)
        XCTAssertEqual(DeviceProfile.platform, "macos")
        #endif
    }

    /// Every value the SDK can stamp must be in the server's `PLATFORM_VALUES`. Read from the
    /// TypeScript source so the two lists cannot drift; skipped outside the monorepo.
    func testEveryStampableValueIsAcceptedByTheServer() throws {
        let schema = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // SheepitKitTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // sdk-swift
            .deletingLastPathComponent() // packages
            .appendingPathComponent("shared/src/schemas/platform.ts")
        guard let source = try? String(contentsOf: schema, encoding: .utf8) else {
            throw XCTSkip("packages/shared is not next to this package (standalone checkout)")
        }
        // The array literal, whatever line breaks prettier gives it.
        let start = try XCTUnwrap(
            source.range(of: "export const PLATFORM_VALUES = ["),
            "PLATFORM_VALUES moved; update this test's reader, not its assertion"
        )
        let end = try XCTUnwrap(source.range(of: "] as const", range: start.upperBound..<source.endIndex))
        let literal = source[start.upperBound..<end.lowerBound]
        let accepted = Set(literal.split(separator: "\"").enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) })
        XCTAssertTrue(accepted.contains("ios") && accepted.contains("web"), "reader parsed \(accepted.sorted())")
        let runtimes: [DeviceProfile.Runtime] = [
            .macOS, .macCatalyst, .tvOS, .watchOS, .visionOS,
            .uiKit(idiom: .phone, onMac: false), .uiKit(idiom: .pad, onMac: false),
            .uiKit(idiom: .mac, onMac: false), .uiKit(idiom: .other, onMac: false),
            .uiKit(idiom: .pad, onMac: true),
        ]
        for runtime in runtimes {
            let value = DeviceProfile.wirePlatform(for: runtime)
            XCTAssertTrue(accepted.contains(value), "\(runtime) → \(value) is not in PLATFORM_VALUES \(accepted.sorted())")
        }
    }

    func testEventsAndRegistrationCarryTheResolvedPlatform() throws {
        let context = ContextManager(storage: InMemoryStorage())
        XCTAssertEqual(context.eventContext().platform, DeviceProfile.platform)

        let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
            DeviceManager.registrationRequest(
                anonymousId: "anon", existingDeviceId: nil, appVersionOverride: nil, locale: Locale(identifier: "en_US")
            )
        )) as? [String: Any]
        XCTAssertEqual(body?["platform"] as? String, DeviceProfile.platform)
    }

    // MARK: - Version

    func testTheOverrideWinsOverTheBundleVersion() {
        XCTAssertEqual(DeviceProfile.wireAppVersion(override: "2.3.0"), "2.3.0")
        XCTAssertEqual(DeviceProfile.wireAppVersion(override: nil), DeviceProfile.appVersion())
    }

    /// One version on every stream, including the cases the two limits treat differently:
    /// 64 UTF-16 units on the wire, 63 UTF-8 bytes in the crash buffer.
    func testEventsRegistrationAndTheCrashBufferAgreeOnLongAndNonASCIIVersions() throws {
        let overrides = [
            "1.0.0",
            String(repeating: "a", count: 64), // fits the wire, not the crash buffer
            String(repeating: "版", count: 30), // 30 UTF-16 units, 90 UTF-8 bytes
            String(repeating: "👩‍👩‍👧", count: 10), // multi-scalar characters
        ]
        for override in overrides {
            let resolved = try XCTUnwrap(DeviceProfile.wireAppVersion(override: override))
            XCTAssertLessThanOrEqual(resolved.utf16.count, SDKDefaults.appVersionMaxLength, override)
            XCTAssertLessThanOrEqual(resolved.utf8.count, DeviceProfile.crashContextStringMaxUTF8, override)
            XCTAssertTrue(override.hasPrefix(resolved), "cut on a whole character: \(override)")

            XCTAssertEqual(TrackSnapshot.capture(appVersion: override).appVersion, resolved, override)
            let body = try JSONSerialization.jsonObject(with: JSONEncoder().encode(
                DeviceManager.registrationRequest(
                    anonymousId: "anon", existingDeviceId: nil, appVersionOverride: override,
                    locale: Locale(identifier: "en_US")
                )
            )) as? [String: Any]
            XCTAssertEqual(body?["app_version"] as? String, resolved, override)
        }
    }

    /// An empty override matched no release on any stream; it now means "unset".
    func testAnEmptyOverrideFallsBackToTheBundleVersion() {
        XCTAssertEqual(DeviceProfile.wireAppVersion(override: ""), DeviceProfile.wireAppVersion(override: nil))
        XCTAssertEqual(
            TrackSnapshot.capture(appVersion: "").appVersion,
            DeviceProfile.wireAppVersion(override: nil)
        )
    }

    /// The 63 is the crash context's C array minus its NUL. If the header's field changes size,
    /// events and crashes would bound differently again; this keeps the constant tied to it.
    func testTheCrashBoundMatchesTheCStruct() {
        let context = sheepit_crash_context_t()
        XCTAssertEqual(MemoryLayout.size(ofValue: context.app_version) - 1, DeviceProfile.crashContextStringMaxUTF8)
        XCTAssertEqual(MemoryLayout.size(ofValue: context.build_number) - 1, DeviceProfile.crashContextStringMaxUTF8)
    }

    func testBoundedUTF8NeverSplitsACharacter() {
        XCTAssertEqual(DeviceProfile.boundedUTF8("abc", 3), "abc")
        XCTAssertEqual(DeviceProfile.boundedUTF8("abcd", 3), "abc")
        XCTAssertEqual(DeviceProfile.boundedUTF8("ab版", 4), "ab") // 版 is 3 bytes
        XCTAssertEqual(DeviceProfile.boundedUTF8("版", 2), "")
    }

    /// The perf batch is built inside `PerformanceMonitor.flush()`; drive a real flush and read
    /// the body off the wire, since that is where crashes and perf used to ignore the override.
    func testAPerformanceBatchCarriesTheOverrideAndThePlatform() async throws {
        StubURLProtocol.reset()
        defer { StubURLProtocol.reset() }
        let http = HTTPClient(
            config: SheepitConfig(
                apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))", apiUrl: "https://stub.invalid"
            ),
            log: Logger(debug: false),
            urlProtocolClasses: [StubURLProtocol.self]
        )
        let monitor = PerformanceMonitor(
            http: http,
            context: ContextManager(storage: InMemoryStorage()),
            config: PerformanceConfig(
                enabled: true,
                startupTrackingEnabled: false,
                frameTrackingEnabled: false,
                networkTrackingEnabled: false,
                memoryTrackingEnabled: false
            ),
            appVersionOverride: "9.1.0-override",
            log: Logger(debug: false)
        )
        await monitor.addMetric(PerformanceMetric(
            metricType: "startup", metricName: "cold_start", valueMs: 1, statusCode: nil, isError: false,
            timestamp: "2026-10-21T00:00:00Z"
        ))
        await monitor.flush()

        let body = try XCTUnwrap(StubURLProtocol.requestBodies.last, "the flush must POST")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        let context = try XCTUnwrap(json["context"] as? [String: Any])
        XCTAssertEqual(context["app_version"] as? String, "9.1.0-override")
        XCTAssertEqual(context["platform"] as? String, DeviceProfile.platform)
    }
}
