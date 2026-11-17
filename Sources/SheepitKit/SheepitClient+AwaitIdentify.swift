import Foundation

/// `identify(userId:timeout:)` and `awaitConfig(timeout:)`: wait until flags answer for a user, or
/// for any config at all. The waits live in `IdentifyWaiters`; the hooks that signal them are in
/// `SheepitClient.swift` (`postIdentity`, the `onConfig` wiring, `reset()`, `performTeardown()`).

/// How `identify(userId:timeout:)` ended. Compare against `.ready` rather than switching over every
/// case: cases may be added.
public enum IdentifyOutcome: Sendable, Equatable {
    /// The server's device row holds the user and the config applied in memory was fetched for
    /// them: `flag()` and `experiment()` now answer for this user.
    case ready
    /// The timeout ran out first, or the calling task was cancelled. The identify request and the
    /// config fetch carry on in the background; flags switch to the user's values when they land.
    case timedOut
    /// The user is not bound now, and this call will not bind them: the server rejected the
    /// identify request, the device was not found, retries ran out, device registration is backed
    /// off, `reset()` or `destroy()` ran, the app identified a different user, the `userId` is
    /// longer than 256 UTF-16 units, or the client is destroyed or inert. Flags keep evaluating
    /// this device without the user.
    ///
    /// Only a rejected id is final. After a backoff or exhausted retries the SDK's own periodic
    /// retry may still bind the user later, so calling again later can return `.ready`.
    case failed
}

extension SheepitClient {
    /// Identify the user, then wait until flags answer for them, at most `timeout`.
    ///
    /// Does exactly what `identify(userId:)` does, then waits for two things: the server's device row
    /// is known to hold `userId`, and the config applied in memory was evaluated while it held them.
    /// That config is usually the one fetched right after the server confirms the user (a response
    /// the server could not resolve this device for is never applied, so a server-side lookup
    /// failure on that fetch ends in `.timedOut` unless a later fetch lands in time). The config
    /// cached on the device never settles it: the launch applies the cache inside `create`,
    /// before the server has confirmed any user this session, so it never counts as evaluated for
    /// `userId`, even when the same user was identified in the last session. Flags still answer
    /// from that cache while this waits, so an offline launch returns `.timedOut` with the cached
    /// values in place. Use it where the first screen after login depends on a user-targeted flag:
    ///
    /// ```swift
    /// let outcome = await sheepit.identify(userId: "user_123", timeout: .seconds(2))
    /// let showNewCheckout = sheepit.flag("new_checkout", default: .bool(false)).boolValue == true
    /// if outcome != .ready {
    ///     // `showNewCheckout` is the anonymous value (or the default): decide whether that is
    ///     // acceptable for this screen.
    /// }
    /// ```
    ///
    /// Calling it again with the user already identified returns `.ready` at once when nothing is
    /// pending, sends no request, and returns `.failed` at once if that user's identify request was
    /// already rejected, registration is backed off, or their retries just ran out (see
    /// `IdentifyOutcome.failed`: only the rejection is final).
    ///
    /// The timeout, and cancelling the calling task, end only the wait: neither cancels the
    /// identify request or the config fetch. `timeout` of zero or less reports what is already
    /// known without waiting.
    ///
    /// - Parameters:
    ///   - userId: Your own id for this person; same rules as `identify(userId:)`.
    ///   - timeout: How long to wait at most.
    /// - Returns: `.ready`, `.timedOut` or `.failed` (see `IdentifyOutcome`). Available from 0.9.0.
    public func identify(userId: String, timeout: Duration) async -> IdentifyOutcome {
        guard inertReason == nil, !destroyedFlag.value,
              let wait = identifyWaiters.register(.identify(userId))
        else {
            identify(userId: userId)
            return .failed
        }
        switch dispatchIdentify(userId: userId) {
        case .notSent:
            identifyWaiters.resolve(wait, .failed)
        case .posted(let sequence):
            identifyWaiters.arm(wait, failingFrom: sequence)
        case .alreadyBound(let sequence):
            identifyWaiters.arm(wait, failingFrom: sequence)
            // The row holds the user but the config in memory was not fetched for them: fetch it
            // now rather than leave the wait to the next periodic refresh.
            if !identifyWaiters.isResolved(wait) { refetchConfigForAwaitedIdentify() }
        }
        let outcome = await identifyWaiters.wait(wait, timeout: timeout)
        // A `destroy()` racing this call can land after the wait resolved: report the destroy.
        return destroyedFlag.value ? .failed : outcome
    }

    /// Wait until a config is applied in memory, at most `timeout`.
    ///
    /// Returns `true` at once when one already is (from the on-device cache or a fetch). On a fresh
    /// install nothing is until the first `/v1/config` fetch lands, and `flag()` returns your
    /// defaults until then; await this before reading a flag that must not fall back:
    ///
    /// ```swift
    /// if await sheepit.awaitConfig(timeout: .seconds(1)) {
    ///     let showNewCheckout = sheepit.flag("new_checkout", default: .bool(false)).boolValue == true
    /// }
    /// ```
    ///
    /// After `reset()` no config is applied again until the next fetch lands, and a `reset()` racing
    /// this call makes it return `false`. A response the server could not resolve this device for
    /// (before it registers, or a server-side lookup failure) is never applied, so on a fresh
    /// install this waits for the fetch that follows registration. This says nothing
    /// about WHICH user the config was evaluated for: use `identify(userId:timeout:)` for that.
    ///
    /// - Returns: `false` on timeout, when the calling task is cancelled, when a `reset()` races the
    ///   call, or once the client is destroyed or inert. Available from 0.9.0.
    @discardableResult
    public func awaitConfig(timeout: Duration) async -> Bool {
        guard inertReason == nil, !destroyedFlag.value, let wait = identifyWaiters.register(.config) else {
            return false
        }
        let outcome = await identifyWaiters.wait(wait, timeout: timeout)
        return outcome == .ready && !destroyedFlag.value
    }
}
