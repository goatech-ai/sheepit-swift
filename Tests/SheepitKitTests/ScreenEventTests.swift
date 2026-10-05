import XCTest
import SheepitCrashHandler
@testable import SheepitKit

/// `screen(_:properties:)`: one call that both tracks a `$screen` event and sets the crash
/// context's screen. Clients are constructed but never started (`constructOnlyForTesting`), so
/// nothing here touches the network; events are observed through `config.onEvent`.
final class ScreenEventTests: XCTestCase {
    private typealias Captured = (name: String, properties: [String: Any]?)

    private func makeClient(
        crashes: Bool = false,
        diagnostics: LockedBox<[DiagnosticEvent]>? = nil
    ) -> (SheepitClient, LockedBox<[Captured]>) {
        let events = LockedBox<[Captured]>([])
        var config = SheepitConfig(
            apiKey: "lp_pub_tst_\(String(repeating: "a", count: 64))",
            apiUrl: "https://stub.invalid",
            crashes: CrashConfig(enabled: crashes)
        )
        config.onEvent = { @Sendable name, properties in
            events.mutate { $0.append((name, properties)) }
        }
        if let diagnostics {
            config.onDiagnostic = { @Sendable event in diagnostics.mutate { $0.append(event) } }
        }
        return (SheepitClient.constructOnlyForTesting(config: config), events)
    }

    private func screens(_ box: LockedBox<[Captured]>) -> [Captured] {
        box.get().filter { $0.name == "$screen" }
    }

    func testScreenTracksAScreenEventCarryingTheNameAndTheCallersProperties() throws {
        let (client, events) = makeClient()
        defer { client.destroy() }

        client.screen("Checkout", properties: ["step": 2, "variant": "b"])

        let sent = screens(events)
        XCTAssertEqual(sent.count, 1)
        let props = try XCTUnwrap(sent.first?.properties)
        XCTAssertEqual(props["screen"] as? String, "Checkout")
        XCTAssertEqual(props["step"] as? Int, 2)
        XCTAssertEqual(props["variant"] as? String, "b")
    }

    func testScreenWithoutPropertiesStillCarriesTheScreenProperty() throws {
        let (client, events) = makeClient()
        defer { client.destroy() }

        client.screen("Home")

        let props = try XCTUnwrap(screens(events).first?.properties)
        XCTAssertEqual(props.count, 1)
        XCTAssertEqual(props["screen"] as? String, "Home")
    }

    func testTheCallerCannotOverrideTheScreenProperty() throws {
        let (client, events) = makeClient()
        defer { client.destroy() }

        client.screen("Settings", properties: ["screen": "Spoofed"])

        let props = try XCTUnwrap(screens(events).first?.properties)
        XCTAssertEqual(props["screen"] as? String, "Settings")
    }

    func testTheNameIsTrimmed() throws {
        let (client, events) = makeClient()
        defer { client.destroy() }

        client.screen("  Profile \n")

        XCTAssertEqual(screens(events).first?.properties?["screen"] as? String, "Profile")
    }

    func testAnEmptyNameIsDroppedWithADiagnostic() {
        let diagnostics = LockedBox<[DiagnosticEvent]>([])
        let (client, events) = makeClient(diagnostics: diagnostics)
        defer { client.destroy() }

        client.screen("   ")
        client.screen("")

        XCTAssertTrue(screens(events).isEmpty, "no $screen event for an empty name")
        XCTAssertEqual(
            diagnostics.get().filter { $0.code == "transport.invalid_screen_name" }.count, 2
        )
    }

    func testANameThatBoundsToEmptyIsDroppedNotSentBlank() {
        // One grapheme cluster wider than the whole cap: bounding on a character boundary
        // leaves nothing. It must be dropped, not sent as `screen: ""` (and must not blank the
        // crash context).
        let diagnostics = LockedBox<[DiagnosticEvent]>([])
        let (client, events) = makeClient(diagnostics: diagnostics)
        defer { client.destroy() }

        client.screen("e" + String(repeating: "\u{0301}", count: 200))

        XCTAssertTrue(screens(events).isEmpty)
        XCTAssertEqual(diagnostics.get().filter { $0.code == "transport.invalid_screen_name" }.count, 1)
    }

    func testANULIsStrippedSoTheEventAndTheCrashContextAgree() throws {
        // The crash context is written with strlen: it would stop at the NUL while the event
        // carried the whole string.
        let (client, events) = makeClient()
        defer { client.destroy() }

        client.screen("Check\u{0}out")

        XCTAssertEqual(screens(events).first?.properties?["screen"] as? String, "Checkout")
    }

    func testSetScreenIsBoundedOnACharacterBoundaryToo() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sheepit-setscreen-context-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(sheepit_crash_handler_install(url.path), 0, "precondition: handler must install")
        defer { sheepit_crash_handler_uninstall() }

        let (client, _) = makeClient(crashes: true)
        defer { client.destroy() }

        client.setScreen(String(repeating: "é", count: 200))

        let ctx = try XCTUnwrap(sheepit_get_crash_context())
        let recorded = withUnsafeBytes(of: &ctx.pointee.screen_name) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        XCTAssertEqual(recorded, String(repeating: "é", count: 127), "no split multi-byte character")
    }

    func testBoundingIsIdempotent() {
        // The byte cut can land right after a space; without a second trim the result ends in
        // whitespace and a second pass shortens it again.
        let name = String(repeating: "a", count: 254) + " " + String(repeating: "b", count: 50)
        let once = SheepitClient.boundedScreenName(name)
        XCTAssertEqual(SheepitClient.boundedScreenName(once), once)
        XCTAssertEqual(once, String(repeating: "a", count: 254))
    }

    func testALongNameIsCappedOnACharacterBoundary() {
        // 200 two-byte characters = 400 UTF-8 bytes; the cap is 255 bytes, so 127 fit.
        let long = String(repeating: "é", count: 200)
        let bounded = SheepitClient.boundedScreenName(long)
        XCTAssertEqual(bounded.utf8.count, 254)
        XCTAssertEqual(bounded, String(repeating: "é", count: 127))

        let ascii = String(repeating: "a", count: 300)
        XCTAssertEqual(SheepitClient.boundedScreenName(ascii).utf8.count, SDKDefaults.screenNameMaxUTF8Bytes)
        XCTAssertEqual(SheepitClient.boundedScreenName("Home"), "Home")
    }

    func testTheEventNamePassesTheIngestEventNameRule() {
        // `eventNameSchema` in packages/shared/src/schemas/platform.ts: /^\$?[a-z][a-z0-9_]{0,255}$/.
        // A `$`-prefixed name is accepted from a publishable key; there is no reserved-name list.
        let rule = try? NSRegularExpression(pattern: "^\\$?[a-z][a-z0-9_]{0,255}$")
        let name = SheepitClient.screenEventName
        XCTAssertNotNil(rule?.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)))
    }

    func testAScreenCallAfterDestroyIsANoOp() {
        let (client, events) = makeClient()
        client.destroy()

        client.screen("Checkout")

        XCTAssertTrue(screens(events).isEmpty)
    }

    /// The crash half: a crash report reads `screen_name` from the mmap'd context, so the name
    /// must land there. Installs the process-global handler into a temp file and uninstalls
    /// before returning — the same discipline as `CrashContextDeviceProfileTests`.
    func testScreenSetsTheCrashContextScreen() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("sheepit-screen-context-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertEqual(sheepit_crash_handler_install(url.path), 0, "precondition: handler must install")
        defer { sheepit_crash_handler_uninstall() }

        let (client, _) = makeClient(crashes: true)
        defer { client.destroy() }

        client.screen("Checkout")

        let ctx = try XCTUnwrap(sheepit_get_crash_context())
        let recorded = withUnsafeBytes(of: &ctx.pointee.screen_name) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
        XCTAssertEqual(recorded, "Checkout")
    }
}
