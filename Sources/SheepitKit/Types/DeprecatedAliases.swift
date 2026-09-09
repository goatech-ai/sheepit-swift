import Foundation

/// Compatibility shims for the public-API renames.
///
/// Two waves live here:
///
/// 1. **`LP*` → `Sheepit*`** — the LaunchPad → Sheepit brand change (0.2.0).
/// 2. **`GoaTech*` / `GT*` → `Sheepit*`** — the prefix unification (0.2.0),
///    which brings the Swift SDK's public surface in line with
///    `@sheepit-ai/sdk-js`, where the same types are already `Sheepit` and
///    `SheepitConfig`.
///
/// A type shim costs nothing next to a customer hitting an unexplained
/// "cannot find type" after a `swift package update`, and Xcode's fix-it
/// applies the rename automatically from `renamed:`.
///
/// Unlike the type renames above, a **module** rename gets no shim: Swift
/// has no module-alias mechanism, so the old `import` line cannot be kept
/// compiling. This package has now taken two of them — `GoaTechSDK` →
/// `SheepitSDK` (before `1.0.0`, when no tag existed), and `SheepitSDK` →
/// `SheepitKit` in `0.3.0`. The package is deliberately back on `0.x` until
/// the API stabilises (see CHANGELOG "Version policy"), so a breaking change
/// rides a minor bump rather than a major.
///
/// Delete this file one minor version after the first public tag.

// MARK: - LaunchPad → Sheepit (brand rename)

@available(*, deprecated, renamed: "SheepitSpan")
public typealias LPSpan = SheepitSpan

@available(*, deprecated, renamed: "SheepitBreadcrumb")
public typealias LPBreadcrumb = SheepitBreadcrumb

// MARK: - GoaTech* / GT* → Sheepit* (prefix unification)

@available(*, deprecated, renamed: "SheepitClient")
public typealias GoaTech = SheepitClient

@available(*, deprecated, renamed: "SheepitConfig")
public typealias GoaTechConfig = SheepitConfig

@available(*, deprecated, renamed: "SheepitExperimentResult")
public typealias GTExperimentResult = SheepitExperimentResult

@available(*, deprecated, renamed: "SheepitPerformanceSummary")
public typealias GTPerformanceSummary = SheepitPerformanceSummary
