# Changelog

All notable changes to `SheepitKit` (the Sheepit Swift SDK).

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/); the
package uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

> Published to the SPM mirror
> [`goatech-ai/sheepit-swift`](https://github.com/goatech-ai/sheepit-swift) by
> `.github/workflows/publish-sdk-swift.yml` when a `swift-v<version>` tag is
> pushed.
>
> The version here must always equal `SDKDefaults.sdkVersion` — it is stamped
> on every ingested event, so a mismatch misattributes release-health data to
> a version that does not exist. The mirror workflow enforces this before it
> tags.

> **🔴 Version policy: this package stays on `0.x` until the API is stable.**
> `1.0.0` and `1.0.1` were cut too early — they claimed stability the surface
> did not have, and breaking changes kept coming. Those two tags stay on the
> mirror (deleting a published tag breaks whoever pinned it) but the `1.x`
> line is **abandoned; it will receive no further releases**. Development
> continues on `0.x`, where SemVer permits breaking changes in a minor bump,
> and **`2.0.0` is reserved for the first genuinely stable release.**
>
> Consequence to state plainly when anyone integrates: SPM's `from: "1.0.0"`
> resolves `>=1.0.0 <2.0.0`, so **a consumer pinned to `1.0.x` will never
> receive a `0.x` release.** They are frozen until they re-pin to `0.x`.

## [0.3.0]

### Changed — BREAKING

- **Module renamed `SheepitSDK` → `SheepitKit`, entry type `Sheepit` → `SheepitClient`.**
  `import SheepitSDK` becomes `import SheepitKit`, and `Sheepit.create(config:)` /
  `Sheepit.initialize(config:)` / `Sheepit.shared` become `SheepitClient.*`.
  As with the `0.x` → `1.0.0` module rename there is no shim: Swift has no
  module-alias mechanism, so the old import cannot be kept compiling.

  **Why not `SheepitSDK`.** Modern Swift SDKs do not put `SDK` in the module
  name (Firebase, Sentry, PostHog, Amplitude), and it reads dated.

  **Why not plain `Sheepit`.** It was tried and it does not build. The Mission
  Control app target in `apps/ios` is itself named `Sheepit`, so a library
  product of the same name makes Xcode emit `Multiple commands produce
Sheepit.swiftmodule` — and since that app is meant to dogfood this SDK, it
  would have been an app importing itself. `*Kit` is Apple's own idiom
  (`WidgetKit`, `StoreKit`, `ActivityKit`).

  **Why the type is not `SheepitKit` either.** A type named after its module
  collides: the first pass of this rename produced `cannot call value of
non-function type 'module<Sheepit>'`. Sentry has `SentrySDK` and Firebase has
  `FirebaseApp` for the same reason. `SheepitClient` keeps the module name free
  as a namespace.

  This leaves room for a later product split — `SheepitAnalytics`,
  `SheepitCrash`, `SheepitPerformance` as peers, with `SheepitKit` as the core
  holding the connection, the same shape as `FirebaseCore` + `FirebaseApp`.
  Not done here and not scheduled: the trigger is a customer who cannot accept
  a subsystem's side effects (a second crash reporter contending for the same
  signal handlers is the likeliest), not a size target. Note `SheepitCore` is
  **not** available as a name — `apps/ios/Packages/SheepitCore` already exists
  and the app links both.

  **Unlike the `0.x` → `1.0.0` rename, this one happens after a published
  tag** — `1.0.1` is on the SPM mirror, so anyone already pinned there keeps a
  working build but receives nothing further (see "Version policy" above).
  It rides a **minor** bump because the package is back on `0.x`, where SemVer
  allows exactly that; it is not a free pre-tag correction either.

## [1.0.1]

Published to the mirror but never recorded here — backfilled 2026-09-09 from
`git diff 1.0.0 1.0.1` on `goatech-ai/sheepit-swift`.

### Changed

- Default API host `https://api.goatech.ai` → `https://api.sheepit.ai`.
  Both remain live and co-equal on the same service, so this changed nothing
  for existing installs; `api.goatech.ai` is never retired.
- `SDKDefaults.sdkVersion` `1.0.0` → `1.0.1`.

## [1.0.0]

### Changed — BREAKING

- **Module renamed `GoaTechSDK` → `SheepitSDK`.** `import GoaTechSDK` becomes
  `import SheepitSDK`. Unlike the `Sheepit*` type-prefix renames in `0.2.0`,
  there is no deprecation shim — Swift has no module-alias mechanism, so the
  old import cannot be kept compiling. Done now, before the first tag: zero
  external consumers exist today, and after a tag a module rename breaks
  every customer's import with no migration path. The public mirror moves
  with it, from `goatech-ai/sdk-swift` to `goatech-ai/sheepit-swift`.
- **First tagged release.** Shipping directly as `1.0.0` rather than a `0.x`
  pre-release: the public API (module name, `Sheepit*` types, storage key
  prefix) was already revised in `0.2.0` specifically to be tag-ready, so
  there is nothing left to keep provisional.

### Added

- **Non-exposing flag inspection API**, for building a customer-facing debug
  menu without polluting exposure/experiment data:
  - `Sheepit.inspect(_:default:) -> SheepitFlagInspection` — a diagnostic
    read of a single flag key (`remoteValue`, `overrideValue`,
    `effectiveValue`, and a `SheepitFlagValueSource` of `.remote` /
    `.override` / `.fallback`). Does NOT fire exposure, so a dev menu can
    sweep every known key without polluting flag/experiment exposure data.
  - `Sheepit.knownFlagKeys() -> [String]` — every flag key with either a
    remote value (last-applied `/v1/config`) or a local override.
  - `Sheepit.clearOverride(_ key:)` — clears a single flag's debug override,
    leaving others in place.
  - `Sheepit.flagChanges() -> AsyncStream<Void>` — fires on config apply,
    override set, and override clear; multi-subscriber, for driving a
    SwiftUI dev-menu screen's re-render.
  - `SheepitConfig.allowFlagOverrides` gates whether `overrideFlag(_:value:)`
    can _write_ an override at all (defaults to following `debug`) — off by
    default, so a production build can't accidentally ship a debug menu that
    mutates flags.

### Fixed

- **`clearOverrides()` / `clearOverride(_:)` now always purge the on-disk
  override**, regardless of `allowFlagOverrides`. Previously, flipping
  `allowFlagOverrides` off after an override had been set left the stale
  override on disk — readable again (and silently re-applied) the next time
  the flag gate was flipped back on. Clearing is destructive-only; the gate
  now only governs _setting_ an override, not removing one.

## [0.2.0]

### Changed — BREAKING

- **Public type prefixes unified on `Sheepit*`.** `GoaTech` → `Sheepit`,
  `GoaTechConfig` → `SheepitConfig`, `GTExperimentResult` →
  `SheepitExperimentResult`, `GTPerformanceSummary` →
  `SheepitPerformanceSummary`. This matches `@sheepit-ai/sdk-js`, where the
  same types are already `Sheepit` and `SheepitConfig`. Deprecated
  typealiases keep the old names compiling with an Xcode fix-it.

  Done deliberately **before** the first public tag: afterwards every rename
  costs a customer a deprecation cycle. The internal log prefix flipped from
  `[GoaTech]` to `[Sheepit]` in the same pass, matching sdk-js 1.1.0.

  **The module stayed `GoaTechSDK`** at this point — `import GoaTechSDK` was
  unchanged. Renaming it would change every customer's import line, so that
  call was deferred to a future major. (It happened in `1.0.0`, above —
  still before the first tag, so still free.)

  Note that the shims emit deprecation warnings, so a consumer building the
  old names with `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` will fail rather than
  warn. That is the intended pressure to migrate, but it means "old code
  keeps compiling" holds only where warnings are not errors.

- **Storage keys renamed `lp_*` → `gt_*`**, matching `STORAGE_KEYS` in
  `@sheepit-ai/sdk-js`. Existing installs are migrated automatically on
  first launch by `StorageMigration`, which copies each legacy value to its
  new key before anything reads storage — no device id, identity, offline
  queue, or experiment assignment is lost. `lp_debug_overrides` is
  deliberately NOT renamed (the JS SDK keeps it on the old prefix too).
- **`LPSpan` → `SheepitSpan`**, **`LPBreadcrumb` → `SheepitBreadcrumb`**.
  Deprecated typealiases keep the old names compiling with an Xcode fix-it.
  **These shims should be deleted one minor version after the first public
  tag** — see `Sources/SheepitSDK/Types/DeprecatedAliases.swift`.

### Fixed

- **`SheepitBreadcrumb`, `SDKStatus` and `GTPerformanceSummary` gained public
  initializers.** Swift only synthesises an _internal_ memberwise init when a
  struct declares none, so these types were readable but not constructible
  outside the module — a customer could call `status()` but could not fixture
  one in their own tests.

### Known limitation — downgrade then upgrade

The migration is one-pass and guarded by a marker key. If a device runs
0.2.0+ (marker set, `gt_*` populated), then **downgrades** to a build using
`lp_*`, then upgrades again, the data written during the downgrade window is
not migrated: the marker short-circuits the second run and the pre-downgrade
`gt_*` values win. Not reachable through the App Store, which does not allow
downgrades, but it is reachable via TestFlight rollbacks and enterprise
distribution.

## [0.1.0]

Pre-release development. Notable changes shipped without a changelog:

- Feature flags with JSON (`.json`) values, background flush on app
  suspension, transport error-classing (4xx dropped / 429 re-queued with
  `Retry-After` back-off / 5xx offline-queued), and a `DiagnosticBus`.
- `PrivacyInfo.xcprivacy` declaring collected data types and required-reason
  API usage.

## Known issues

Tracked here because they are SDK-scoped and this file ships to the public
mirror, so it is where a consumer looks:

- Two ThreadSanitizer data races in the C crash handler
  (`sheepit_crash_handler.c`, `sheepit_nsexception_handler.m`) on the global
  `s_report` when `install()` runs concurrently. Pre-existing; reproduces on
  an unmodified checkout.
- `identify()` does not rotate the session id on an identity change, unlike
  the JS SDK's `resetSessionOnly()`.
- `FlagManager`'s debug overrides use `UserDefaults.standard` rather than the
  SDK's `ai.goatech.sdk` suite used everywhere else.
- `ExperimentResult` in `Types/GeneratedTypes.swift` is `public` with only an
  internal memberwise init — the same defect fixed elsewhere in 0.2.0. It is
  unreferenced by any SDK code path and lives in a generated file, so fixing
  it means changing `scripts/generate-swift-models.ts` (outside this
  package). Either give the generator a public init or stop emitting the type
  as `public`.
