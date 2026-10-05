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

Sheepit is developed in the Sheepit monorepo (`packages/sdk-swift`) and published to the public mirror repository [`goatech-ai/sheepit-swift`](https://github.com/goatech-ai/sheepit-swift), which is what Swift Package Manager resolves against. Every release tag on the mirror is a bare semver version (`0.7.0`), mirrored from the monorepo by CI.

### Xcode

**File → Add Package Dependencies…** → enter `https://github.com/goatech-ai/sheepit-swift.git` → choose **Exact Version** and enter `0.7.0`.

> 🔴 **Choose "Exact Version" `0.7.0`. Do not accept Xcode's default "Up to Next Major", and do not use `from:`.**
> The mirror also carries tags `1.0.0` and `1.0.1`. They are **older** code than `0.7.0` and
> export a different product name (`SheepitSDK`, not `SheepitKit`). Semver ranks them higher,
> so Xcode pre-fills its default rule from `1.0.1` and resolves the wrong release. Pin
> `exact: "0.7.0"` and upgrade deliberately. See the CHANGELOG's "Version policy".

### Package.swift

```swift
dependencies: [
  .package(url: "https://github.com/goatech-ai/sheepit-swift.git", exact: "0.7.0"),
]
```

```swift
.target(
  name: "MyApp",
  dependencies: [.product(name: "SheepitKit", package: "sheepit-swift")]
)
```

Supported platforms (from `Package.swift`): iOS 16+, macOS 13+, tvOS 16+, watchOS 9+. Swift tools 5.9+.

## Key type

Use a **publishable** key (`lp_pub_…`). It is the only type the SDK accepts; a secret or developer key produces an inert client (see the FAQ). Never ship a secret key (`lp_sec_…`) in an app binary.

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
import SheepitKit

func example(sheepit: SheepitClient) async {
    // track an event
    sheepit.track("checkout_started", properties: ["cart_value": 42])

    // identity: after login. Traits stay on the device — they are NOT uploaded and cannot be
    // targeted on. Send anything the server needs as event properties instead.
    sheepit.identify(userId: "user_abc")

    // evaluate a flag (synchronous; returns the default until config has loaded)
    let showBeta = sheepit.flag("show_beta_ui", default: .bool(false))
    if showBeta.boolValue == true { /* ... */ }

    // experiment variant; "control" when there is no assignment
    let result = sheepit.experiment("checkout_redesign")
    print(result.variant, result.payload ?? [:])

    // send queued events now
    await sheepit.flush()

    // logout: clears identity, cached config, evaluated flags and assignments
    sheepit.reset()

    // teardown: stops timers and handlers; final flush is fire-and-forget
    sheepit.destroy()
}
```

### How flags and experiments resolve

SheepitKit evaluates nothing locally. It fetches `GET /v1/config`, which returns values the API has already evaluated for this device, and caches them. `flag(_:default:)` and `experiment(_:)` read that cache synchronously.

- Configuration is polled every `configRefreshInterval`, **300 seconds by default**. A flag change or kill switch can therefore take up to about five minutes to reach a running app; lower `configRefreshInterval` if you need faster propagation.
- The first `flag` read per flag and the first `experiment` read per experiment emit `$flag_exposure` / `$experiment_exposure`. `inspect(_:default:)` never emits exposure.
- Events from macOS, tvOS, and watchOS currently report `platform: "ios"`; the OS name is recorded separately on the device.

## Configuration

`SheepitConfig.init(apiKey:…)`; every parameter except `apiKey` has a default.

| Parameter                | Type                                            | Default                               |
| ------------------------ | ----------------------------------------------- | ------------------------------------- |
| `apiKey`                 | `String` (required)                             | —                                     |
| `environment`            | `String`                                        | `"production"`                        |
| `apiUrl`                 | `String`                                        | `"https://api.sheepit.ai"`            |
| `flushInterval`          | `TimeInterval` (s)                              | `5.0`                                 |
| `flushSize`              | `Int`                                           | `20`                                  |
| `configRefreshInterval`  | `TimeInterval` (s)                              | `300`                                 |
| `maxQueueSize`           | `Int`                                           | `1000`                                |
| `retryAttempts`          | `Int`                                           | `3`                                   |
| `debug`                  | `Bool`                                          | `false`                               |
| `onEvent`                | `(@Sendable (String, [String: Any]?) -> Void)?` | `nil`                                 |
| `performance`            | `PerformanceConfig`                             | `.init()`: **off** (`enabled: false`) |
| `crashes`                | `CrashConfig`                                   | `.init()`: **on** (`enabled: true`)   |
| `appVersion`             | `String?`                                       | `nil` → `CFBundleShortVersionString`  |
| `onDiagnostic`           | `DiagnosticListener?`                           | `nil`                                 |
| `diagnosticBufferSize`   | `Int`                                           | `100`                                 |
| `allowFlagOverrides`     | `Bool?`                                         | `nil` (follows `debug`)               |
| `allowSecretKeyInClient` | `Bool`                                          | `false` (tests only)                  |
| `requestTelemetryHosts`  | `[String]`                                      | `[]` (records no requests)            |

Pass your git SHA or build tag as `appVersion` so events attribute to the right release; the marketing version rarely matches a release record.

### Configure with xcconfig

Keep the key and URL out of Swift source: set them per build configuration in `.xcconfig` files, expose them through Info.plist, and build the config with `SheepitConfig(bundle:)`.

**1. Create one xcconfig per build configuration.** Values take **no quotes**. Write `SHEEPIT_API_URL` as a **bare host**, optionally with a path. An xcconfig treats `//` as the start of a comment, so `https://sheepit.example.com` would reach the app as `https:`. SheepitKit prepends `https://` itself.

```
// Debug.xcconfig
SHEEPIT_API_KEY = lp_pub_dev_...
SHEEPIT_API_URL = sheepit-staging.example.com
SHEEPIT_ENVIRONMENT = development
```

```
// Release.xcconfig
SHEEPIT_API_KEY = lp_pub_prd_...
SHEEPIT_API_URL = sheepit.example.com/_sheepit
SHEEPIT_ENVIRONMENT = production
```

A bare host always becomes `https://`. To reach a plain-HTTP server during local development, write the full URL with an empty build setting between the slashes, so the xcconfig does not see `//`:

```
// Debug.xcconfig, local server without TLS
SHEEPIT_API_URL = http:/$()/localhost:3001
```

No path segment may contain `//` either: everything after it is cut off, and SheepitKit cannot detect a cut in the middle of a path.

**2. Assign the files under Project → Info → Configurations.** Pick `Debug.xcconfig` for Debug and `Release.xcconfig` for Release on your app target. Until a file is assigned there, its settings are not applied.

**3. Add the keys in the target's Info tab** (Custom iOS Target Properties). New Xcode projects have no Info.plist file (`GENERATE_INFOPLIST_FILE = YES`). Xcode creates one at build time and merges these entries into it:

| Key                  | Type   | Value                    |
| -------------------- | ------ | ------------------------ |
| `SheepitAPIKey`      | String | `$(SHEEPIT_API_KEY)`     |
| `SheepitAPIURL`      | String | `$(SHEEPIT_API_URL)`     |
| `SheepitEnvironment` | String | `$(SHEEPIT_ENVIRONMENT)` |

Key names are case-sensitive. A variant that differs only in case, spaces or punctuation (`SheepitAPIUrl`, `SHEEPIT_API_URL`) is reported rather than ignored: for `SheepitAPIKey` and `SheepitAPIURL` the client is inert, and for `SheepitEnvironment` it warns and uses `"production"`. If your project already has an Info.plist file, add the same entries to it instead:

```xml
<key>SheepitAPIKey</key>
<string>$(SHEEPIT_API_KEY)</string>
<key>SheepitAPIURL</key>
<string>$(SHEEPIT_API_URL)</string>
<key>SheepitEnvironment</key>
<string>$(SHEEPIT_ENVIRONMENT)</string>
```

App extensions and widgets read their own bundle, not the app's. Each extension target that uses SheepitKit needs these keys in its own Info tab.

**4. Build the config from the bundle:**

```swift
var config = SheepitConfig(bundle: .main)
config.appVersion = "<git sha>" // any other property can still be set here
let sheepit = SheepitClient.create(config: config)
```

| Key                  | Absent                            | Present but empty, an unexpanded `$(…)`, or cut off at `//` | Spelled with different case or punctuation |
| -------------------- | --------------------------------- | ----------------------------------------------------------- | ------------------------------------------ |
| `SheepitAPIKey`      | inert client                      | inert client                                                | inert client                               |
| `SheepitAPIURL`      | `https://api.sheepit.ai` (hosted) | inert client — **never** the hosted default                 | inert client                               |
| `SheepitEnvironment` | `"production"`                    | inert client                                                | warning, `"production"`                    |

A misconfigured plist never crashes the app. The client is inert, like one with a rejected key, and `status().rejectionReason` names the key and the fix. The same message is printed to the Xcode console as a `[Sheepit]` warning. No message repeats a configured `SheepitAPIURL` or `SheepitAPIKey` value, since a URL can carry credentials. When `SheepitAPIURL` is absent, the started client logs the hosted host it is using, so you can confirm it is not pointed at the wrong install. If you self-host, define `SHEEPIT_API_URL` in **every** configuration: an empty value does not fall back to the hosted API, because that would send your users' events to Sheepit's cloud. If you use the hosted API, leave `SheepitAPIURL` out.

Setting `config.apiUrl` or `config.environment` yourself after `SheepitConfig(bundle:)` replaces the Info.plist value, including a broken one. `apiKey` is a `let` and cannot be replaced: fix the plist, or use `SheepitConfig(apiKey:…)`.

TestFlight and the App Store ship the same binary, so the URL compiled into the build you test in TestFlight is the one App Store users get. Archive with the configuration you mean to release.

## API reference

| Symbol                                                              | Purpose                                                            |
| ------------------------------------------------------------------- | ------------------------------------------------------------------ |
| `SheepitClient.create(config:)`                                     | Create an instance (preferred for SwiftUI)                         |
| `SheepitClient.initialize(config:)` / `SheepitClient.shared`        | Singleton create and accessor                                      |
| `track(_:properties:)`                                              | Send an event                                                      |
| `flag(_:default:)`                                                  | Evaluate a flag; returns a `FlagValue`                             |
| `experiment(_:)`                                                    | Get a `SheepitExperimentResult` (with `.variant`)                  |
| `identify(userId:)` / `reset()`                                     | Set or clear user identity (no traits — see below)                 |
| `flush() async` / `destroy()`                                       | Send queued events / tear down                                     |
| `screen(_:properties:)`                                             | Track a `$screen` event and set the crash context's screen         |
| `captureError(_:error:attributes:)`                                 | Report a handled (non-fatal) error as a `$error` event             |
| `recordRequest(method:url:status:durationMs:responseBytes:error:)`  | Report a failed first-party HTTP request as a `$http_error` event  |
| `addBreadcrumb(category:message:)` / `setScreen(_:)`                | Context attached to crash reports                                  |
| `startSpan(_:attributes:)` / `endSpan(_:)` / `markFirstFrame()`     | Performance spans (when `performance.enabled`)                     |
| `FlagValue`                                                         | Enum: `.bool`, `.string`, `.int`, `.double`, `.json`               |
| `overrideFlag(_:value:)` / `clearOverride(_:)` / `clearOverrides()` | Set/clear debug flag overrides                                     |
| `getOverrides()`                                                    | Read the debug flag overrides currently set                        |
| `inspect(_:default:)`                                               | Non-exposing diagnostic read — `SheepitFlagInspection` (dev menu)  |
| `knownFlagKeys()`                                                   | Sorted union of remote-valued + overridden flag keys               |
| `flagChanges()`                                                     | `AsyncStream<Void>` — fires on config apply / override set / clear |
| `status()`                                                          | Queue depths, connectivity, `lastFlushAt`, device / user id        |
| `diagnostics()` / `getRecentDiagnostics()`                          | Live and buffered internal SDK events                              |
| `SheepitConfig`                                                     | Configuration, including optional `crashes` and `performance`      |

**`identify()` takes no traits.** 🔴 The `traits` parameter was **removed in 0.7.0** — `identify(userId:traits:)` no longer exists, so a call site passing them is a compile error. It is a deliberate break rather than a silent no-op: the values used to be merged into a server-side column that survived both `reset()` and a GDPR erase, and they could never be targeted on again. Send what you need as event properties for dashboards and experiment/release metrics instead: `track("plan_selected", properties: ["plan": "pro"])` — event properties are not evaluable by flag/experiment rules, so this does not restore targeting. To keep targeting the value, add the user to a group (`POST /v1/groups/:id/members`, target `user_group`) or call `POST /v1/devices/:deviceId/identify` directly with `attributes` (same retention trade-off: survives `reset()`, not cleared by GDPR end-user erase). The web SDK has always behaved this way. ⚠️ **Upgrading from 0.6.0? This is about new traits only** — whatever 0.6.0 already uploaded stays on the device row and keeps matching targeting rules. See the [CHANGELOG](CHANGELOG.md).

**Crash capture is ON by default**; performance monitoring is OFF by default. Both are configured through `SheepitConfig` (`crashes:` / `performance:`).

A crash is uploaded on the next launch. If that upload fails for a reason a retry can fix, the report is kept and retried on each later launch. Only a 5xx counts as an attempt, and 5 counted attempts drop it; offline, timeouts, the daily cap's 402, a 429 and a 401/403/404 from a key, proxy or firewall do not count and are bounded by age alone (7 days), so a crash waits out a misconfigured proxy. Each launch makes one HTTP attempt per report. A 400, 413 or 422 drops it at once. At most 5 reports wait at a time. When XCTest is loaded in the process — your unit tests, including ones hosted in your app — the retry queue lives in a temporary directory unique to that run, so a test run never uploads or clears a real queue. The live crash file is not moved, so an app-hosted test run adopts a crash left over from before it into that temporary queue, and the report is lost if the run cannot upload it. To see a crash reported, reproduce it outside a test run. Every decision emits a `transport.crash_upload` diagnostic whose `data["outcome"]` is `uploaded`, `retained_for_retry`, `dropped_non_retryable`, `dropped_retry_exhausted`, `dropped_queue_full`, `dropped_unreadable` or `dropped_unretainable`.

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
/// - `Flag.allCases` (from `sheepit codegen` with `codegen.outputs.swift`
///   set in sheepit.config.json) — works on a fresh
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

### Screens

Call `screen(_:properties:)` when the user arrives on a screen. It tracks a `$screen` event with a `screen` property and sets the screen that a crash report carries — one call for both:

```swift
struct CheckoutView: View {
  @Environment(\.sheepit) private var sheepit

  var body: some View {
    CheckoutForm()
      .onAppear { sheepit?.screen("Checkout", properties: ["cart_items": 3]) }
  }
}
```

- **Nothing is automatic.** The SDK does not swizzle UIKit or observe SwiftUI navigation; you decide what a "screen" is and when it counts.
- The name is trimmed, stripped of U+0000 and capped at 255 UTF-8 bytes (the crash context's buffer), cut on a character boundary. A name that ends up empty is dropped with a `transport.invalid_screen_name` diagnostic.
- `screen` is always the name you passed: a `screen` key in `properties` is overwritten.
- `setScreen(_:)` still exists and sets only the crash context, with no event.

Chart screens by filtering `$screen` and breaking down by the `screen` property.

### Errors

Call `captureError(_:error:attributes:)` for an error your app handled — one it caught and recovered from, so no crash report will ever tell you about it:

```swift
do {
  try await checkout.submit(order)
} catch {
  sheepit?.captureError("Checkout submit failed", error: error, attributes: ["step": "payment"])
}
```

It sends a `$error` event through the same path as `track()`, so it carries the same session, device, user, app version and experiment assignments as every other event — the platform and OS included, in the event context (the context's `platform` is currently always `"ios"`, even on macOS, tvOS and watchOS — the OS name is recorded separately; a known gap, queued); there is no separate `platform` property, so a `platform` key in your `attributes` is kept as it is — and it adds an `error` breadcrumb with the message, so a crash later in the session shows it.

| Property               | Value                                                                                                                                                                             |
| ---------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `message`              | The message you passed                                                                                                                                                            |
| `type`                 | `"handled"`                                                                                                                                                                       |
| `origin`               | `"app"`                                                                                                                                                                           |
| `error_type`           | With `error:` only. The module-qualified type, e.g. `MyApp.CheckoutError`. Foundation's errors (`URLError`, `CocoaError`, …) all report `NSError` — group those by `error_domain` |
| `error_description`    | With `error:` only. See below — for a Swift enum it includes the associated values, e.g. `declined(code: 51)`                                                                     |
| `error_domain`         | With `error:` only. `(error as NSError).domain` — the type name for a Swift error                                                                                                 |
| `error_code`           | With `error:` only. `(error as NSError).code` — the case index for a Swift enum                                                                                                   |
| `suppressed_count`     | Only when non-zero: repeats of this same error that were suppressed before this one                                                                                               |
| `dropped_count`        | Only when non-zero: errors of any kind dropped by the global rate limit before this one                                                                                           |
| `attributes_truncated` | `true` only when some of your attributes were dropped for a size limit (below)                                                                                                    |
| your `attributes`      | Under their own keys. A key that collides with one above (or with `source`) is stored as `attr_<key>`; if that is taken too, it is dropped                                        |

**The SDK sends exactly what it is given — redact URLs, tokens and PII before calling.** That includes an error's description string, which can name the host or file it failed on. Foundation's own file errors usually carry the path in `userInfo` (for example `Data(contentsOf:)` → `NSCocoaErrorDomain 260` with a `userInfo`), so their `NSLocalizedDescriptionKey` text — e.g. `"The file “report.pdf” couldn’t be opened…"` — is sent as given; and for an error with an empty `userInfo`, the text Foundation composes can still name a file or host you never passed in.

How `error_description` is built:

- **An `NSError`** (or one of Foundation's error structs, such as `URLError`, `CocoaError` and `POSIXError`): `"<domain> <code>: <text>"`. `userInfo` is only ever read through CoreFoundation and never printed.
  - **Empty `userInfo`, `NSPOSIXErrorDomain`**: the text is the C library's `strerror_r` message (`"NSPOSIXErrorDomain 2: No such file or directory"`); Foundation is never asked.
  - **Empty `userInfo`, any other domain**: Foundation's own `localizedDescription` (e.g. `"NSCocoaErrorDomain 4: The file doesn’t exist."`), but only when the error's class does not override `localizedDescription` or `localizedFailureReason`, AND the domain is `NSCocoaErrorDomain` or has no `NSError.setUserInfoValueProvider(forDomain:)` provider registered. A provider runs inside `localizedDescription`, and one that returns a non-string or a self-containing value, or raises, can crash your app; registration is process-wide, so any library can register one, and Foundation accepts a replacement on every one of its domains except `NSCocoaErrorDomain` (measured on macOS; not verified on an iOS 16 runtime). So with a provider registered — including Foundation's own on `NSOSStatusErrorDomain` and `NSMachErrorDomain` — the text is just `"<domain> <code>"`, and a provider's text is never sent, even a well-formed one. Residuals: a process-wide swizzle of `-[NSError localizedDescription]` (what APM libraries do) runs on the Cocoa and provider-free paths and can crash the host if it misbehaves — and provider-free (`URLError`, CFNetwork, your own domains) is the common case, so a broken swizzle would reach most real errors; a provider registered at the very moment of the call is a race.
  - **Non-empty `userInfo`**: Foundation is never asked, because composing its text reads `userInfo` — a value there that contains itself overflows the stack, a non-string under the description key raises an exception Swift cannot catch, and even a non-string KEY aborts a Swift read of `userInfo`; each can crash your app. The text is the `NSLocalizedDescriptionKey` value, or else the `NSLocalizedFailureReasonErrorKey` value, used only when it is a string; otherwise just `"<domain> <code>"`.
- **A Swift error with its own `description`** (its type conforms to `CustomStringConvertible` / `CustomDebugStringConvertible`): that description, used verbatim — it is your code, so keeping it safe and free of PII is your responsibility.
- **An error class** (other than `NSError`): an `NSObject` subclass always reports its type name — its `description` is never called, since `NSObject`'s prints a per-launch address (`<MyError: 0x…>`), Foundation subclasses such as `NSData` or `NSNumber` raise, and an override can recurse. A Swift class uses its own description only when it conforms to `CustomStringConvertible` / `CustomDebugStringConvertible`; otherwise its type name.
- **Any other Swift error:** Swift's default shape — `declined(code: 51, reason: "insufficient_funds")`, `Failure(field: 1)` — built by a bounded walk: 3 levels deep, 50 values per level, `Optional`s unwrapped. A class instance or Foundation collection inside it prints as `<TypeName>`, never as its contents.

Limits:

- Every string value — the message, the error fields and your attribute strings — is cut to **500 characters and 2 KB**, on a character boundary.
- Attribute keys are cut to **64 characters and 256 bytes**. A key that, once cut, matches one already kept is dropped (the first in sorted order wins).
- At most **50 attributes**, and across all of them at most **200 values and about 8 KB** (keys and values as JSON, nested ones included). Attributes are taken in sorted key order; the first one that does not fit is dropped whole, with every one after it, and the event carries `attributes_truncated: true`. Together these keep one event well under the server's 32 KB per-event limit: the largest event the caps allow measures about 18 KB.
- Nested containers go at most 3 levels deep; a deeper one is sent as `"<array of N>"` / `"<dictionary of N>"`. A nested array keeps its first 50 elements and a nested dictionary its 50 smallest string keys (a key that is not a string is skipped); losing any sets `attributes_truncated`.
- A value JSON cannot carry (`Date`, `URL`, `UUID`, `Float`, `Int64`, a `NaN` or infinite `Double`, …) is sent as text, never as `null`. A class instance or Foundation collection that is not plain JSON is sent as a `<TypeName>` placeholder, never described. A dictionary whose keys are not all typed `String` — such as `[AnyHashable: Any]`, e.g. a `Notification.userInfo` — is sent as text.
- **Rate limit.** The same error — same message, `error_type`, `error_domain` and `error_code`, compared after each is cut to its limit (so two messages that share their first 500 characters count as the same error) — is sent at most once per **60 seconds**; repeats are counted and reported as `suppressed_count` on the next one sent after the window. Across all errors, at most **30 are sent per rolling 60 seconds**; the excess is counted into `dropped_count` on the next one sent. Suppression emits an `error_capture.suppressed` diagnostic, at most once a minute. Both windows run on the device's uptime clock, which counts awake time only — a window that spans the device sleeping lasts longer in wall time — and which changing the date cannot move. The counts are taken when the event is handed to `track()`: if the client is destroyed at that instant, or the event is later evicted from a full queue, its counts go with it.
- Two `private` error types with the **same name in the same module** report the same `error_type` and `error_domain`, and so share a rate-limit signature when the message and code match too. That is the price of a type name that stays the same from launch to launch; their `error_description` still tells them apart.
- It never throws and never blocks beyond `track()`; it is safe from any thread. A `captureError` call made from inside your `onEvent` callback while another `captureError` is running on that thread is dropped with an `error_capture.reentrant_dropped` diagnostic instead of recursing.

To chart your app's handled errors, filter `$error` by `origin = app` (or `type = handled`). The SDK's own internal failures are also `$error` events, with `origin = sdk` and `type = sdk_internal`. Handled errors do not affect release health (error rate, health score, alerts); they are reported separately as `handled_errors` on `GET /v1/releases/:id/health` (and the MCP `release_health` tool).

### Network request failures

Call `recordRequest(method:url:status:durationMs:responseBytes:error:)` after each request your app makes to its own backend. It records only **failures** — a status of 400 or above, or `status: nil` when no response arrived at all (pass the reason as `error`); a status of `0` or below is treated the same as `nil`. A successful call returns at once and sends nothing, so it is cheap to call for every request. It is **opt-in**: nothing is recorded until you list your API hosts in `SheepitConfig.requestTelemetryHosts`.

```swift
var config = SheepitConfig(apiKey: "lp_pub_...")
config.requestTelemetryHosts = ["api.example.com", "*.cdn.example.com"]
let sheepit = SheepitClient.create(config: config)

guard let url = request.url else { throw URLError(.badURL) }
let method = request.httpMethod ?? "GET"
let start = Date()
do {
  let (data, response) = try await URLSession.shared.data(for: request)
  sheepit.recordRequest(
    method: method,
    url: url,
    status: (response as? HTTPURLResponse)?.statusCode,
    durationMs: Date().timeIntervalSince(start) * 1000,
    responseBytes: data.count
  )
} catch {
  sheepit.recordRequest(method: method, url: url, status: nil,
                        durationMs: Date().timeIntervalSince(start) * 1000, error: error)
  throw error
}
```

It sends a `$http_error` event — the same event the web SDK's `autoCaptureHttpErrors` sends — through the same path as `track()`, so it carries the same session, device, user, app version and experiment assignments as every other event. It also adds an `http` breadcrumb (`"GET api.example.com/v1/feed 503"`), so a crash later in the session shows it.

| Property           | Value                                                                                                                                                                                                      |
| ------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `url`              | Scheme, host, port (only when not the scheme's default) and path, e.g. `https://api.example.com/v1/orders/42` — **no query**                                                                               |
| `host`             | The lowercased host, as Foundation decodes it (an IDN's `xn--` form arrives as Unicode — see Allowlist)                                                                                                    |
| `path`             | The URL path, exactly as it was percent-encoded; `/` when empty                                                                                                                                            |
| `method`           | Uppercased, cut to 32 characters; an empty method is sent as `GET`                                                                                                                                         |
| `status`           | The HTTP status, or `0` when no response arrived (as on the web) — also when you passed `0` or a negative value                                                                                            |
| `latency_ms`       | `durationMs` rounded to a whole number; a negative, `NaN` or infinite value is sent as `0`                                                                                                                 |
| `kind`             | `"http_error"` for a status, `"network_failure"` when no response arrived (the web SDK's values)                                                                                                           |
| `origin`           | `"app"`                                                                                                                                                                                                    |
| `response_bytes`   | Only when you passed it and it is not negative (`URLResponse.expectedContentLength` is `-1` when unknown)                                                                                                  |
| `error_name`       | With `error:` only. The module-qualified type, as `error_type` in `captureError` — `URLError` and other Foundation errors report `NSError`                                                                 |
| `error_message`    | With `error:` only. Built exactly as `captureError`'s `error_description` (see [Errors](#errors)), always starting `"<domain> <code>"` (e.g. `"NSURLErrorDomain -1001"`, then the OS's own localized text) |
| `error_domain`     | With `error:` only. `(error as NSError).domain`                                                                                                                                                            |
| `error_code`       | With `error:` only. `(error as NSError).code`                                                                                                                                                              |
| `aborted`          | Network failures with an `error:` only. `true` when it is `URLError.cancelled`                                                                                                                             |
| `suppressed_count` | Only when non-zero: repeats of this same failure that were suppressed before this one                                                                                                                      |
| `dropped_count`    | Only when non-zero: failures of any kind dropped by the global rate limit before this one                                                                                                                  |

**Privacy.** The SDK never sends the query string, the fragment, userinfo (`user:password@`), headers or bodies. **It sends the path verbatim** — if your paths carry tokens, emails or other personal data (`/reset/<token>`, `/users/jane@example.com`), do not record those requests, or call `recordRequest` with a URL you have already rewritten (`/reset/:token`). Path parameters after `;` (e.g. `;jsessionid=…`) are part of the path and are sent verbatim too. **`error_message` is the error's own description** — if your error type puts a URL, token or user data in its message, that is sent; redact it in your error type, or pass a sanitized error. Unlike the web SDK, there is no `request_id`, `response_headers` or `cookie_names`: those come from headers.

**Allowlist.** Each entry in `requestTelemetryHosts` is a bare host name, matched exactly and case-insensitively: `api.example.com` does not cover `v2.api.example.com`. `*.example.com` covers every subdomain of `example.com`, but not `example.com` itself — list that separately. A wildcard over a single label (`*.com`, and also `*.localhost` or `*.test` for local development) is refused — list the exact host instead (`api.localhost`); there is no public-suffix list, so a broad entry such as `*.co.uk` is still accepted — don't write one. An entry with a scheme, port or path (`https://api.example.com`, `api.example.com:8443`) matches nothing, nor does one that is only valid before percent-decoding (`exa%2Fmple.com`), has a leading dot or an empty label (`.example.com`, `example..com`), or carries a control character; all unusable entries are reported together, once, as a `request_telemetry.invalid_host` diagnostic. The list is read when the client is created.

International domain names: hosts are compared as Foundation's `URLComponents` returns them, and the SDK passes each entry through the same API, so the two are canonicalized alike on the same OS. Measured on macOS 27, an `xn--` (punycode) host is decoded — `https://xn--bcher-kva.example/` is recorded with `host` `bücher.example` — and an entry written in either form (`xn--bcher-kva.example` or `bücher.example`) matches it. The `xn--` form of an entry is the safer choice; other OS releases were not measured.

**The SDK's own API is never recorded**, even if you list its host: any URL on `apiUrl`'s host at or under `apiUrl`'s path, whatever its scheme or port — so a network interceptor that also sees the SDK's own uploads cannot feed them back. 🔴 **When `apiUrl` has no path, that is every request to its host.** A self-hosted install serving the SDK from your app's own origin (`apiUrl: "https://app.example.com"`) therefore records nothing on `app.example.com`, and the client says so once with a `request_telemetry.api_host_excluded` diagnostic. The remedy is to serve the SDK under a path prefix — `apiUrl: "https://app.example.com/_sheepit"` — so only that prefix is excluded. A proxy that rewrites the SDK's requests to a different host defeats the exclusion; that loop is still bounded by the rate limit below.

Limits:

- The same failure — same method, host, path and status (or `network_failure`), compared after each is cut to its limit — is sent at most once per **60 seconds**; repeats are counted as `suppressed_count` on the next one sent after the window. Different query strings are the same failure. Across all requests, at most **30 are sent per rolling 60 seconds**; the excess is counted into `dropped_count`. Suppression emits a `request_telemetry.suppressed` diagnostic, at most once a minute. The windows run on the same uptime clock as `captureError`'s, but the limits are **separate**: a burst of failing requests cannot use up `captureError`'s 30, nor the reverse.
- Every string is cut to **500 characters and 2 KB** (the method to 32 characters).
- No sampling: every failure that passes the allowlist goes to the rate limit.
- **Volumes are not comparable with the web.** The web SDK keeps a single last-failure slot: it drops a failure only when it immediately repeats the previous one (same method, URL — query included — and status) within **1 second**, so alternating failures are never deduplicated; this SDK suppresses the same method + host + path + status for **60 seconds** and caps at 30 per 60 seconds. Compare rates within a platform, not across.
- It never throws and never blocks beyond `track()`; it is safe from any thread. A `recordRequest` call made from inside your `onEvent` callback while another `recordRequest` is running on that thread is dropped with a `request_telemetry.reentrant_dropped` diagnostic instead of recursing. A no-op once the client is destroyed.

To chart them, filter `$http_error` by `origin = app` (the web SDK's rows carry no `origin`), and break down by `path` or `status`. The built-in "HTTP errors by status" widgets already include them.

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

**How do I get type-safe flags?** `sheepit codegen` from [@sheepit-ai/cli](https://www.npmjs.com/package/@sheepit-ai/cli) generates a Swift `Flag` enum (`String`, `CaseIterable`) when `codegen.outputs.swift` is set in `sheepit.config.json`. Reference flags by `Flag.<name>.rawValue`.

**How does experiment bucketing work?** The API assigns the variant; the SDK only caches the result. There is no on-device bucketing.

**Is the SDK concurrency-safe?** Yes, within one process. `SheepitClient` is `Sendable` and its internals are actor-isolated, so its public methods are safe to call from any thread. That guarantee does not extend across process boundaries: `create()`/`initialize()` persist device and session identity under a fixed `UserDefaults` suite that is not an App Group id, so **do not link SheepitKit into an app extension alongside a host app**, and do not run two independent processes against the same install — each process would compute its own fresh device id and independently report its own `$app_install` and `$session_start(is_first_session: true)`, double-counting a single real install.

## Links

- [`@sheepit-ai/sdk-js`](https://www.npmjs.com/package/@sheepit-ai/sdk-js) · [`@sheepit-ai/react`](https://www.npmjs.com/package/@sheepit-ai/react) · [`@sheepit-ai/server`](https://www.npmjs.com/package/@sheepit-ai/server) · [`@sheepit-ai/cli`](https://www.npmjs.com/package/@sheepit-ai/cli)
- Android and .NET SDKs: coming soon.
- [sheepit.ai](https://www.sheepit.ai)

## License

MIT. Copyright (c) 2026 GoaTech AI LLC. See [LICENSE](./LICENSE).
