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

## FAQ

**Which key type should I use?** Use a publishable key (`lp_pub_*`). The initializer validates the key format and accepts `lp_pub_*` or `lp_sec_*`, but a secret key must never ship in an app binary, so always use a publishable key in production builds.

**How do I get type-safe flags?** The `sheepit codegen` command in [@sheepit-ai/cli](https://www.npmjs.com/package/@sheepit-ai/cli) generates a Swift `Flag` enum for your project. Reference flags by `Flag.<name>.rawValue`.

**How does experiment bucketing work?** The server assigns the variant and the SDK caches it per device, so a device keeps its assignment across launches.

**Is the SDK concurrency-safe?** Yes. `SheepitClient` is `Sendable` and its internals are actor-isolated, so its public methods are safe to call from any thread.

## License

MIT. Copyright (c) 2026 GoaTech AI LLC. See [LICENSE](./LICENSE).
