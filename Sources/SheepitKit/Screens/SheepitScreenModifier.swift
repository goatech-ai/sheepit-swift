import Foundation

/// Decides, for one view, whether an `onAppear` should record a screen view: once per
/// appearance, never again until `onDisappear` has run.
///
/// SwiftUI may call `onAppear` more than once without the view leaving (a container re-attaching
/// its content, a `TabView` re-selection). A screen view per call would double-count; a screen
/// view per appearance is what `UIViewController.viewDidAppear` tracking gives UIKit apps.
/// Lock-guarded because the closures are `@Sendable` under strict concurrency, though SwiftUI
/// runs them on the main thread.
final class ScreenAppearanceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var visible = false

    /// True when this appearance has not been recorded yet.
    func appeared() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !visible else { return false }
        visible = true
        return true
    }

    func disappeared() {
        lock.lock()
        defer { lock.unlock() }
        visible = false
    }
}

#if canImport(SwiftUI)
import SwiftUI

extension View {
    /// Records a `$screen` view (`SheepitClient.screen(_:properties:)`) each time this view
    /// appears, and sets the crash context's screen.
    ///
    /// ```swift
    /// CheckoutView().sheepitScreen("Checkout")
    /// ```
    ///
    /// Once per appearance: a repeated `onAppear` with no `onDisappear` between does not track
    /// again, so a re-render or container re-attach does not double-count. It does nothing before
    /// the SDK is created or after `destroy()`, and never throws or blocks the view.
    /// A name that is empty after trimming is dropped with a diagnostic, like `screen(_:)`.
    ///
    /// - Parameters:
    ///   - name: the screen name; fixed for the view's lifetime.
    ///   - properties: extra event properties.
    ///   - client: defaults to `SheepitClient.shared`.
    public func sheepitScreen(
        _ name: String,
        properties: [String: Any]? = nil,
        client: SheepitClient? = nil
    ) -> some View {
        modifier(SheepitScreenModifier(name: name, properties: properties, client: client))
    }
}

struct SheepitScreenModifier: ViewModifier {
    let name: String
    let properties: [String: Any]?
    let client: SheepitClient?
    @State private var gate = ScreenAppearanceGate()

    func body(content: Content) -> some View {
        content
            .onAppear {
                // Resolve the client first: a view that appears before `create` ran (the SDK is
                // often created from a `.task`) must not spend its appearance on nothing.
                guard let target = client ?? SheepitClient.shared, gate.appeared() else { return }
                target.screen(name, properties: properties)
            }
            .onDisappear { gate.disappeared() }
    }
}
#endif
