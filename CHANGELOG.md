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

## [0.4.0] - 2026-09-11

### Added

- **`$app_install` / `$app_update`**, both driven by one storage key
  (`gt_installed_app_version`). `$app_install` fires exactly once, on a genuinely fresh
  install — never again, and never merely because an EXISTING install upgraded to this
  version of the SDK. That suppression is the whole point: `beginWork()` already persists
  `gt_device_id` before `SheepitClient.start()` ever runs, so checking whether that key
  exists cannot tell the two cases apart (the exact dead-guard shape D-1 exists to avoid
  repeating). The real signal is `ContextManager.didMintDeviceId`, captured inside `init`
  BEFORE that write — true only when THIS launch minted a fresh device id from empty
  storage. An install with no version marker yet but a pre-existing device id backfills
  the marker silently instead of reporting a fake install the day it upgrades, which would
  otherwise corrupt install counts for every customer with an existing install base.
  `$app_update` fires whenever the stored marker differs from the version running now,
  carrying `previous_version` / `current_version`.

  The version compared is `config.appVersion ?? CFBundleShortVersionString` — the SAME
  fallback `Transport.buildPayload` (audit L-005) uses for every other event's
  `app.version` — not `CFBundleShortVersionString` alone. A release-binding customer sets
  `config.appVersion` to a commit SHA / build tag rather than the marketing version, so
  events resolve to the right `Release` row; reading a different source here would have
  made `previous_version`/`current_version` disagree with `app.version` on every other
  event in the same batch, and would mean `$app_update` never fires when only
  `config.appVersion` changes — the exact release-upgrade scenario the event exists for.

  🔴 **Durability caveat.** The one-shot marker is written to disk before its event is
  durably queued — `EventQueue` is purely in-memory, and `OfflineQueue` only persists on a
  _failed_ flush. A process crash inside the flush window on a fresh install loses
  `$app_install` permanently: the marker is already written, so no future launch retries.
  This event already "fires exactly once, ever" by design (see
  `DEVICE_CONTEXT_AND_AUDIENCE_ANALYTICS.md` § 5) — miss the narrow window and it is gone,
  same as a miss for any other reason. No durability machinery added for this; tracked in
  `PENDING_WORK.md`.

- **`is_first_session` on `$session_start`.** One property: `true` only for the device's
  very first session ever, so the install cohort is queryable without a join back to
  `$app_install`. Deliberately NOT the three-value `start_reason` (`cold | warm | resume`)
  the design doc considered — `StartupTracker` has no resume concept (a nil-check on
  `warmStartBegin`, no enum) and times `cold_start` from SDK-init rather than process
  launch, so that enum would be a lie. `is_first_session` is a one-shot for the LIFETIME of
  the device, distinct from `ContextManager.didMintDeviceId` itself (which stays `true` for
  the whole process once set): without a separate latch, a session that rolls over later in
  the SAME process would also report `is_first_session: true`, which is wrong.

- **The ingest wire now carries the device-context dimensions it always claimed
  to.** `Transport.buildPayload` hardcoded `model: nil, osVersion: nil` and
  omitted everything else, so the `device_model` and `os_version` columns have
  been empty for every iOS event ever sent, and the six columns added
  server-side in #983 (`sdk_name`, `sdk_version`, `os_name`, `timezone`,
  `device_type`, `build_channel`) had nothing populating them. Audience
  analytics — device / country / OS version / app version breakdowns — reads
  exactly these columns, so it rendered empty on iOS no matter what the
  dashboard did.

  Two of the values were also wrong at the source, not merely absent.
  `DeviceProfile.deviceModel()` returned `UIDevice.current.model`, which is the
  generic `"iPhone"` / `"iPad"` — but the server's `formatDeviceModel()` maps
  **hardware identifiers** (`iPhone16,2`), so the friendly-name lookup could
  never hit. It now reads `utsname.machine` / `hw.model`. And `osName` was a
  hardcoded `"iOS"` constant, mislabelling every macOS and tvOS event.

  🔴 This is why the published version matters: the columns stay empty until a
  release carrying this ships, and #983 must be DEPLOYED first — the ingest
  context schema is a plain `z.object` that strips unknown keys with no error,
  and BYOC customers pin an API image, so an SDK ahead of its API loses these
  dimensions silently in the field rather than failing loudly.

  ⚠️ **iPad traffic reclassifies from `iOS` to `iPadOS`.** `osName` was a hardcoded
  `"iOS"`, so every iPad event has been filed under `iOS` to date. Nothing
  server-side keys off the literal (checked), but a saved chart or segment
  filtering `os_name = "iOS"` will show a step-change at the release carrying
  this — the iPad share moves to a new bucket rather than disappearing.

  🔴 **This SDK is first, and web/server traffic will look empty until they catch
  up.** `sdk-js` builds `context.device` as `{ id, platform, locale }` and sends
  no `context.sdk` at all — it has an `SDK_VERSION` constant that never reaches
  the wire — and `sdk-server` sends only `{ platform: "server" }`. So a
  device-model or SDK-name breakdown will populate for iOS and stay empty for
  web and server. That is a real inconsistency a customer will see, tracked in
  PENDING_WORK.md; the fix is to bring those two up, never to weaken this one.

  Verified end-to-end rather than by inspection: the exact key set this encoder
  emits was run through the merged `ingestContextSchema`, and every key is
  accepted with **none** silently stripped.

  This also makes `emitSessionStartIfOwed()`'s docstring true. It already told
  readers that `timezone` and `sdk_version` "already ride the event context" —
  neither was on the wire until now.

  `build_channel` is honest about its limits: `"simulator"` and `"debug"` are
  exact (compiler-guaranteed), while `"testflight"` and `"appstore"` are inferred
  from the App Store receipt filename, so TestFlight, ad-hoc and enterprise
  builds all collapse to `"testflight"` and `"appstore"` is a default rather
  than a positive confirmation.

- **`$session_start` is now emitted automatically**, bringing launch/session
  capture to parity with the JS SDK. An app that launched and did nothing used
  to produce **zero** events and therefore zero DAU — while `$session_start` was
  already the unit that the platform's DAU/MAU rollup, retention cohorts, admin
  launch dashboard and ten dashboard-template widgets all count. An iOS-only
  project rendered zeroes everywhere while appearing to work, and every customer
  had to hand-write a `track()` in `didFinishLaunchingWithOptions` to see
  anything at all.

  It fires at two boundaries: `SheepitClient.start()` when the launch opened a
  new session, and `UIApplication.willEnterForegroundNotification` when the
  30-minute idle window elapsed while the app was suspended. The event carries
  **no properties** — the JS SDK's `utm_*` / `referrer` / `landing_page` are
  browser-only, and the event context already carries `session_id`, `device_id`,
  `anonymous_id`, `platform`, `locale`, `timezone`, `sdk_version` and
  `app.version`.

  Treating foreground as a session boundary is a deliberate adaptation, not a
  divergence: on the web a session dies with its tab, so a page load is the
  natural boundary. An iOS process is long-lived, so without the foreground
  check a single session could span weeks. `applicationWillTerminate` is
  **not** used and must not be — iOS routinely kills suspended apps without
  calling it.

### Fixed

- **🔴 Event timestamps now carry sub-second precision — a wire-format change on every
  event.** `EnrichedEvent.timestamp` used `ISO8601DateFormatter()`'s default
  (`.withInternetDateTime`) formatting, which is second granularity with no fractional
  seconds, so any two events emitted within the same wall-clock second — most commonly
  `$app_install`/`$app_update` immediately followed by `$session_start` on a fresh
  install — carried a byte-identical timestamp on the wire. `insights-funnel-query.ts`'s
  step join is strictly `ev.ts > s${i}.ts_${i}`, so a tied timestamp made that funnel
  return zero rows, permanently, for any two steps landing in the same second. Timestamps
  now use `[.withInternetDateTime, .withFractionalSeconds]`. Wire-compatible in both
  directions: `ingestEventSchema.timestamp` is `z.string().datetime()` with no
  `precision` constraint, so the added fractional digits are accepted by every already-
  deployed API version, and older SDK versions' second-granularity timestamps remain
  valid input to a server that has this fix.

- **D-1: device registration has never run in ANY published version, so `/v1/config` could
  never resolve the device — and once fixed to actually run, three more bugs it had been
  hiding became reachable.** `start()`'s guard read
  `storage.string(forKey: StorageKeys.deviceId) == nil` to decide whether to POST
  `/v1/devices/register` — but `ContextManager.init` has unconditionally persisted that key
  before `start()` ever ran since the SDK's very first commit (verified against the
  `swift-v0.3.0` tag too), so the guard was never satisfiable. `POST /v1/devices/register` has
  therefore never actually fired in the field: no `device_assignments` row exists for any iOS
  install, and every device evaluating flags has silently been falling back to defaults the
  whole time. The guard now checks a dedicated `gt_device_registered` flag, set only after a
  successful round trip, and registration fires for real.

  Because registration has never run, **every real existing install already carries a
  LOCALLY-MINTED UUID — never a server-assigned `dev_…` id — stamped on however much event
  history it has.** The registration call used to always send `existingDeviceId: nil`
  regardless, which is what the server's fresh-install path expects — but sending it
  unconditionally the moment registration starts working for real would mint a BRAND NEW
  server-assigned id for every existing install and upsert a fresh `device_assignments` row
  under it, orphaning that install's entire event history from its device profile on the very
  first launch where registration finally succeeds. `ContextManager` now tracks whether
  `gt_device_id` was restored from storage or minted fresh THIS launch
  (`didMintDeviceId`): a genuinely fresh install still gets a server-minted id, while every
  existing install sends its own locally-minted UUID and the server upserts under that SAME
  id — keeping its event history attached to the identity it already carries, rather than
  orphaning it the moment registration turns on. (`didMintDeviceId == false` also covers a
  forward-looking case with no installs in it today: a device that already holds a
  server-assigned id from a successful registration, should some later bug make it attempt
  registration a second time.) A device whose first registration attempt fails (no network at
  first launch) still retries on the next launch, unchanged.

  Making registration actually run surfaced an ordering bug of its own: `start()` emits
  `$session_start` SYNCHRONOUSLY, before the registration round trip it just kicked off has
  any chance to complete, so that event — and any host `track()` call landing in the same
  window — gets enqueued under the pre-registration id. Left alone, the periodic auto-flush
  or a queue-size-triggered one could send that batch to `/v1/ingest` before the id swap
  ever happens, orphaning it exactly like the bug above, just downstream of it.
  `EventQueue.restampDeviceId` now rewrites any already-queued event carrying the
  pre-registration id once registration adopts the real one, and every SDK-internal
  auto-flush trigger (the size threshold, the periodic timer, app background/foreground, and
  connectivity-restored) now waits for registration to settle first. The public `flush()` API
  is deliberately NOT gated — a host that calls it directly must never be made to wait on a
  network round trip it didn't ask for.

  Finally, `deviceManager.register()` used to treat every failure identically. A permanently
  rejected key (401/403) or a device-cap ceiling (422) now backs off for 24 hours instead of
  re-hitting the endpoint on every single cold start, and emits a diagnostic (with a distinct
  `outcome` value per status) so the failure is actually visible — while still leaving
  `gt_device_registered` unset, so a key that gets fixed in a later build is retried once the
  window elapses rather than stranded forever.

- **D-2: crash reports shipped an empty device profile.** `CrashReporter.updateContext()`
  wrote `user_id`/`device_id`/`session_id` into the mmap'd C crash context but never
  `app_version`/`build_number`/`os_version`/`device_model` — the C struct had reserved those
  fields since it was written, and `CrashReportReader` already read them back, so every crash
  report shipped `app_version: ""` and the other three `nil` with no signal anywhere that the
  fields were silently empty. Now filled from `DeviceProfile` through the same
  size-truncating `writeString` helper the three id fields already use.

- **MF-2/MF-3: a concurrent `initialize()` inflated DAU and could disable crash reporting.**
  The round-2 deadlock fix moved construction outside the singleton lock, so every racing
  caller built a _fully started_ client. Only one was published; the losers were
  `destroy()`ed — but `destroy()` flushes, so their auto-emitted `$session_start` reached
  the server. Measured: 50 concurrent calls returned one instance and six `$session_start`.
  A host calling `initialize()` from both an `AppDelegate` and a `SceneDelegate` inflated
  DAU every launch — the same harm this release notes as the reason an inert client must
  emit nothing, through a different door. The crash handler compounded it: the install path
  is per-instance but the C handler is a process-global, so a loser that won the install
  race tore the handlers out for the whole process on `destroy()`, leaving the surviving
  client with none. Construction and starting work are now separate: `beginWork()` runs
  only for the client that actually wins publication, so a loser emits nothing, registers
  nothing and installs nothing. `create(config:)`'s behaviour is unchanged.
- **MF3-1: a concurrent `initialize()` LOSER still wrote its identity to disk.** The
  construct/beginWork split above closed every NETWORK side effect of a losing candidate, but
  `ContextManager`'s device/session-id persistence ran unconditionally during construction —
  before `beginWork()` was ever in the picture — so a fully-constructed loser (accepted key,
  never published, `destroy()`ed without starting) still clobbered whatever the WINNER had
  already persisted with a session id nobody would ever use again. A device that hit this
  window resumed the LOSER's session on its next launch — one that never emitted
  `$session_start` and is therefore invisible to DAU, while the live client kept emitting
  under a session id disk no longer agreed with. `ContextManager` now always constructs with
  `persistOnInit: false`; `beginWork()` persists via the new `persistOnBeginWork()`, so a
  candidate that never begins work writes no per-client identity and cannot clobber the
  winner's device or session ids. It is **not** byte-identical on disk to an inert client, and
  saying so was wrong: a non-inert candidate also runs the one-shot `StorageMigration` and
  creates the crash-report cache directory. Both are process-wide, idempotent and shared by
  every client of the install, so neither can clobber another client — but both are writes.
  Deferring them behind `beginWork()` is queued rather than done here.
- **MF3-2: `beginWork()` could run on a client `destroy()` had already torn down.** It guarded
  on `inertReason` but not `destroyedFlag`, and `initialize()` publishes the singleton under
  its lock BEFORE calling `beginWork()` outside that lock — so a thread that read `shared` in
  that window and called `destroy()` could finish (one-shot) before `beginWork()` ran at all,
  which then started device registration, the config-sync loop, and a crash-handler install
  on a client nothing would ever tear down again. `beginWork()` now also guards on
  `destroyedFlag`, and re-checks it after `start()` returns — closing the deterministic
  variant where a host callback calls `destroy()` from inside `start()`'s own synchronous
  `config.onEvent?` callout — running the same (idempotent) teardown a second time if it lost
  the race in the meantime.
- **MF3-3: an `anrThresholdMs` of `0` or less SIGKILLed the host.** The MF-1 sweep clamped
  every `Task.sleep` site but missed `ANRWatchdog`, which drives a real background `Thread`
  via `Thread.sleep`. At `<= 0` the watchdog loop stopped sleeping and spun, enqueuing an
  unbounded `DispatchQueue.main.async` per iteration — measured RSS 21.5 -> 70.8 MB in 0.5s,
  process killed (exit 137) at ~0.7s. `ANRWatchdog.init` now clamps to a 100ms...600s range,
  matching the `EventQueue.init` pattern of clamping at the actual consumer rather than
  trusting `PerformanceConfig`'s (bypassable) initializer clamp. Reachable only with
  `performance.enabled: true` and a bad threshold, since the default is `5000`.
- **MF-1: a public config value could still abort the host app.** The `maxQueueSize` clamp
  sat in `SheepitConfig.init`, but the property is a `public var`, so assigning `0` after
  construction walked past it and trapped on an empty-queue `removeFirst`. Worse,
  `flushInterval: .infinity` — the obvious "never auto-flush" idiom — aborted through the
  initializer itself, as did `.nan` and out-of-range values on the config-refresh and
  performance intervals. Clamping now happens at each _consumer_ (`EventQueue`, and every
  `Task.sleep` site via `TimeInterval.sanitizedForSleep()`), which is why
  `diagnosticBufferSize` was never bypassable; the initializer clamps remain as defence in
  depth.
- **MF-4/MF-5: a malformed `apiUrl` was certified healthy.** The admission gate validated
  the _trimmed_ URL while `HTTPClient` built its base URL from the _untrimmed_ one, so
  `" https://host"` yielded `initialized == true` and then routed every event, flag fetch
  and crash report to a nonexistent domain, with no log and no diagnostic. The gate also
  accepted an empty scheme or host, because `URL` returns empty strings rather than `nil`.
  Both sides now agree on the same trimmed string, and a scheme must be `http`/`https` with
  a non-empty host.
- A malformed `environment` (empty, or containing control characters) now routes through
  the inert path instead of being sent as an `X-Environment` header that Foundation
  silently drops — which had quietly filed events under the wrong environment.
- Userinfo redaction no longer requires a colon, so a bare `https://<token>@host` credential
  is redacted rather than echoed into logs, the diagnostic bus and the public
  `status().rejectionReason`; the rejection reason is logged `%{private}@`.

- **A flush now sends one request per session.** `Transport.buildPayload` stamps a
  single batch-level `context.session.id` taken from `events[0]`, and the wire
  format carries no per-event session field — so a batch spanning two sessions
  filed its whole tail under the first event's session, unrecoverably. That
  really happened by three unrelated routes: the offline queue draining events a
  previous process persisted behind events from this one, a 429 re-queue landing
  behind newer events, and a session rollover between two `track()` calls.
  `flush()` now splits the drained batch into runs of consecutive events sharing
  a session id and sends each separately.

- **Session rollover no longer happens silently, or mid-batch.**
  `ContextManager.touchSession()` — called on every `track()` — used to rotate
  the session id whenever the idle window had elapsed. Nothing announced the
  new session, so the platform never counted it; and because
  `Transport.buildPayload` stamps one batch-level `context.session.id` taken
  from `events[0]`, a rotation inside a batch filed every later event in that
  batch under the _previous_ session. `touchSession()` is now bump-only,
  matching `packages/sdk-js/src/context.ts:175`, and rollover moved to
  `rolloverIfExpired()` which callers invoke only at flush boundaries.

- **A rejected API key no longer aborts the host app.** `SheepitClient.create(config:)`
  validated the key with `precondition`/`preconditionFailure`, which terminates the process
  — a misconfigured key crashed the customer's app at launch. It now returns an **inert**
  client: an error is logged, a `lifecycle.api_key_rejected` diagnostic is emitted,
  `status().initialized` reports `false`, and no method reaches the network, persists a flag
  override, or starts background work. `diagnostics()` and `getRecentDiagnostics()`
  deliberately keep working: they are how a host app reads _why_ the client is inert. This
  matches the JS SDK, where the same guard throws — recoverable — rather than killing the
  process. Secret keys are still refused just as firmly (audit E-002); they now produce a
  dead client instead of a dead app.

  **2026-09 security follow-up, finding E-001 — corrected above.** The first version of this
  fix still ran the one-time `UserDefaults` storage migration and device-identity persist
  step (`ContextManager`'s `deviceId`/`anonymousId`/`sessionId`/`sessionLastSeen`)
  unconditionally, before the key was judged — so constructing a rejected-key client
  silently rotated the session/device ids the _next_, correctly-keyed client in the same
  process would read, corrupting analytics session boundaries. Both calls are now gated on
  the key (and apiUrl, see E-003 below) having been judged admissible first. `OfflineQueue.init`
  still does a disk **read** on every construction (to restore any previously-queued events)
  regardless of admission — reads were never the concern, only writes.

  **An inert client makes zero writes to persistent storage** is the invariant this finding
  and finding S1 (round 2, below) jointly establish — S1 closed the last gap, in
  `clearOverrides()`/`clearOverride(_:)`, that this entry alone did not cover.

- **A `dev` key no longer takes the app down.** Admission accepted only `pub` and `sec`, so a
  `*_dev_*` key — a documented key type — hit the generic format `precondition` and aborted,
  reporting only that `pub` or `sec` was expected. Dev keys still cannot drive a client-side
  SDK (they are read-only for schemas and definitions and cannot post events), but they are
  now refused with their own message naming the actual reason.

- **A rejected key no longer poisons the singleton.** `initialize(config:)` cached whatever
  `create(config:)` returned, and an inert client's `destroy()` is an early-return (its latch
  is set at construction), so the singleton could never be cleared — `shared` and every later
  `initialize()`, including one with a corrected key, returned the dead client for the rest
  of the process lifetime. A rejected client is now never cached.

- **A rejected client no longer leaks its network monitor.** `ConnectivityMonitor` starts an
  `NWPathMonitor` in its own initializer, which runs before the key is judged, and an
  `NWPathMonitor` is not released by `dealloc` — it needs an explicit `cancel()`. Combined
  with the early-returning `destroy()` above, every rejected client left one running forever.

- **A concatenated `sec` or `dev` key is refused.** Admission reads the type segment
  positionally, so a whole second key glued onto something publishable-shaped
  (`lp_pub_env_<secret>_lp_dev_env_<secret>`) was admitted on the strength of segment 1 alone.
  Any non-publishable type segment past the environment slug now refuses. The slug itself is
  exempt — an environment named "security" legitimately slugs to `sec` — and
  `allowSecretKeyInClient`, the XCTest-only opt-out, exempts `sec` and nothing else.

- **`ConnectivityMonitor` no longer starts itself.** It began watching the network path in its
  own initializer, which runs before its owner knows whether the client should exist. That is
  what made the leak above possible, and it made every short-lived client pay for a real
  `NWPathMonitor`. It now starts from `start()` with the rest of the background work.

- **`overrideFlag()` and `getOverrides()` are guarded.** They were not, and
  `setOverridesAllowed` ran before the key was judged, so a rejected client built with
  `debug: true` wrote flag overrides into the shared `UserDefaults` — where the next healthy
  client in the same process picked them up.

- **E-002, retroactive review — a two-token vendor prefix could smuggle a secret key past
  the guard above.** The concatenated-key sweep exempted index 2 as "the environment slug",
  but `{vendor}_{type}_{slug}_{secret}` positional matching assumed the vendor prefix was a
  single token. A key shaped `my_pub_sec_abc_<secret>` slides the real `sec` type token into
  that exempted slot — `segments[1]` still reads `pub`, and the guard let it through. Keys
  must now have **exactly** four `_`-delimited segments; the vendor prefix and the secret
  must not themselves contain `_`. This is latent today (the server only ever mints `lp_`),
  but is exactly the forward-compatibility case the positional-match design exists for.

- **E-003 — a malformed or empty `apiUrl` still aborted the host app.** `HTTPClient.init`
  built its base URL with `URL(string: config.apiUrl)!`; an empty string (an unset BYOC env
  var is the common case) or one missing a scheme/host traps the process. A bad `apiUrl` now
  routes through the same inert-client path a rejected key does, with a rejection reason
  naming the value. `track(_:)`'s `precondition` on an empty event name is fixed the same
  way — it is now a dropped event plus a `transport.invalid_event_name` diagnostic, not a
  crash.

- **E-004 — a key with a trailing newline/space silently sent every request unauthenticated.**
  A key with no alphabet constraint on its secret was admitted verbatim; Foundation's
  `URLRequest` then silently drops the entire `Authorization` header rather than sending one
  containing a raw `\n` — so the request went out with NO auth header and no error anywhere.
  Keys are now trimmed before admission is judged and again where the `Authorization` header
  is built; the secret segment is constrained to printable ASCII so an embedded NUL or other
  control character in the middle of the secret (which trimming cannot reach) is refused
  outright rather than reaching the wire.

- **E-005 — `lp__pub_…`, `_lp_pub_…`, and `lp_pub_…_` were admitted.** Splitting on `_` with
  the default `omittingEmptySubsequences: true` silently collapsed a double, leading, or
  trailing underscore into a segment count that looked like a well-formed key. Splitting
  with `omittingEmptySubsequences: false` and rejecting any empty segment surfaces these
  instead of hiding them.

- **Lifecycle: `initialize()`'s singleton check was an unsynchronized race.** Two concurrent
  callers could both observe `instance == nil` and each construct (and start) a live client;
  only one ever won the final assignment, and the loser's caller got back a live, started
  client that `shared` would never point to. A lock now serializes the check-then-act (and
  `destroy()`'s clear of the same variable).

- **Lifecycle: the periodic-flush `Task` leaked any client the host dropped without calling
  `destroy()`.** It referenced `config`/`transport` with no capture list — an implicit
  strong `self` capture in an escaping closure — so `self -> flushTask -> closure -> self`
  was a genuine reference cycle. It now captures `[weak self]`.

- **`clearOverrides()`/`clearOverride(_:)` briefly gained a `guard !destroyedFlag.value`**
  that contradicted their own doc comment (deletes are never gated — only writes are, so a
  build that calls `destroy()` as part of its own teardown/reset flow can still purge an
  override it wrote earlier in the session). Removed; the guard was never released.

- **2026-09 security follow-up, round 2 (independent review of the fixes above) — M1
  (CRITICAL): `initialize()` deadlocked the host thread.** Holding `instanceLock` across the
  whole of `create(config:)` meant a host callback that ran DURING construction —
  `onDiagnostic` on the inert path, `onEvent` on the live path (fired synchronously from the
  auto-emitted `$session_start`) — and read `SheepitClient.shared` or called `destroy()` on
  that same thread self-deadlocked forever against the non-recursive lock. On the main thread
  that is an unrecoverable watchdog kill with no readable crash report — strictly worse than
  the crash this PR series exists to remove. Construction now happens OUTSIDE the lock; the
  lock guards only the short check-and-assign, and a caller that loses the race (or arrives
  after the singleton already exists) has its just-built client `destroy()`ed instead of
  leaked. `LifecycleSafetyTests` covers both deadlock shapes.

- **M2: `SheepitConfig(maxQueueSize: 0)` trapped the process inside `create()`.**
  `EventQueue.add` evicts the oldest event once `count >= maxSize`, which crashes on an empty
  array at `maxSize == 0` — and #973's auto-emitted `$session_start` enqueues an event during
  construction, so this was reachable from `create()` on a config value alone.
  `SheepitConfig.init` now clamps `maxQueueSize` to a floor of 1.

- **M3: the E-004 fix (printable-ASCII key validation) covered only the secret segment.**
  A CR/LF in the vendor prefix or the environment slug was still admitted — trimming only
  strips the ends of the whole key, not a mid-string control character in an interior segment
  — and Foundation still silently dropped the `Authorization` header for it. The printable-
  ASCII check now covers the whole trimmed key.

- **S1: an "inert" client still wrote to persistent storage.** `clearOverrides()` and
  `clearOverride(_:)` carried no guard at all — not even on `inertReason` — so a rejected-
  key/apiUrl client, documented to make zero writes to disk, could still delete an override a
  different, live client in the same process had written to the shared on-disk blob. Both are
  now gated on `inertReason` (not `destroyedFlag` — a client this call itself just
  `destroy()`ed must still be able to purge, per the entry above).

- **The malformed-`apiUrl` rejection message could leak embedded credentials.** A gateway URL
  copy-pasted with basic-auth userinfo (`https://user:password@host`) was echoed verbatim
  into `log.error`, the `lifecycle.api_key_rejected` diagnostic, and the PUBLIC
  `status().rejectionReason`. The message now strips any `user[:password]@` component before
  interpolating the URL.

### Added

- **`SDKStatus.rejectionReason`** — non-nil when the SDK refused the client's API key.
  `initialized` alone could not tell you that: a refused client and a `destroy()`ed one both
  report `false`. Assert it is nil at launch to catch a misconfigured key in development,
  which is the check that replaces the crash this release removes.

### Changed

- **The API-key prefix is no longer compiled into the SDK.** Admission matched the literal
  prefixes `lp_pub_` / `lp_sec_`. It is now positional against the key's shape,
  `{vendor}_{type}_{env}_{secret}`, and segment 0 — the vendor prefix — is the only part
  never compared to anything. So `si_pub_…` is admitted by a version published today, while
  the secret-key guard does not fail open under that rename. A published SPM version is
  immutable forever, so a literal prefix here meant that prefix had to keep being minted for
  as long as anyone had that version pinned. The key format itself does not change in this
  release; this only stops a shipped version from being what blocks a future change.

  The rest of the shape **is** checked, deliberately. An earlier draft matched any `pub`
  segment anywhere, which admitted `"pub"`, `"your_pub_key"` and a truncated key as live
  clients that then silently 401'd — trading a loud crash for a silent misconfiguration. The
  secret's length is a lower bound with no alphabet constraint, so it can grow or change
  encoding without stranding published versions the way the prefix did.

- **`$sdk_error` renamed to `$error`.** Converges on the one name web/server already use
  for their own error events, rather than iOS carrying a third name for the same concept.
  Historical rows in `events_raw` stay under `$sdk_error` — a saved chart or segment
  filtering the old name goes flat at this release rather than erroring.

- **`Flags/Targeting.swift` deleted.** A real port of a then-existing
  `sdk-js/src/targeting.ts`, wired up at `FlagManager.swift:82` — but `c72bcac7`
  (2026-04-18) deliberately removed client-side rule evaluation from BOTH SDKs ("server
  owns assignment; SDK caches + emits exposure") and only cleaned up the JS half. Leftover,
  not undone work: it also lacked `regex`, carried a phantom `exists`, and had no version
  awareness, so reviving it would silently disagree with the server. Nothing else in
  `Sources/` referenced it.

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
