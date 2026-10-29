import Foundation

/// Why an exposure fired: the first read of the flag, or a read after its value changed.
enum FlagExposureReason: String, Sendable {
    case first
    case valueChanged = "value_changed"
}

/// Applies evaluated Flag values received from `/v1/config` and surfaces
/// them to calling code via `evaluate(...)`. Mirrors
/// `packages/sdk-js/src/flags.ts` — all evaluation is server-side; the
/// SDK only caches the result and tracks exposure once per flag VALUE: a
/// refresh that returns the same value is not a new exposure, a changed value is.
/// All mutable state is lock-guarded: `setEvaluatedFlags` runs on
/// ConfigSync's async callback while `evaluate` / `count` run on whatever
/// thread the host app calls `flag()` from. ThreadSanitizer reports the
/// unguarded version as a `Swift access race` on the dictionary.
///
/// `onExposure` is invoked OUTSIDE the lock. It ultimately calls
/// `track()`, which invokes the host's `SheepitConfig.onEvent` closure —
/// a customer closure that may call `flag()` again. Holding the lock
/// across it would deadlock on this non-recursive lock. `flagChanges()`
/// continuations are yielded outside the lock for the same reason.
final class FlagManager: @unchecked Sendable {
    private let lock = NSLock()
    private var flagValues: [String: AnyCodable] = [:]
    private var debugOverrides: [String: FlagValue] = [:]
    /// flag key → the value its exposure was recorded for.
    private var exposed: [String: FlagValue] = [:]
    /// Exposed keys whose value has changed since: their next read re-fires.
    private var stale = Set<String>()
    /// Resolved once at init from `SheepitConfig.allowFlagOverrides ?? config.debug`
    /// and never changed again — see `SheepitClient.init`. `overrideFlag` (the
    /// WRITE path) no-ops and does not persist while this is false, and
    /// `getOverrides()` reads as empty. `clearOverride` / `clearOverrides`
    /// (deletes) are NOT gated by this — see their doc comments.
    private var overridesAllowed = false
    private let diagnostics: DiagnosticBus?

    private var changeContinuations: [UInt64: AsyncStream<Void>.Continuation] = [:]
    private var nextContinuationId: UInt64 = 0

    private static let debugOverridesKey = "lp_debug_overrides"

    init(diagnostics: DiagnosticBus? = nil) {
        self.diagnostics = diagnostics
    }

    /// Apply the latest evaluated flag values from `/v1/config`.
    func setEvaluatedFlags(_ flags: [String: AnyCodable]) {
        lock.lock()
        self.flagValues = flags
        // 🔴 Do NOT clear the dedup here. This used to, from when config was fetched
        // once per session; with polling every apply re-fired `$flag_exposure` for
        // every flag read, every refresh. Compare instead. A key the server stopped
        // sending is forgotten, so if it comes back its next read is a first exposure.
        for (key, seen) in exposed {
            guard let raw = flags[key] else {
                exposed.removeValue(forKey: key)
                stale.remove(key)
                continue
            }
            if FlagValue.from(raw.value) == seen {
                stale.remove(key)
            } else {
                stale.insert(key)
            }
        }
        lock.unlock()
        notifyChange()
    }

    func setOverridesAllowed(_ enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        overridesAllowed = enabled
        if enabled { loadDebugOverrides() }
    }

    /// Override a flag value for local testing. No-ops (and does not
    /// persist) when overrides are disabled — see `overridesAllowed`.
    /// Gating WRITES is the security property that matters: a production
    /// build must not be able to apply an override.
    func overrideFlag(_ key: String, value: FlagValue) {
        lock.lock()
        guard overridesAllowed else {
            lock.unlock()
            emitOverridesDisabledWarning(key: key)
            return
        }
        debugOverrides[key] = value
        saveDebugOverrides()
        lock.unlock()
        notifyChange()
    }

    /// Clear a single flag's debug override, leaving any others in place.
    /// ALWAYS purges — regardless of `overridesAllowed` — including a
    /// key this instance never loaded into memory (see
    /// `purgeStaleKeyFromDisk`). Gating deletes buys nothing and creates
    /// unreachable state: a build that once ran with `debug: true` writes
    /// an override to disk, ships to production (overrides disabled),
    /// and — if clears were gated too — nothing could ever purge it. That
    /// state is dormant, not inert: flip `allowFlagOverrides` on later
    /// for any reason and the stale override silently resurrects.
    func clearOverride(_ key: String) {
        lock.lock()
        let removedFromMemory = debugOverrides.removeValue(forKey: key) != nil
        if removedFromMemory { saveDebugOverrides() }
        let removedFromDisk = purgeStaleKeyFromDisk(key)
        lock.unlock()
        if removedFromMemory || removedFromDisk { notifyChange() }
    }

    /// Clear all debug overrides. ALWAYS purges the on-disk key —
    /// regardless of `overridesAllowed` — same rationale as
    /// `clearOverride`.
    func clearOverrides() {
        lock.lock()
        let hadAnyInMemory = !debugOverrides.isEmpty
        let hadAnyOnDisk = UserDefaults.standard.data(forKey: Self.debugOverridesKey) != nil
        debugOverrides.removeAll()
        UserDefaults.standard.removeObject(forKey: Self.debugOverridesKey)
        lock.unlock()
        if hadAnyInMemory || hadAnyOnDisk { notifyChange() }
    }

    /// Get all current debug overrides. Empty when overrides are disabled.
    func getOverrides() -> [String: FlagValue] {
        lock.lock()
        defer { lock.unlock() }
        guard overridesAllowed else { return [:] }
        return debugOverrides
    }

    /// Whether `overrideFlag` writes currently take effect. Test-only introspection (like
    /// `ConnectivityMonitor.isMonitoring`) so a test can prove `SheepitClient` never calls
    /// `setOverridesAllowed(true)` for a rejected-key/apiUrl client, independent of
    /// `overrideFlag()`'s own `guard !destroyedFlag.value` at the `SheepitClient` layer —
    /// see `SecretKeyGuardTests.testInertClientDoesNotWriteFlagOverrides`. Not part of the
    /// public surface.
    var overridesAllowedForTests: Bool {
        lock.lock()
        defer { lock.unlock() }
        return overridesAllowed
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return flagValues.count
    }

    /// Evaluate a flag. Returns the resolved value or the default.
    /// Fires `onExposure` on the first read of a value, and once more after a refresh changes it.
    func evaluate(
        flagKey: String,
        defaultValue: FlagValue,
        onExposure: (String, FlagValue, FlagExposureReason) -> Void
    ) -> FlagValue {
        lock.lock()

        // Debug overrides take highest priority
        if overridesAllowed, let override = debugOverrides[flagKey] {
            lock.unlock()
            return override
        }

        guard let raw = flagValues[flagKey] else {
            lock.unlock()
            return defaultValue
        }

        let value = FlagValue.from(raw.value)
        let reason: FlagExposureReason?
        if stale.remove(flagKey) != nil {
            reason = .valueChanged
        } else {
            reason = exposed[flagKey] == nil ? .first : nil
        }
        if reason != nil { exposed[flagKey] = value }
        lock.unlock()

        // Outside the lock — see the note on this type.
        if let reason {
            onExposure(flagKey, value, reason)
        }
        return value
    }

    /// Diagnostic read for a dev-menu / debug inspector. Never touches
    /// `exposed`, never invokes `onExposure` — rendering a list of these
    /// must not pollute experiment/flag exposure data.
    func inspect(flagKey: String, defaultValue: FlagValue) -> SheepitFlagInspection {
        lock.lock()
        defer { lock.unlock() }
        let remote = flagValues[flagKey].map { FlagValue.from($0.value) }
        let override = overridesAllowed ? debugOverrides[flagKey] : nil

        let source: SheepitFlagValueSource
        let effective: FlagValue
        if let override {
            source = .override
            effective = override
        } else if let remote {
            source = .remote
            effective = remote
        } else {
            source = .fallback
            effective = defaultValue
        }

        return SheepitFlagInspection(
            key: flagKey,
            remoteValue: remote,
            overrideValue: override,
            effectiveValue: effective,
            source: source
        )
    }

    /// Union of keys with a remote value and keys carrying an override,
    /// sorted. Never fires exposure.
    func knownFlagKeys() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        var keys = Set(flagValues.keys)
        if overridesAllowed {
            keys.formUnion(debugOverrides.keys)
        }
        return keys.sorted()
    }

    /// Forget which values were exposed, so each next read fires again. Called when the identity changes.
    func clearExposed() {
        lock.lock()
        defer { lock.unlock() }
        exposed.removeAll()
        stale.removeAll()
    }

    /// Forget the evaluated values. Called on `reset()` (logout).
    ///
    /// Clearing the cached config is not enough on its own: the values are also
    /// held here, so `flag()` would keep returning the logged-out user's values
    /// until the next `/v1/config` landed. Debug overrides are deliberately NOT
    /// cleared — they are set by the developer, not by the user.
    func clearEvaluated() {
        lock.lock()
        flagValues.removeAll()
        exposed.removeAll()
        stale.removeAll()
        lock.unlock()
        // 🔴 Every other mutator notifies; this one did not. A SwiftUI view
        // awaiting `changes()` would keep rendering the logged-out user's
        // gated surfaces — the manager empty, the screen stale — until some
        // unrelated re-render happened to ask again. Notify OUTSIDE the lock,
        // as the other call sites do.
        notifyChange()
    }

    // MARK: - Change notification

    /// Fires on config apply (`setEvaluatedFlags`), override set
    /// (`overrideFlag`), and override clear (`clearOverride` /
    /// `clearOverrides`). Multi-subscriber: every call registers an
    /// independent continuation, dropped on stream termination.
    func changes() -> AsyncStream<Void> {
        AsyncStream { continuation in
            lock.lock()
            let id = nextContinuationId
            nextContinuationId += 1
            changeContinuations[id] = continuation
            lock.unlock()

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.changeContinuations.removeValue(forKey: id)
                self.lock.unlock()
            }
        }
    }

    /// Finish every outstanding `flagChanges()` stream — called from
    /// `SheepitClient.destroy()`. Without this, a consumer whose lifetime isn't
    /// tied to a cancellable scope (e.g. not a SwiftUI `.task`) would hang
    /// forever `for await`-ing a stream that will never yield or complete
    /// again once the SDK is torn down.
    ///
    /// Continuations are removed from the registry and `.finish()`d
    /// OUTSIDE the lock — same invariant as `notifyChange`/`onExposure`:
    /// `.finish()` synchronously runs the stream's `onTermination`, whose
    /// handler re-enters this manager to remove itself from
    /// `changeContinuations`. Clearing the dict before unlocking makes
    /// that re-entrant removal a harmless no-op instead of a second
    /// mutation racing the first.
    func finishAllChanges() {
        lock.lock()
        let continuations = Array(changeContinuations.values)
        changeContinuations.removeAll()
        lock.unlock()
        for continuation in continuations {
            continuation.finish()
        }
    }

    /// Yielded OUTSIDE the lock — see the type-level note.
    private func notifyChange() {
        lock.lock()
        let continuations = Array(changeContinuations.values)
        lock.unlock()
        for continuation in continuations {
            continuation.yield()
        }
    }

    /// Emitted OUTSIDE the lock — `DiagnosticBus.emit` invokes subscribers
    /// synchronously, and a subscriber that called back into this manager
    /// would deadlock on this non-recursive lock. Only `overrideFlag` (the
    /// WRITE path) calls this now — clears are never gated, so they never
    /// need to warn.
    private func emitOverridesDisabledWarning(key: String) {
        guard let diagnostics else { return }
        diagnostics.emit(
            .warn,
            .flag,
            code: "flag.override_disabled",
            message: "Flag overrides are disabled (SheepitConfig.debug is false and "
                + "allowFlagOverrides is not true) — overrideFlag ignored.",
            data: ["flag_key": AnyCodable(key)]
        )
    }

    // MARK: - Debug Override Persistence

    // Callers of load/save must hold `lock` — NSLock is not recursive.

    /// Overrides persist as `[String: AnyCodable]` so object/array
    /// (`.json`) overrides survive a relaunch.
    ///
    /// Legacy note: this key previously held `[String: String]`, where
    /// every value was stringified and re-parsed heuristically on load.
    /// A `[String: String]` blob still decodes cleanly as
    /// `[String: AnyCodable]`, so the string heuristic is retained for
    /// String values — which keeps the pre-existing behaviour that an
    /// override of `.string("true")` reloads as `.bool(true)`.
    private func loadDebugOverrides() {
        guard let data = UserDefaults.standard.data(forKey: Self.debugOverridesKey),
              let dict = try? JSONDecoder().decode([String: AnyCodable].self, from: data) else { return }
        for (key, wrapped) in dict {
            if let raw = wrapped.value as? String {
                debugOverrides[key] = Self.parseLegacyStringOverride(raw)
            } else {
                debugOverrides[key] = FlagValue.from(wrapped.value)
            }
        }
    }

    private static func parseLegacyStringOverride(_ raw: String) -> FlagValue {
        if raw == "true" { return .bool(true) }
        if raw == "false" { return .bool(false) }
        if let intVal = Int(raw) { return .int(intVal) }
        if let doubleVal = Double(raw) { return .double(doubleVal) }
        return .string(raw)
    }

    private func saveDebugOverrides() {
        var dict: [String: AnyCodable] = [:]
        for (key, value) in debugOverrides {
            switch value {
            case .bool(let val): dict[key] = AnyCodable(String(val))
            case .string(let val): dict[key] = AnyCodable(val)
            case .int(let val): dict[key] = AnyCodable(String(val))
            case .double(let val): dict[key] = AnyCodable(String(val))
            case .json(let val): dict[key] = val
            }
        }
        if let data = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(data, forKey: Self.debugOverridesKey)
        }
    }

    /// Removes a single key from the on-disk override blob DIRECTLY —
    /// independent of `debugOverrides` (and therefore of `overridesAllowed`
    /// / whether `loadDebugOverrides()` ever ran this session). Needed for
    /// Fix 1: a "production" instance that never loaded overrides into
    /// memory must still be able to purge a key a prior "debug" instance
    /// wrote to disk. Returns whether the key was actually present.
    /// Must hold `lock` — same rule as load/save.
    private func purgeStaleKeyFromDisk(_ key: String) -> Bool {
        guard let data = UserDefaults.standard.data(forKey: Self.debugOverridesKey),
              var dict = try? JSONDecoder().decode([String: AnyCodable].self, from: data),
              dict.removeValue(forKey: key) != nil else { return false }
        if dict.isEmpty {
            UserDefaults.standard.removeObject(forKey: Self.debugOverridesKey)
        } else if let newData = try? JSONEncoder().encode(dict) {
            UserDefaults.standard.set(newData, forKey: Self.debugOverridesKey)
        }
        return true
    }
}
