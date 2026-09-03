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
/// The SPM package carries no tag yet, so there are no known external
/// consumers — but the source repository has been shared, and a shim costs
/// nothing next to a customer hitting an unexplained "cannot find type"
/// after a `swift package update`. Xcode's fix-it applies the rename
/// automatically from `renamed:`.
///
/// Unlike the type renames above, the **module itself** (`GoaTechSDK` →
/// `SheepitSDK`, published to the public mirror `goatech-ai/sheepit-swift`)
/// got no shim: Swift has no module-alias mechanism, so `import GoaTechSDK`
/// cannot be kept compiling. Done now, before the first tag — the last
/// moment it costs nothing. After a tag, a module rename breaks every
/// customer's import line with no migration path.
///
/// Delete this file one minor version after the first public tag.

// MARK: - LaunchPad → Sheepit (brand rename)

@available(*, deprecated, renamed: "SheepitSpan")
public typealias LPSpan = SheepitSpan

@available(*, deprecated, renamed: "SheepitBreadcrumb")
public typealias LPBreadcrumb = SheepitBreadcrumb

// MARK: - GoaTech* / GT* → Sheepit* (prefix unification)

@available(*, deprecated, renamed: "Sheepit")
public typealias GoaTech = Sheepit

@available(*, deprecated, renamed: "SheepitConfig")
public typealias GoaTechConfig = SheepitConfig

@available(*, deprecated, renamed: "SheepitExperimentResult")
public typealias GTExperimentResult = SheepitExperimentResult

@available(*, deprecated, renamed: "SheepitPerformanceSummary")
public typealias GTPerformanceSummary = SheepitPerformanceSummary
