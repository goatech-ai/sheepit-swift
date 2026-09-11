<div align="center">

# SheepitKit

_Feature flags, experiments, and event tracking for iOS, macOS, tvOS, and watchOS._

[![license](https://img.shields.io/badge/license-MIT-blue)](./LICENSE)
[![platforms](https://img.shields.io/badge/platforms-iOS%2016%20%7C%20macOS%2013%20%7C%20tvOS%2016%20%7C%20watchOS%209-blue)](./Package.swift)

</div>

Native Swift SDK for the [Sheepit](https://www.sheepit.ai) platform. Evaluate feature flags, assign experiment variants, and track events from Apple platforms, against the same project as the JavaScript and server SDKs.

## Why it exists

Web and backend get flags and experiments from the Sheepit SDKs, and native apps need the same surface without a JavaScript bridge. SheepitKit is a Swift-native client built for SwiftUI: a `Sendable` reference type you inject through the environment, with crash and performance capture built in.

## Install

Sheepit is developed in the Sheepit monorepo (`packages/sdk-swift`) and published to the public mirror repository [`goatech-ai/sheepit-swift`](https://github.com/goatech-ai/sheepit-swift), which is what Swift Package Manager resolves against. Every release tag on the mirror is a bare semver version (`0.3.0`), mirrored from the monorepo by CI.

### Xcode

**File → Add Package Dependencies…** → enter `https://github.com/goatech-ai/sheepit-swift.git` → choose **Exact Version** and enter `0.3.0`.

> 🔴 **Pin exactly while this package is on `0.x`.** SPM's "Up to Next Major"
> does not special-case `0.x` the way npm and Cargo do — `from: "0.3.0"`
> resolves `>=0.3.0 <1.0.0`, which would pull in every future `0.x` release,
> and `0.x` is precisely where breaking changes are allowed. Pin exactly and
> upgrade deliberately until `2.0.0`, the first stable release. See the
> CHANGELOG's "Version policy" for why `1.0.x` is abandoned.

### Package.swift

```swift
dependencies: [
  .package(url: "https://github.com/goatech-ai/sheepit-swift.git", exact: "0.3.0"),
]
```

```swift
.target(
  name: "MyApp",
  dependencies: [.product(name: "SheepitKit", package: "sheepit-swift")]
)
```

Supported platforms (from `Package.swift`): iOS 16+, macOS 13+, tvOS 16+, watchOS 9+. Swift tools 5.9+.

## Usage

```swift
import SheepitKit
import SwiftUI

// SheepitClient is a plain reference type, not `Observable`, so it travels
// through a custom EnvironmentKey rather than SwiftUI's `.environment(_:)`
// single-argument form — that overload requires `Observable` and iOS 17,
// and this package supports iOS 16.
private struct SheepitClientKey: EnvironmentKey {
  static let defaultValue: SheepitClient? = nil
}

extension EnvironmentValues {
  var sheepit: SheepitClient? {
    get { self[SheepitClientKey.self] }
    set { self[SheepitClientKey.self] = newValue }
  }
}

@main
struct MyApp: App {
  @State private var sheepit: SheepitClient?

  var body: some Scene {
    WindowGroup {
      ContentView()
        .environment(\.sheepit, sheepit)
        .task {
          sheepit = SheepitClient.create(config: .init(apiKey: "lp_pub_..."))
        }
    }
  }
}

struct ContentView: View {
  @Environment(\.sheepit) private var sheepit

  var body: some View {
    Button("Start trial") { sheepit?.track("cta_clicked") }
  }
}
```

```swift
// track an event
sheepit?.track("course_viewed", properties: ["course_id": "abc-123"])

// evaluate a flag
let showBeta = sheepit?.flag("show_beta_ui", default: .bool(false))

// assign an experiment variant (sticky per device)
let result = sheepit?.experiment("checkout_redesign")
print(result?.variant ?? "control")

// identity
sheepit?.identify(userId: "user_abc", traits: ["plan": "pro"])
sheepit?.reset()
```

## API reference

| Symbol                                                              | Purpose                                                            |
| ------------------------------------------------------------------- | ------------------------------------------------------------------ |
| `SheepitClient.create(config:)`                                     | Create an instance (preferred for SwiftUI)                         |
| `SheepitClient.initialize(config:)` / `SheepitClient.shared`        | Singleton create and accessor                                      |
| `track(_:properties:)`                                              | Send an event                                                      |
| `flag(_:default:)`                                                  | Evaluate a flag; returns a `FlagValue`                             |
| `experiment(_:)`                                                    | Get a `SheepitExperimentResult` (with `.variant`)                  |
| `identify(userId:traits:)` / `reset()`                              | Set or clear user identity                                         |
| `FlagValue`                                                         | Enum: `.bool`, `.string`, `.int`, `.double`, `.json`               |
| `overrideFlag(_:value:)` / `clearOverride(_:)` / `clearOverrides()` | Set/clear debug flag overrides                                     |
| `getOverrides()`                                                    | Read the debug flag overrides currently set                        |
| `inspect(_:default:)`                                               | Non-exposing diagnostic read — `SheepitFlagInspection` (dev menu)  |
| `knownFlagKeys()`                                                   | Sorted union of remote-valued + overridden flag keys               |
| `flagChanges()`                                                     | `AsyncStream<Void>` — fires on config apply / override set / clear |
| `status()`                                                          | Queue depths, connectivity, `lastFlushAt`, device / user id        |
| `diagnostics()` / `getRecentDiagnostics()`                          | Live and buffered internal SDK events                              |
| `SheepitConfig`                                                     | Configuration, including optional `crashes` and `performance`      |

**Crash capture is ON by default**; performance monitoring is OFF by default. Both are configured through `SheepitConfig` (`crashes:` / `performance:`).

Because crash capture is on by default, the package ships a privacy manifest (`Sources/SheepitKit/PrivacyInfo.xcprivacy`) declaring the data it collects and the required-reason APIs it calls. Xcode aggregates it into your app's privacy report automatically — you do not need to copy anything into your target.

### Flags with JSON values

A flag whose value type is `json` resolves to `.json`:

```swift
struct Theme: Decodable { let accent: String; let compact: Bool }

let value = sheepit?.flag("home_theme", default: .json(AnyCodable(["accent": "purple"])))
let theme = value?.decodeJSON(Theme.self)      // typed
let dict = value?.jsonObject                    // [String: Any]?
let items = value?.jsonArray                    // [Any]?
```

### Diagnostics

Subscribe to the SDK's internal event stream without turning on `debug` logging:

```swift
let cancel = sheepit?.diagnostics().subscribe(
  { event in print(event.code, event.message) },
  options: .init(minSeverity: .warn, categories: [.transport])
)

// or read the bounded buffer
let recent = sheepit?.getRecentDiagnostics()
```

`SheepitConfig.onDiagnostic` wires a subscriber at init; `diagnosticBufferSize` sizes the buffer (default 100).

**SDK-internal errors are tracked as an `$error` event** (renamed from `$sdk_error` in `0.4.0`, to converge on the one name the web and server SDKs already use for their own error events). If you have a saved dashboard chart or segment filtering `$sdk_error`, it goes flat at the `0.4.0` release — historical rows stay under the old name, but nothing new is written there. Point it at `$error` instead. This matters for BYOC customers pinning an image who may not read the CHANGELOG.

### Developer menu

The SDK links **no SwiftUI/AppKit** — it ships the flag-override _store_
and a non-exposing _inspection_ surface, not a screen. Building the
screen (a DEBUG-only flag override menu) is on you. Gate it with
`#if DEBUG` explicitly rather than relying on `SheepitConfig` alone — the
SDK has no way to keep a screen you build out of a release binary:

```swift
#if DEBUG
import SwiftUI
import SheepitKit

/// The full key list is the UNION of two sources, deduped:
/// - `Flag.allCases` (from `sheepit codegen --swift`) — works on a fresh
///   install even with the API down.
/// - `sheepit.knownFlagKeys()` — server keys your local codegen doesn't
///   know about yet (a stale-codegen detector). Skipping this half is
///   the difference between a menu that shows every flag and one that
///   silently hides any flag added after your last `sheepit codegen` run.
struct FlagOverrideMenu: View {
    let sheepit: SheepitClient
    @State private var inspections: [SheepitFlagInspection] = []

    var body: some View {
        List(inspections, id: \.key) { row in
            HStack {
                VStack(alignment: .leading) {
                    Text(row.key).font(.headline)
                    Text("\(row.source.rawValue) · remote: \(String(describing: row.remoteValue))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { row.effectiveValue.boolValue ?? false },
                    set: { sheepit.overrideFlag(row.key, value: .bool($0)) }
                ))
                if row.overrideValue != nil {
                    Button("Reset") { sheepit.clearOverride(row.key) }
                }
            }
        }
        .task { await refresh() }
        .task {
            // No Combine/Observation surface exists — poll the stream to
            // re-render on config apply / override set / override clear.
            for await _ in sheepit.flagChanges() { await refresh() }
        }
    }

    private func refresh() async {
        let codegenKeys = Flag.allCases.map(\.rawValue)
        let allKeys = Set(codegenKeys).union(sheepit.knownFlagKeys()).sorted()
        inspections = allKeys.map { sheepit.inspect($0) }
    }
}
#endif
```

`inspect(_:default:)` **never fires `$flag_exposure`** — sweeping every
known flag to render this list does not pollute experiment/flag exposure
data the way calling `flag(_:default:)` in a loop would.
`SheepitConfig.allowFlagOverrides` gates whether `overrideFlag` takes
effect (defaults to following `debug`) — `clearOverride`/`clearOverrides`
always work, so the "Reset" button above is never a silent no-op even in
a build where overrides are disabled. The full precedence table is `override` > `remote` (live or cached
`/v1/config`) > the `default:` you pass in, which is exactly what
`SheepitFlagInspection.source` reports.

### Background flush

On UIKit platforms the SDK observes `UIApplication.didEnterBackgroundNotification` and flushes queued events inside a `beginBackgroundTask` window, so events queued just before the app is backgrounded are not lost when the process is later killed. Nothing to configure.

### Sessions

The SDK maintains a session automatically. You do not need to call `track()` at launch to be counted — **an app that launches and does nothing still registers a session.**

- A session ends after **30 minutes of inactivity**, where activity means an event. This matches the JS SDK.
- `$session_start` is emitted automatically when a launch opens a new session, and again when the app returns to the foreground after the idle window elapsed while it was suspended. It carries one property, `is_first_session` — `true` only for the device's very first session ever, so the install cohort is queryable without joining back to `$app_install`. Everything else (session id, device context) already rides on every event.
- The session id is persisted, so relaunching within the window continues the same session rather than starting a new one.
- `reset()` rotates the session id (as on web) but does **not** emit `$session_start` — a logout is not a new session.

Nothing to configure, and nothing to call.

### Install and update

`$app_install` fires exactly once, on a genuinely fresh install — never again, and never on an existing install merely upgrading to a version of this SDK that ships the feature. `$app_update` fires whenever the app's version changes since the last launch, carrying `previous_version` / `current_version`. Both are driven by one storage key, so an app that has been installed for months does not report a fake install the day it upgrades.

Nothing to configure, and nothing to call.

## FAQ

**Which key type should I use?** A publishable key (`lp_pub_*`) — it is the only type this SDK accepts. Secret keys (`lp_sec_*`) grant full project write access and must never ship in an app binary, where anyone can extract them from the IPA; developer keys (`lp_dev_*`) are read-only for schemas and definitions and cannot post events. Both are refused.

**Nothing is happening — no events, and every flag returns my default.** Most often the API key was refused. The SDK does not crash your app over a bad key; it returns an inert client and tells you three ways:

```swift
let sheepit = SheepitClient.create(config: .init(apiKey: key))
if let reason = sheepit.status().rejectionReason {
    assertionFailure("[Sheepit] \(reason)")   // debug builds only
}
```

An error is also logged to `os_log`, and a `lifecycle.api_key_rejected` diagnostic is emitted — subscribe with `SheepitConfig.onDiagnostic` or read `getRecentDiagnostics()`. If the key is fine, check that the device has network and that events are being flushed (`status().queueDepth`).

**Does the SDK hardcode the `lp_` key prefix?** No. It validates the shape of a key — `{prefix}_pub_{env}_{secret}` — but never the vendor prefix itself, so a key minted under a future prefix works on a version you have already pinned. A published Swift package version is immutable, so anything compiled in here is compiled in forever.

**How do I get type-safe flags?** The `sheepit codegen` command in [@sheepit-ai/cli](https://www.npmjs.com/package/@sheepit-ai/cli) generates a Swift `Flag` enum for your project. Reference flags by `Flag.<name>.rawValue`.

**How does experiment bucketing work?** The server assigns the variant and the SDK caches it per device, so a device keeps its assignment across launches.

**Is the SDK concurrency-safe?** Yes, within one process. `SheepitClient` is `Sendable` and its internals are actor-isolated, so its public methods are safe to call from any thread. That guarantee does not extend across process boundaries: `create()`/`initialize()` persist device and session identity under a fixed `UserDefaults` suite that is not an App Group id, so **do not link SheepitKit into an app extension alongside a host app**, and do not run two independent processes against the same install — each process would compute its own fresh device id and independently report its own `$app_install` and `$session_start(is_first_session: true)`, double-counting a single real install.

## License

MIT. Copyright (c) 2026 GoaTech AI LLC. See [LICENSE](./LICENSE).
