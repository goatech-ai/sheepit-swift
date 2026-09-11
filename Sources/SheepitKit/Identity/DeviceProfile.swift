import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Single source of device/app introspection. Before this existed, `DeviceManager`
/// (device registration) and `PerformanceMonitor` (perf-batch context) each carried a
/// byte-identical private copy of `deviceModel()`/`osVersion()`.
enum DeviceProfile {
    /// Human-readable OS name, per platform. Was a hardcoded `"iOS"` constant before this
    /// fix, so every macOS/tvOS host silently reported "iOS" too — both to
    /// `POST /v1/devices/register` (`os_name`) and, once `Transport` wires it up, to the
    /// ingest wire's `context.device.os_name`.
    static var osName: String {
        #if os(macOS)
        return "macOS"
        #elseif os(tvOS)
        return "tvOS"
        #elseif os(watchOS)
        return "watchOS"
        #elseif os(iOS)
        #if targetEnvironment(macCatalyst)
        // A Catalyst binary compiles under `os(iOS)` but runs as a Mac app.
        return "macOS"
        #else
        return UIDevice.current.userInterfaceIdiom == .pad ? "iPadOS" : "iOS"
        #endif
        #else
        return "unknown"
        #endif
    }

    /// Hardware identifier (e.g. `"iPhone16,2"`), NOT `UIDevice.current.model` — that
    /// collapses to the generic `"iPhone"` / `"iPad"`, which is useless to the server's
    /// `formatDeviceModel()` (`packages/shared/src/device-models.ts`), which maps these
    /// identifiers to display names.
    /// Truncated to 256 for the same reason `osVersion()` and `timezone()` are: the value
    /// comes from the OS (`utsname.machine` / `sysctlbyname("hw.model")`), so its length is
    /// Apple's to change. `ingestContextSchema.device.model` caps at 256 and this context
    /// rides the whole BATCH, so an over-long string 400s up to 100 events. Apple's
    /// identifiers have never exceeded ~20 chars, which is exactly the "well under in
    /// practice" argument this codebase has been burned by before.
    ///
    /// 🔴 Two host-is-not-a-device cases, both of which make `uname()` report the CPU
    /// ARCHITECTURE rather than a device identifier — the same generic-string defect this
    /// function exists to fix:
    ///
    ///   • **Mac Catalyst** compiles under `os(iOS)` but runs as a Mac app, so it must take
    ///     the `hw.model` path. `osName` and `deviceType()` already nest a
    ///     `targetEnvironment(macCatalyst)` check inside their `os(iOS)` branch; this one
    ///     missed it, and a Catalyst install reported `os_name: "macOS"`,
    ///     `device.type: "desktop"` and `device.model: "arm64"` — internally inconsistent.
    ///   • **Simulator** runs as a native macOS process, so prefer the
    ///     `SIMULATOR_MODEL_IDENTIFIER` the simulated device advertises. Without it every
    ///     Simulator session — the normal integrator workflow, and our own dogfood app —
    ///     reports `"arm64"`.
    ///
    /// Neither is reachable by CI: `swift test` runs the macOS host, so only the
    /// `hw.model` branch executes, and the iOS typecheck never runs anything.
    static func deviceModel() -> String {
        #if targetEnvironment(simulator)
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"],
           !simulated.isEmpty {
            return bounded(simulated, 256)
        }
        return bounded(hardwareMachineIdentifier(), 256)
        #elseif os(macOS) || targetEnvironment(macCatalyst)
        return bounded(macHardwareModel(), 256)
        #else
        return bounded(hardwareMachineIdentifier(), 256)
        #endif
    }

    /// Truncated to 64 for the same reason `timezone()` is, and the reasoning is the
    /// point rather than today's margin: this value is OS-supplied, so its FORMAT is
    /// Apple's to change, not ours. `UIDevice.current.systemVersion` is a bare `"18.1"`,
    /// but `operatingSystemVersionString` is already a sentence — `"Version 26.6.2
    /// (Build 25G83)"` — and nothing stops that growing.
    ///
    /// It matters because `ingestContextSchema.device.os_version` caps at 64 and that
    /// context rides the whole BATCH: one over-long string 400s up to 100 events, and
    /// sdk-js drops a 400 without retry. Losing the tail of a version string is a
    /// cosmetic defect; losing 100 events is data loss. Truncate.
    static func osVersion() -> String {
        // 🔴 `os(iOS) || os(tvOS)`, NOT `canImport(UIKit)`. UIKit IS importable on watchOS
        // but `UIDevice` is not available there, so the `canImport` guard compiled on every
        // platform except the one it needed to exclude — and `Package.swift` declares
        // `.watchOS(.v9)`, so adding SheepitKit to a watch target failed to BUILD:
        //   error: 'UIDevice' is unavailable in watchOS
        // Reproduce with:
        //   xcrun --sdk watchos swiftc -target arm64_32-apple-watchos9.0 -typecheck <this file>
        // `scripts/check.sh` cannot catch it — it compiles the macOS host and typechecks iOS
        // only, and neither configuration takes this branch.
        #if os(iOS) || os(tvOS)
        return bounded(UIDevice.current.systemVersion, 64)
        #else
        return bounded(ProcessInfo.processInfo.operatingSystemVersionString, 64)
        #endif
    }

    static func appVersion() -> String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    static func buildNumber() -> String? {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String
    }

    /// IANA timezone identifier (e.g. `"America/Argentina/Buenos_Aires"`). Every other
    /// value this file returns is a small hardcoded literal (bounded by construction —
    /// the enumerable set of possible strings is verified against its schema field's max
    /// length), but this one is OS-supplied: no current IANA zone id is anywhere near the
    /// wire's 64-char cap (the longest today is ~34 chars), yet nothing guarantees that at
    /// the type level, and this context rides the whole ingest BATCH — one oversized value
    /// would 400 every event in it. Truncate defensively rather than trust tzdata forever.
    static func timezone() -> String {
        bounded(TimeZone.current.identifier, 64)
    }

    /// Canonical device-type bucket. `ingestContextSchema.device.type` (and the matching
    /// `deviceRegisterSchema`) deliberately keep this a bounded STRING rather than an enum
    /// server-side — this context rides the whole ingest BATCH, so one unrecognized value
    /// would 400 every event in it. "phone"/"tablet" are resolved at RUNTIME via
    /// `userInterfaceIdiom`, not a compile-time `#if`: a Mac Catalyst binary still compiles
    /// under `os(iOS)`, so a compile-time-only check would mislabel it as a phone.
    static func deviceType() -> String {
        #if os(macOS)
        return "desktop"
        #elseif os(tvOS)
        return "tv"
        #elseif os(watchOS)
        return "watch"
        #elseif os(iOS)
        #if targetEnvironment(macCatalyst)
        return "desktop"
        #else
        // Enumerated rather than `== .pad ? "tablet" : "phone"`: that spelling reports
        // "phone" for EVERY idiom it does not know, so an iPad-compatible app on Vision
        // Pro (idiom `.vision`) and a CarPlay scene both filed as phones. An unknown
        // idiom must say so — a wrong bucket is worse than an absent one, because it is
        // indistinguishable from real phone traffic in a breakdown.
        switch UIDevice.current.userInterfaceIdiom {
        case .phone: return "phone"
        case .pad: return "tablet"
        case .tv: return "tv"
        case .mac: return "desktop"
        case .carPlay: return "carplay"
        default: return "unknown"
        }
        #endif
        #else
        return "unknown"
        #endif
    }

    /// Best-effort distribution channel. Only two of the four values are genuinely
    /// distinguishable; the other two are inferred and can be wrong:
    ///
    ///   - `"simulator"` is compiler-guaranteed exact (`targetEnvironment(simulator)`).
    ///   - `"debug"` is exact whenever the host app's Debug configuration propagates
    ///     `-DDEBUG` to this package — SwiftPM's and Xcode's default for a Debug build,
    ///     no opt-in required, but still a property of how the CONSUMER builds, not
    ///     something this package can verify at compile time.
    ///   - `"testflight"` is inferred from the App Store receipt's filename
    ///     (`sandboxReceipt`) — Apple's own documented technique, not a stable public API.
    ///     TestFlight, ad-hoc, and enterprise-distributed Release builds all share that
    ///     same filename, so those last two are misreported as `"testflight"` too.
    ///   - `"appstore"` is the byproduct default (no sandbox receipt, not Debug, not the
    ///     Simulator) rather than a positive confirmation of App Store distribution.
    static func buildChannel() -> String {
        #if targetEnvironment(simulator)
        return "simulator"
        #elseif DEBUG
        return "debug"
        #else
        if let receiptURL = Bundle.main.appStoreReceiptURL,
           receiptURL.lastPathComponent == "sandboxReceipt" {
            return "testflight"
        }
        return "appstore"
        #endif
    }


    /// Truncates to at most `maxUTF16` UTF-16 code units — **the unit the server actually
    /// counts**.
    ///
    /// 🔴 This exists because `String.prefix(n)` is the wrong tool and looked like the
    /// right one. `prefix` counts Swift `Character`s, i.e. GRAPHEME CLUSTERS; zod's
    /// `.max(n)` counts JS `String.length`, i.e. UTF-16 code units. Those diverge badly
    /// on anything non-ASCII — measured against the real `ingestContextSchema`, a value of
    /// 32 grapheme clusters (a ZWJ emoji sequence) is **256** UTF-16 units and the schema
    /// rejects it.
    ///
    /// So `.prefix(32)` would pass on the client and then 400 the ENTIRE batch of up to
    /// 100 events, with sdk-js dropping the 400 without retry — the exact failure the
    /// truncation was added to prevent, surviving in the one case it was written for.
    /// Every value here is ASCII today, which is why this is latent rather than live; the
    /// point of truncating defensively is that "ASCII today" is Apple's call, not ours.
    ///
    /// Truncates on whole `Character`s, so it can never split a grapheme cluster or leave
    /// a dangling surrogate half.
    static func bounded(_ value: String, _ maxUTF16: Int) -> String {
        if value.utf16.count <= maxUTF16 { return value }
        var out = ""
        var used = 0
        for character in value {
            let width = String(character).utf16.count
            if used + width > maxUTF16 { break }
            out.append(character)
            used += width
        }
        return out
    }

    // MARK: - Private

    #if !os(macOS)
    /// `uname(2)`'s `machine` field — the hardware identifier iOS/tvOS/watchOS report
    /// (e.g. "iPhone16,2"), as opposed to `UIDevice.current.model`'s generic string.
    private static func hardwareMachineIdentifier() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let identifier = withUnsafePointer(to: &systemInfo.machine) { ptr -> String in
            ptr.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: ptr.pointee)) {
                String(cString: $0)
            }
        }
        return identifier.isEmpty ? "Unknown" : identifier
    }
    #endif

    // Catalyst is included deliberately: it compiles under `os(iOS)`, so a bare
    // `os(macOS)` guard would make this unavailable exactly where `deviceModel()` now
    // needs it. The iOS typecheck in `scripts/check.sh` targets plain iOS, not Catalyst,
    // so it would NOT have caught the missing symbol.
    #if os(macOS) || targetEnvironment(macCatalyst)
    /// macOS's `utsname.machine` reports the CPU architecture ("arm64"/"x86_64"), not the
    /// Mac's hardware identifier — `sysctlbyname("hw.model")` is the macOS equivalent of
    /// `hardwareMachineIdentifier()` above, returning e.g. "Mac14,7" / "MacBookPro18,3".
    private static func macHardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "Mac" }
        var raw = [CChar](repeating: 0, count: size)
        // The SECOND call is the one that fills the buffer, and it can fail independently
        // of the first. Without this guard a failure leaves `raw` zero-filled and
        // `String(cString:)` returns "" — an empty device_model rather than the "Mac"
        // fallback, which reads downstream as "the SDK sent nothing" instead of "unknown
        // Mac". The non-macOS sibling already guards its empty case.
        guard sysctlbyname("hw.model", &raw, &size, nil, 0) == 0 else { return "Mac" }
        let model = String(cString: raw)
        return model.isEmpty ? "Mac" : model
    }
    #endif
}
