import XCTest
@testable import SheepitSDK

/// The Swift half of the cross-language conformance gate.
///
/// Reads the SAME JSON files as the vitest and dotnet suites, straight from
/// the repository via `#filePath`. That is deliberate: SwiftPM `resources:`
/// would require the corpus to be COPIED under this package, and a copy is a
/// second source of truth that drifts silently — precisely the failure mode
/// this corpus exists to end. Reading the canonical file means a stale port
/// cannot hide behind a stale copy.
///
/// See packages/conformance/README.md.
final class ConformanceTests: XCTestCase {

    private static var corpusURL: URL {
        // <repo>/packages/sdk-swift/Tests/SheepitSDKTests/ConformanceTests.swift
        //   -> up 4 -> <repo>/packages -> conformance
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SheepitSDKTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // sdk-swift
            .deletingLastPathComponent()   // packages
            .appendingPathComponent("conformance")
    }

    private func load(_ name: String) throws -> [String: Any] {
        let url = Self.corpusURL.appendingPathComponent(name)
        let data = try Data(contentsOf: url)
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw XCTSkip("corpus \(name) is not a JSON object")
        }
        return obj
    }

    // MARK: - Corpus integrity

    func testCorpusIsTheVersionThisImplementationWasBuiltFor() throws {
        for name in ["hash.json", "bucket.json"] {
            let corpus = try load(name)
            XCTAssertEqual(
                corpus["bucketing_version"] as? Int, Bucketing.version,
                "\(name) describes a bucketing version this SDK does not implement"
            )
        }
    }

    // MARK: - hash.json

    func testHashVectors() throws {
        let corpus = try load("hash.json")
        let vectors = try XCTUnwrap(corpus["vectors"] as? [[String: Any]])
        // A path typo would otherwise produce a green suite that tested nothing.
        XCTAssertGreaterThan(vectors.count, 20, "hash corpus did not load")

        for v in vectors {
            let id = v["id"] as? String ?? "?"
            let b64 = try XCTUnwrap(v["input_utf8_base64"] as? String, "\(id): no input")
            let bytes = [UInt8](try XCTUnwrap(Data(base64Encoded: b64), "\(id): bad base64"))
            let seed = UInt32(truncatingIfNeeded: try XCTUnwrap(v["seed"] as? Int, "\(id): no seed"))
            let expected = UInt32(truncatingIfNeeded: try XCTUnwrap(
                v["expected_u32"] as? Int, "\(id): no expectation"
            ))
            XCTAssertEqual(
                MurmurHash3.hash32(bytes: bytes, seed: seed), expected,
                "hash vector \(id) diverges — this SDK would bucket users differently from the server"
            )
        }
    }

    func testPublishedReferenceVectors() {
        // Hard-coded rather than read from the corpus: the one assertion that
        // checks the corpus itself against the outside world. If the corpus is
        // ever regenerated from a broken implementation, every vector-driven
        // test still passes and only this one fails.
        XCTAssertEqual(MurmurHash3.hash32(""), 0)
        XCTAssertEqual(MurmurHash3.hash32("a"), 1_009_084_850)
        XCTAssertEqual(MurmurHash3.hash32("abc"), 3_017_643_002)
        XCTAssertEqual(MurmurHash3.hash32("abcd"), 1_139_631_978)
    }

    // MARK: - bucket.json

    func testBucketVectors() throws {
        let corpus = try load("bucket.json")
        let vectors = try XCTUnwrap(corpus["vectors"] as? [[String: Any]])
        XCTAssertGreaterThan(vectors.count, 20, "bucket corpus did not load")

        for v in vectors {
            let id = v["id"] as? String ?? "?"
            let kind = try XCTUnwrap(v["kind"] as? String, "\(id): no kind")
            let identity = try XCTUnwrap(v["identity"] as? String, "\(id): no identity")
            let entityId = try XCTUnwrap(v["entity_id"] as? String, "\(id): no entity_id")
            let expectedSeed = try XCTUnwrap(v["expected_seed"] as? String, "\(id): no seed")
            let expectedBucket = UInt32(truncatingIfNeeded: try XCTUnwrap(
                v["expected_bucket"] as? Int, "\(id): no bucket"
            ))

            let seed: String
            let bucket: UInt32
            switch kind {
            case "rollout":
                seed = Bucketing.rolloutSeed(identity: identity, rolloutId: entityId)
                bucket = Bucketing.rolloutBucket(identity: identity, rolloutId: entityId)
            case "experiment_pool":
                seed = Bucketing.experimentPoolSeed(identity: identity, experimentId: entityId)
                bucket = Bucketing.experimentPoolBucket(identity: identity, experimentId: entityId)
            case "experiment_variant":
                seed = Bucketing.experimentVariantSeed(identity: identity, experimentId: entityId)
                bucket = Bucketing.experimentVariantBucket(identity: identity, experimentId: entityId)
            default:
                // Fail CLOSED. Skipping an unknown kind is how a new vector
                // class ends up checked only by vitest while this suite stays
                // green and says nothing.
                XCTFail("unknown vector kind \"\(kind)\" — teach this suite the new kind, do not skip it")
                continue
            }

            XCTAssertEqual(seed, expectedSeed, "seed construction diverges for \(id)")
            XCTAssertEqual(bucket, expectedBucket, "bucket diverges for \(id)")
        }
    }

    // MARK: - Identity

    func testIdentityPrefersUserIdAndNamespacesIdSpaces() {
        XCTAssertEqual(Bucketing.identity(userId: "4821", deviceId: "dev-1"), "u:4821")
        XCTAssertEqual(Bucketing.identity(userId: nil, deviceId: "dev-1"), "d:dev-1")
        XCTAssertEqual(Bucketing.identity(userId: "", deviceId: "dev-1"), "d:dev-1")
        XCTAssertNil(Bucketing.identity(userId: nil, deviceId: nil))
        XCTAssertNotEqual(
            Bucketing.identity(userId: "x", deviceId: nil),
            Bucketing.identity(userId: nil, deviceId: "x")
        )
    }

    func testIdentityIsNilRatherThanCrashingAndCallersMustFailClosed() {
        // The TS sibling throws here; an SDK inside a customer app must not.
        // This test pins the resulting contract while `Bucketing` still has no
        // callers, so whoever wires up local evaluation inherits it rather
        // than inventing it.
        XCTAssertNil(Bucketing.identity(userId: nil, deviceId: nil))
        XCTAssertNil(Bucketing.identity(userId: "", deviceId: ""))

        // The prescribed caller shape: no identity -> the caller's default.
        // NOT "skip the rollout", which would put every unidentified subject
        // outside every rollout and look like a working feature flag.
        let callerDefault = true
        func evaluate(userId: String?, deviceId: String?) -> Bool {
            guard let identity = Bucketing.identity(userId: userId, deviceId: deviceId) else {
                return callerDefault
            }
            return Bucketing.rolloutBucket(identity: identity, rolloutId: "r-1") < 50
        }
        XCTAssertEqual(evaluate(userId: nil, deviceId: nil), callerDefault)
    }

    // MARK: - Regressions the retired implementation would fail

    func testDistinguishesEqualLengthAlphabeticInputs() {
        let hashes = Set(["aaaa", "bbbb", "zzzz"].map { MurmurHash3.hash32($0) })
        XCTAssertEqual(hashes.count, 3)
    }

    func testHashesMultibyteTextByBytesNotCodeUnits() {
        // "café" is 4 characters but 5 UTF-8 bytes. The retired implementation
        // masked UTF-16 code units to 0xFF and fed the CHARACTER count to the
        // finalizer, so it produced a different hash from every byte-oriented
        // implementation.
        XCTAssertEqual(Array("café".utf8).count, 5)
        XCTAssertEqual(MurmurHash3.hash32("café"), MurmurHash3.hash32(bytes: Array("café".utf8)))
    }

    func testTailIsHashedInCanonicalOrder() {
        // len % 4 == 3 is where the retired reversed-tail port diverged.
        XCTAssertEqual(MurmurHash3.hash32("abc"), 3_017_643_002)
    }
}
