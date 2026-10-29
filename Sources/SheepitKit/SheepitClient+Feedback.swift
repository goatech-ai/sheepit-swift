import Foundation

/// `submitFeedback(message:type:email:attributes:screenshots:)` — in-app feedback from the app's
/// users, with up to 3 screenshots, to `POST /v1/feedback/sdk`. See README "In-app feedback".
///
/// Collaborators: `FeedbackValidator` (the server's caps, checked on the device),
/// `MultipartFormData` (the wire body), `FeedbackSender` + `PendingFeedbackStore` (delivery and
/// the on-disk retry queue, per storage scope). `reset()` clears the queue; `destroy()` keeps it.
extension SheepitClient {
    /// Send feedback from the app's user. The SDK attaches where it came from: the device, session
    /// and identified user (`identify(userId:)`), the app version and build, platform, OS version,
    /// device model, locale, the current screen (`screen(_:)` / `setScreen(_:)`) and the SDK
    /// version. Only what you pass is sent beyond that: `email` is never filled in for you, and the
    /// SDK never captures the screen — `screenshots` are images your app made.
    ///
    /// Checked before any request, against the server's limits: `message` 1-5000 characters after
    /// trimming; `email` a valid address of at most 256 characters; at most 20 `attributes`, keys
    /// of 1-64 `A-Z a-z 0-9 _ . -` (not a reserved tenancy key), strings up to 256 characters,
    /// finite numbers; at most 3 screenshots, each at most 1 MiB and 16384 pixels a side. A
    /// submission that fails a check returns `.rejected` and nothing is sent or saved.
    ///
    /// When it cannot be delivered now (offline, timeout, 408, 429, 5xx) it is saved on the device
    /// and `.queued` is returned; the SDK retries it, honouring the server's `Retry-After`, for up
    /// to 7 days, keeping at most 10 items (the oldest is dropped first). Any other 4xx is final:
    /// `.rejected(.server(statusCode:code:))`. One request is out at a time; a call made while
    /// another is in flight waits for it. `reset()` deletes everything queued, under every key.
    /// `message`, `email` and attribute strings containing U+0000 are rejected.
    ///
    /// Every outcome emits a `transport.feedback_upload` diagnostic (`diagnostics()`).
    @discardableResult
    public func submitFeedback(
        message: String,
        type: SheepitFeedbackType = .general,
        email: String? = nil,
        attributes: [String: SheepitFeedbackAttributeValue] = [:],
        screenshots: [SheepitFeedbackScreenshot] = []
    ) async -> SheepitFeedbackResult {
        guard inertReason == nil, !destroyedFlag.value else { return .rejected(.clientUnavailable) }
        let built = FeedbackValidator.build(
            message: message,
            type: type,
            email: email,
            attributes: attributes,
            screenshots: screenshots,
            context: feedbackContext()
        )
        switch built {
        case .failure(let rejection):
            diagnosticBus.emit(
                .warn,
                .transport,
                code: "transport.feedback_upload",
                message: "Feedback failed validation on the device; not sent",
                data: ["outcome": AnyCodable("invalid"), "reason": AnyCodable(rejection.diagnosticName)]
            )
            return .rejected(rejection)
        case .success(let submission):
            return await feedbackSender.submit(submission)
        }
    }

    func feedbackContext() -> FeedbackContext {
        let snapshot = context.eventContext()
        return FeedbackContext(
            deviceId: snapshot.deviceId,
            sessionId: snapshot.sessionId,
            userId: snapshot.userId,
            appVersion: DeviceProfile.wireAppVersion(override: feedbackSender.appVersionOverride),
            buildNumber: DeviceProfile.wireBuildNumber(),
            platform: snapshot.platform,
            osVersion: DeviceProfile.osVersion(),
            deviceModel: DeviceProfile.deviceModel(),
            locale: snapshot.locale,
            screen: currentScreen.value,
            sdkName: SDKDefaults.sdkName,
            sdkVersion: SDKDefaults.sdkVersion
        )
    }
}
