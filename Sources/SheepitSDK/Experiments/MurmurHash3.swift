import Foundation

/// MurmurHash3 x86 32-bit — canonical Austin Appleby, over UTF-8 bytes.
///
/// A PORT of `packages/shared/src/bucketing/`. It is not trusted on the
/// strength of that claim: `packages/conformance/` pins it against the same
/// vectors as every other implementation, including the published MurmurHash3
/// reference values. See `ConformanceTests.swift`.
///
/// 🔴 The implementation this replaced was NOT MurmurHash3. It hashed
/// `String.utf16` masked to `0xFF` and built its tail in reverse byte order,
/// so it agreed with canonical murmur3 only when `count % 4` was 0 or 1 — and
/// it disagreed with the API server, which had a separate and worse defect of
/// its own. Its header comment asserted agreement with both the JS SDK and the
/// server; that comment was false in both directions, and nothing tested it.
enum MurmurHash3 {

    /// Compute a 32-bit MurmurHash3 over a string's UTF-8 bytes.
    static func hash32(_ string: String, seed: UInt32 = 0) -> UInt32 {
        hash32(bytes: Array(string.utf8), seed: seed)
    }

    /// Compute a 32-bit MurmurHash3 over raw bytes.
    static func hash32(bytes: [UInt8], seed: UInt32 = 0) -> UInt32 {
        let c1: UInt32 = 0xCC9E_2D51
        let c2: UInt32 = 0x1B87_3593
        let len = bytes.count
        let nblocks = len & ~3
        var h1 = seed

        var i = 0
        while i < nblocks {
            var k1 = UInt32(bytes[i])
                | (UInt32(bytes[i + 1]) << 8)
                | (UInt32(bytes[i + 2]) << 16)
                | (UInt32(bytes[i + 3]) << 24)

            k1 = k1 &* c1
            k1 = (k1 << 15) | (k1 >> 17)
            k1 = k1 &* c2

            h1 ^= k1
            h1 = (h1 << 13) | (h1 >> 19)
            h1 = (h1 &* 5) &+ 0xE654_6B64

            i += 4
        }

        // Tail. Canonical order: the LAST remaining byte occupies the HIGH
        // position. Reversing these three lines is exactly the defect that
        // made the previous implementation agree with nothing.
        var k1: UInt32 = 0
        switch len & 3 {
        case 3:
            k1 ^= UInt32(bytes[nblocks + 2]) << 16
            fallthrough
        case 2:
            k1 ^= UInt32(bytes[nblocks + 1]) << 8
            fallthrough
        case 1:
            k1 ^= UInt32(bytes[nblocks])
            k1 = k1 &* c1
            k1 = (k1 << 15) | (k1 >> 17)
            k1 = k1 &* c2
            h1 ^= k1
        default:
            break
        }

        h1 ^= UInt32(truncatingIfNeeded: len)
        h1 ^= h1 >> 16
        h1 = h1 &* 0x85EB_CA6B
        h1 ^= h1 >> 13
        h1 = h1 &* 0xC2B2_AE35
        h1 ^= h1 >> 16

        return h1
    }
}

/// Seed construction + bucket derivation. Mirrors
/// `packages/shared/src/bucketing/index.ts`; pinned by `packages/conformance/bucket.json`.
enum Bucketing {

    /// Bumped whenever a live subject's bucket can move.
    static let version = 2

    static let rolloutModulus: UInt32 = 100
    static let experimentModulus: UInt32 = 10_000

    /// The bucketing identity: the user id when the subject is identified, the
    /// device id when anonymous. The `u:` / `d:` prefixes namespace the two id
    /// spaces so the same text cannot land on the same bucket as a different
    /// kind of subject.
    ///
    /// 🔴 Returns `nil` where the TypeScript sibling THROWS, and that
    /// asymmetry is deliberate: on the server an identity-less subject is a
    /// programmer error worth failing loudly on, whereas an SDK embedded in a
    /// customer's app must never crash it. The contract for a caller is
    /// therefore **fail closed to the caller-supplied default** — never treat
    /// `nil` as "skip the rollout and carry on", which would silently place
    /// every unidentified subject outside every rollout. `ConformanceTests`
    /// pins this, because nothing calls it yet and an untested contract on
    /// dead code is how the next reader gets it wrong.
    static func identity(userId: String?, deviceId: String?) -> String? {
        if let userId, !userId.isEmpty { return "u:\(userId)" }
        if let deviceId, !deviceId.isEmpty { return "d:\(deviceId)" }
        return nil
    }

    /// Rollout seed. The flag key is deliberately absent: the rollout id is
    /// already unique, and including the key meant renaming a flag re-bucketed
    /// every user on it.
    static func rolloutSeed(identity: String, rolloutId: String) -> String {
        "\(identity):\(rolloutId)"
    }

    static func experimentPoolSeed(identity: String, experimentId: String) -> String {
        "\(identity):\(experimentId)"
    }

    static func experimentVariantSeed(identity: String, experimentId: String) -> String {
        "\(identity):variant:\(experimentId)"
    }

    static func rolloutBucket(identity: String, rolloutId: String) -> UInt32 {
        MurmurHash3.hash32(rolloutSeed(identity: identity, rolloutId: rolloutId)) % rolloutModulus
    }

    static func experimentPoolBucket(identity: String, experimentId: String) -> UInt32 {
        MurmurHash3.hash32(experimentPoolSeed(identity: identity, experimentId: experimentId))
            % experimentModulus
    }

    static func experimentVariantBucket(identity: String, experimentId: String) -> UInt32 {
        MurmurHash3.hash32(experimentVariantSeed(identity: identity, experimentId: experimentId))
            % experimentModulus
    }
}
