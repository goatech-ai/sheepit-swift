import XCTest

/// `SharedSDKStorage.keys` is a hand list; `StorageKeys` is the source of truth. Reads the
/// `StorageKeys` enum's string values straight from `PublicTypes.swift`, so a key added there and
/// not here fails this test instead of leaking between suites.
final class SharedSDKStorageTests: XCTestCase {
    func testTheHelperClearsEveryStorageKey() throws {
        let source = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/SheepitKit/Types/PublicTypes.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "enum StorageKeys"))
        let body = String(text[start.upperBound...].prefix { $0 != "}" })
        // `static let name = "…"` or `static let name: String = "…"`.
        let regex = try NSRegularExpression(pattern: #"static let \w+(?:\s*:\s*String)?\s*=\s*"([^"]+)""#)
        let declared = regex.matches(in: body, range: NSRange(body.startIndex..., in: body)).compactMap {
            Range($0.range(at: 1), in: body).map { String(body[$0]) }
        }
        // Exact, both ways: a parse that silently finds fewer keys fails here instead of passing.
        XCTAssertEqual(declared.count, SharedSDKStorage.keys.count, "parsed \(declared)")
        XCTAssertEqual(Set(declared), Set(SharedSDKStorage.keys))
    }
}
