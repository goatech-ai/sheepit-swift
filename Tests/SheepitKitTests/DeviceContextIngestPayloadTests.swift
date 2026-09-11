import XCTest
@testable import SheepitKit

/// Coverage for the device-context wire-payload fix. Before this, `Transport.buildPayload`
/// hardcoded `model: nil, osVersion: nil` on every batch — even the two columns
/// `events_raw` has had for ages were never populated by this SDK — and the six columns
/// PR #983 added server-side (`sdk_name`, `sdk_version`, `os_name`, `timezone`,
/// `device_type`, `build_channel`) had no client-side write path at all. This pins the
/// actual WIRE body (not merely that `DeviceProfile` computes something) carries every
/// field, sourced from `DeviceProfile`/`SDKDefaults` rather than a Transport-local literal
/// — so a regression in either of those fails this test too, not just a Transport-level one.
final class DeviceContextIngestPayloadTests: XCTestCase {
    override func setUp() {
        super.setUp()
        BodyCapturingStubURLProtocol.reset()
    }

    /// Mirrors `makeTransportHarness()` in `Support/TransportTestHarness.swift`, but wired
    /// to `BodyCapturingStubURLProtocol` instead of the shared `StubURLProtocol` — the
    /// shared stub records headers only, and this suite needs the actual JSON body.
    private func makeHarness() -> (transport: Transport, queue: EventQueue) {
        let config = SheepitConfig(
            apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))",
            apiUrl: "https://stub.invalid",
            retryAttempts: 1
        )
        let log = Logger(debug: false)
        let queue = EventQueue(maxSize: 100)
        let transport = Transport(
            http: HTTPClient(config: config, log: log, urlProtocolClasses: [BodyCapturingStubURLProtocol.self]),
            queue: queue,
            offlineQueue: OfflineQueue(storage: InMemoryStorage()),
            connectivity: ConnectivityMonitor(),
            log: log
        )
        return (transport, queue)
    }

    private func flushOneEventAndCaptureContext() async -> [String: Any]? {
        let (transport, queue) = makeHarness()
        queue.add(makeStubEvent(name: "probe_event"))
        await transport.flush()
        guard
            let body = BodyCapturingStubURLProtocol.lastBody,
            let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
            let context = json["context"] as? [String: Any]
        else { return nil }
        return context
    }

    func testIngestWireCarriesEverySDKAndDeviceContextFieldFromItsRealSource() async {
        guard let context = await flushOneEventAndCaptureContext() else {
            XCTFail("ingest request must carry a JSON body with context")
            return
        }

        guard let sdk = context["sdk"] as? [String: Any] else {
            XCTFail("context.sdk must be present — it was entirely unbuilt before this fix")
            return
        }
        XCTAssertEqual(sdk["name"] as? String, SDKDefaults.sdkName)
        XCTAssertEqual(sdk["version"] as? String, SDKDefaults.sdkVersion)

        guard let device = context["device"] as? [String: Any] else {
            XCTFail("context.device must be present")
            return
        }
        XCTAssertEqual(
            device["model"] as? String, DeviceProfile.deviceModel(),
            "model was hardcoded nil before this fix"
        )
        XCTAssertEqual(
            device["os_version"] as? String, DeviceProfile.osVersion(),
            "os_version was hardcoded nil before this fix"
        )
        XCTAssertEqual(device["os_name"] as? String, DeviceProfile.osName)
        // Reuses the EVENT's own stamped timezone (`first.timezone`), not a fresh
        // `DeviceProfile.timezone()` call — `makeStubEvent` fixes this to "UTC" regardless
        // of the host machine's real zone, so asserting on that literal (rather than
        // `DeviceProfile.timezone()`, which would be the CI runner's own zone and could
        // coincidentally match) is what actually pins "forwards the per-event value."
        XCTAssertEqual(device["timezone"] as? String, "UTC")
        XCTAssertEqual(device["type"] as? String, DeviceProfile.deviceType())

        guard let app = context["app"] as? [String: Any] else {
            XCTFail("context.app must be present")
            return
        }
        XCTAssertEqual(app["build_channel"] as? String, DeviceProfile.buildChannel())
    }

    /// `ingestContextSchema` validates the whole BATCH (up to 100 events) — one oversized
    /// field 400s every event in it, and sdk-js-style SDKs drop a 400 without retry. Pins
    /// that every new field fits its schema bound on the actual wire value, not just in
    /// theory.
    func testEverySixNewFieldFitsItsIngestContextSchemaBound() async {
        guard let context = await flushOneEventAndCaptureContext() else {
            XCTFail("ingest request must carry a JSON body with context")
            return
        }
        let sdk = context["sdk"] as? [String: Any] ?? [:]
        let device = context["device"] as? [String: Any] ?? [:]
        let app = context["app"] as? [String: Any] ?? [:]

        // 🔴 Measured in UTF-16 code units, NOT `String.count`.
        //
        // `count` is grapheme clusters; zod's `.max(n)` reads JS `String.length`, which is
        // UTF-16 units. Asserting `count` would pass the EXACT value that 400s the batch —
        // 32 clusters of a ZWJ emoji sequence is 256 UTF-16 units, verified against the
        // real `ingestContextSchema`. This file previously asserted `count`, which is the
        // same unit bug `DeviceProfile.bounded(_:_:)` exists to fix, surviving in the test
        // that was supposed to guard it.
        func utf16Count(_ value: Any?) -> Int { (value as? String)?.utf16.count ?? 0 }

        // Bounds copied from ingestContextSchema (packages/shared/src/schemas/platform.ts).
        XCTAssertLessThanOrEqual(utf16Count(sdk["name"]), 32, "sdk.name")
        XCTAssertLessThanOrEqual(utf16Count(sdk["version"]), 64, "sdk.version")
        XCTAssertLessThanOrEqual(utf16Count(device["os_name"]), 128, "device.os_name")
        XCTAssertLessThanOrEqual(utf16Count(device["timezone"]), 64, "device.timezone")
        XCTAssertLessThanOrEqual(utf16Count(device["type"]), 32, "device.type")
        XCTAssertLessThanOrEqual(utf16Count(app["build_channel"]), 32, "app.build_channel")
        XCTAssertLessThanOrEqual(utf16Count(device["model"]), 256, "device.model")
        XCTAssertLessThanOrEqual(utf16Count(device["os_version"]), 64, "device.os_version")
        // Both predate this work and both can 400 the whole batch — see Transport.swift.
        XCTAssertLessThanOrEqual(utf16Count(device["locale"]), 16, "device.locale")
        if let country = device["country"] as? String {
            XCTAssertEqual(country.utf16.count, 2, "device.country is .length(2), not a max")
        }
    }

    /// `UIDevice.current.model` collapses to the generic `"iPhone"`/`"iPad"` (and the
    /// pre-fix macOS fallback was the literal `"Mac"`) — useless to the server's
    /// `formatDeviceModel()`, which maps hardware identifiers like `"iPhone16,2"` to
    /// display names. This is the regression the `utsname`/`sysctlbyname` rewrite closes.
    func testDeviceModelReturnsAHardwareIdentifierNotTheGenericPlatformString() {
        let model = DeviceProfile.deviceModel()
        XCTAssertFalse(model.isEmpty)
        XCTAssertNotEqual(model, "iPhone")
        XCTAssertNotEqual(model, "iPad")
        XCTAssertNotEqual(model, "Mac")

        // A real hardware identifier looks like "<Family><Major>,<Minor>" —
        // e.g. "iPhone16,2" on iOS, "Mac16,5" on Apple Silicon Macs.
        let pattern = try! NSRegularExpression(pattern: "^[A-Za-z]+[0-9]+,[0-9]+$")
        let range = NSRange(model.startIndex..., in: model)
        XCTAssertNotNil(
            pattern.firstMatch(in: model, range: range),
            "expected a hardware-identifier shape (e.g. 'iPhone16,2' / 'Mac16,5'), got '\(model)'"
        )
    }

    /// `swift test` always builds in Debug configuration (`check.sh` never passes `-c
    /// release`), and SwiftPM defines `-DDEBUG` for that configuration by default —
    /// verified empirically before writing this assertion (a throwaway probe test, printed
    /// the real return value under `swift test`, then removed). So `.debug` is the one
    /// deterministic value `buildChannel()` can produce in THIS test environment; the
    /// other three branches depend on the app/host's own build (see the doc on
    /// `DeviceProfile.buildChannel()` for what is and isn't distinguishable there).
    func testBuildChannelIsDebugUnderTheTestHost() {
        XCTAssertEqual(DeviceProfile.buildChannel(), "debug")
    }
}

/// Body-capturing stub for `stub.invalid`. Unlike the shared `StubURLProtocol` in
/// `TransportTestHarness.swift` (records headers only), this records the request BODY too
/// — this suite asserts on `context.sdk`/`context.device`/`context.app`, not just that a
/// request went out.
final class BodyCapturingStubURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _lastBody: Data?

    static var lastBody: Data? {
        lock.lock(); defer { lock.unlock() }; return _lastBody
    }

    static func reset() {
        lock.lock(); _lastBody = nil; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "stub.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// `URLSession` sometimes hands `URLProtocol` the body as `httpBodyStream` rather than
    /// `httpBody`, even when the caller set `request.httpBody` directly — read both, same
    /// as `RegistrationStubURLProtocol` in `DeviceRegistrationTests.swift`.
    private static func bodyData(for request: URLRequest) -> Data? {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            if read > 0 {
                data.append(buffer, count: read)
            } else {
                break
            }
        }
        return data
    }

    override func startLoading() {
        Self.lock.lock()
        Self._lastBody = Self.bodyData(for: request)
        Self.lock.unlock()

        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url, statusCode: 202, httpVersion: "HTTP/1.1", headerFields: [:]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"data":{"accepted":1}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}


// MARK: - Independent value assertions
//
// The payload tests above compare `device["os_name"]` against a live call to
// `DeviceProfile.osName` — which proves `Transport` FORWARDS whatever the profile
// computes, and nothing about whether the computed value is right. A wrong literal in
// the `#if os(...)` chain, or a missing platform branch, passes that comparison happily.
// These pin the values themselves.
//
// Both are deterministic: `scripts/check.sh` runs `swift test` on the macOS host, so the
// `os(macOS)` branch is the one that executes. That is also the limitation worth stating
// — CI can only ever pin the macOS answers. The iOS/iPadOS/tvOS branches are covered by
// the typecheck pass and by reading, not by execution.
final class DeviceProfileBoundedTests: XCTestCase {
    /// 🔴 The bound the SERVER enforces is UTF-16 code units (zod `.max(n)` reads JS
    /// `String.length`), not Swift `Character`s. `String.prefix(n)` counts the latter, so
    /// it does NOT satisfy the former: measured against the real `ingestContextSchema`, 32
    /// grapheme clusters of a ZWJ emoji sequence is 256 UTF-16 units and is rejected.
    ///
    /// This matters because the context rides the whole BATCH — an over-long value 400s up
    /// to 100 events and sdk-js drops a 400 without retry. Every value we send is ASCII
    /// today, so this is latent; the truncation exists precisely because "ASCII today" is
    /// Apple's decision and not ours.
    func testBoundedCountsUTF16UnitsNotGraphemeClusters() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"  // ONE Character
        XCTAssertEqual(family.count, 1, "precondition: this is a single grapheme cluster")
        XCTAssertGreaterThan(family.utf16.count, 1, "precondition: it is many UTF-16 units")

        let input = String(repeating: family, count: 32)
        let result = DeviceProfile.bounded(input, 32)

        XCTAssertLessThanOrEqual(
            result.utf16.count, 32,
            "bounded() must guarantee the UTF-16 length the server checks. "
            + "String.prefix(32) would return all 32 clusters — \(input.utf16.count) "
            + "UTF-16 units — passing on the client and 400ing the entire batch."
        )
    }

    func testBoundedNeverSplitsAGraphemeCluster() {
        let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}"
        // A cap that falls in the MIDDLE of the cluster: it must drop the whole cluster
        // rather than emit a dangling surrogate half, which is not valid UTF-8 on the wire.
        let result = DeviceProfile.bounded(family, family.utf16.count - 1)
        XCTAssertEqual(result, "", "a partially-fitting cluster must be dropped entirely")
    }

    func testBoundedLeavesAValueThatAlreadyFitsUntouched() {
        XCTAssertEqual(DeviceProfile.bounded("America/Argentina/Buenos_Aires", 64),
                       "America/Argentina/Buenos_Aires")
        XCTAssertEqual(DeviceProfile.bounded("iPhone16,2", 256), "iPhone16,2")
    }
}

final class DeviceProfileValueTests: XCTestCase {
    func testOSNameIsTheMacOSLiteralOnTheTestHost() {
        XCTAssertEqual(
            DeviceProfile.osName, "macOS",
            "the `#if os(...)` chain in `osName` resolved to the wrong literal on the "
            + "macOS test host — the value is sent as `device.os_name` and buckets every "
            + "OS breakdown, so a wrong literal silently splits or mislabels a platform"
        )
    }

    func testDeviceTypeIsDesktopOnTheTestHost() {
        XCTAssertEqual(
            DeviceProfile.deviceType(), "desktop",
            "`deviceType()` resolved to the wrong bucket on the macOS test host"
        )
    }

    func testDeviceModelIsAMacHardwareIdentifierNotTheCPUArchitecture() {
        let model = DeviceProfile.deviceModel()
        // `uname().machine` returns "arm64"/"x86_64" on a Mac — the exact generic-string
        // defect `deviceModel()` exists to avoid, and what a Catalyst or Simulator build
        // would report if its platform branch were missing.
        XCTAssertFalse(
            ["arm64", "x86_64", "i386", "arm64e"].contains(model),
            "deviceModel() returned the CPU architecture \(model) instead of a hardware "
            + "identifier — `sysctlbyname(\"hw.model\")` is the macOS source, and "
            + "`utsname.machine` is wrong here"
        )
        XCTAssertFalse(model.isEmpty, "deviceModel() must never be empty; \"Mac\" is the fallback")
    }
}
