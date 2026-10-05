import Foundation

/// `SheepitConfig(bundle:)`: the xcconfig → Info.plist → SDK configuration path. Reads
/// `SheepitAPIKey` (required), `SheepitAPIURL` and `SheepitEnvironment` (optional). A value that
/// cannot be used never crashes the host and never falls back to the hosted API: it becomes an
/// `InfoPlistIssue`, which `SheepitClient.constructOnly` turns into an inert client. Customer
/// docs: README "Configure with xcconfig".
extension SheepitConfig {
    /// Builds a configuration from `bundle`'s Info.plist.
    ///
    /// | Key                  | Required | When absent       |
    /// | -------------------- | -------- | ----------------- |
    /// | `SheepitAPIKey`      | yes      | inert client      |
    /// | `SheepitAPIURL`      | no       | `defaultAPIUrl`   |
    /// | `SheepitEnvironment` | no       | `"production"`    |
    ///
    /// `SheepitAPIURL` may be a bare host, optionally with a path (`sheepit.example.com/_sheepit`),
    /// and `https://` is prepended; xcconfig reads `//` as a comment, so a full URL cannot be
    /// written there directly. A full URL is used as written. One pair of surrounding quotes is
    /// stripped from every value.
    ///
    /// A key that is present but empty, holds an unexpanded `$(…)` reference, or holds a URL cut
    /// off at `//` (`https:`) produces an inert client whose `status().rejectionReason` names the
    /// key and the fix. So does `SheepitAPIKey` or `SheepitAPIURL` missing under its exact name
    /// when a variant differing only in case, whitespace or punctuation is present
    /// (`SheepitAPIUrl`, `SHEEPIT_API_URL`): key names are case-sensitive, and reading the variant
    /// as absent would silently send a self-hosted app's events to the hosted API. Such a variant
    /// of `SheepitEnvironment` only warns and keeps `"production"`. An empty or unexpanded
    /// `SheepitAPIURL` is never read as "use the hosted default": only a key that is absent
    /// altogether means that, and a started client then logs the host it uses. No message echoes
    /// a configured `SheepitAPIURL` or `SheepitAPIKey` value.
    ///
    /// Every other property keeps its default and can be set on the result before
    /// `SheepitClient.create(config:)`. Setting `apiUrl` or `environment` yourself clears that
    /// field's Info.plist issue; an `apiKey` issue cannot be cleared this way, because `apiKey` is
    /// a `let` — fix the plist or use `init(apiKey:…)`.
    ///
    /// App extensions and widgets: `Bundle.main` there is the extension's own bundle, so each
    /// extension target needs the keys in its own Info.plist.
    public init(bundle: Bundle = .main) {
        self.init(infoDictionary: bundle.infoDictionary ?? [:])
    }

    /// The seam `init(bundle:)` delegates to, so tests need no real bundle.
    init(infoDictionary info: [String: Any]) {
        var issues: [InfoPlistIssue] = []
        let apiKey = InfoPlistReader.apiKey(in: info, issues: &issues)
        let apiUrl = InfoPlistReader.apiURL(in: info, issues: &issues)
        var warnings: [String] = []
        let environment = InfoPlistReader.environment(in: info, issues: &issues, warnings: &warnings)
        self.init(apiKey: apiKey, environment: environment, apiUrl: apiUrl)
        self.infoPlistIssues = issues
        self.infoPlistWarnings = warnings
        // A near-miss key leaves `apiUrl` empty, so `activeInfoPlistNotice` stays nil for it.
        self.apiURLDefaultedFromInfoPlist = info[InfoPlistReader.apiURLKey] == nil
    }

    /// The message for every Info.plist issue whose field still holds the empty value the reader
    /// left in it, or `nil` if there is none. A host that overwrites `apiUrl` or `environment`
    /// after `init(bundle:)` has resolved that field itself, so its issue no longer applies.
    var activeInfoPlistIssueMessage: String? {
        let active = infoPlistIssues.filter { issue in
            switch issue.field {
            case .apiKey: return apiKey.isEmpty
            case .apiUrl: return apiUrl.isEmpty
            case .environment: return environment.isEmpty
            }
        }
        return active.isEmpty ? nil : active.map(\.message).joined(separator: " ")
    }

    /// What a started client logs when `SheepitAPIURL` was absent and `apiUrl` is still the
    /// hosted default, so "am I pointed at my own install?" is answerable from the console.
    var activeInfoPlistNotice: String? {
        guard apiURLDefaultedFromInfoPlist, apiUrl == SheepitConfig.defaultAPIUrl else { return nil }
        let host = URL(string: apiUrl)?.host ?? apiUrl
        return "Info.plist has no \(InfoPlistReader.apiURLKey), so events go to the hosted Sheepit "
            + "API at \(host). If you self-host, add \(InfoPlistReader.apiURLKey) with your host."
    }

    /// Warnings a started client logs and emits. The only one today is a `SheepitEnvironment`
    /// spelling variant, which fell back to `"production"`; a host that set `environment` itself
    /// has resolved it.
    var activeInfoPlistWarnings: [String] {
        environment == "production" ? infoPlistWarnings : []
    }

    /// The Info.plist reason repeated for the unredacted console, or `nil` when `inertReason`
    /// did not come from Info.plist. Safe to log publicly: no Info.plist message echoes a
    /// configured value (a URL may carry gateway credentials, in forms `redactingUserinfo` does
    /// not recognise, such as `https:/user:pass@host`).
    func infoPlistConsoleWarning(forInertReason inertReason: String) -> String? {
        guard let message = activeInfoPlistIssueMessage, message == inertReason else { return nil }
        return message
    }
}

/// One Info.plist value `SheepitConfig(infoDictionary:)` could not use. The field it concerns is
/// left as `""`, which every generic admission gate also rejects.
struct InfoPlistIssue: Sendable, Equatable {
    enum Field: Sendable, Equatable {
        case apiKey, apiUrl, environment
    }

    let field: Field
    let message: String
}

enum InfoPlistReader {
    static let apiKeyKey = "SheepitAPIKey"
    static let apiURLKey = "SheepitAPIURL"
    static let environmentKey = "SheepitEnvironment"

    /// Diagnostic code of the notice a started client emits when `SheepitAPIURL` was absent.
    static let hostedDefaultCode = "config.hosted_default_api_url"
    /// Diagnostic code of a non-fatal Info.plist warning (see `activeInfoPlistWarnings`).
    static let warningCode = "config.info_plist_warning"

    private static let inert = "The Sheepit client is inert until this is fixed."

    static func apiKey(in info: [String: Any], issues: inout [InfoPlistIssue]) -> String {
        switch lookup(apiKeyKey, in: info) {
        case .absent:
            issues.append(.init(field: .apiKey, message: "Info.plist has no \(apiKeyKey) entry. "
                + "Add \(apiKeyKey) with the value $(SHEEPIT_API_KEY) in the target's Info tab and "
                + "define SHEEPIT_API_KEY in the xcconfig of every build configuration. \(inert)"))
            return ""
        case .unusable(let reason), .misspelled(let reason):
            issues.append(.init(field: .apiKey, message: "\(reason) \(inert)"))
            return ""
        case .value(let value):
            return value
        }
    }

    /// A spelling variant only warns: unlike the URL, a wrong environment label sends no data
    /// anywhere it should not go, so it must not brick an app that worked before.
    static func environment(
        in info: [String: Any], issues: inout [InfoPlistIssue], warnings: inout [String]
    ) -> String {
        switch lookup(environmentKey, in: info) {
        case .absent:
            return "production"
        case .misspelled(let reason):
            warnings.append("\(reason) Using \"production\" until then.")
            return "production"
        case .unusable(let reason):
            issues.append(.init(field: .environment, message: "\(reason) \(inert)"))
            return ""
        case .value(let value):
            return value
        }
    }

    /// Absent → the hosted default. Present → a bare host (https:// prepended) or a full URL, or
    /// an issue. Present-but-unusable must NOT fall back to the hosted default: for a self-hosted
    /// install that would send its users' events to Sheepit's cloud.
    static func apiURL(in info: [String: Any], issues: inout [InfoPlistIssue]) -> String {
        let noFallback = "SheepitKit does not fall back to \(SheepitConfig.defaultAPIUrl) for a "
            + "\(apiURLKey) that is present but unusable; remove the key entirely to use it. \(inert)"
        let value: String
        switch lookup(apiURLKey, in: info) {
        case .absent:
            return SheepitConfig.defaultAPIUrl
        case .unusable(let reason), .misspelled(let reason):
            issues.append(.init(field: .apiUrl, message: "\(reason) \(noFallback)"))
            return ""
        case .value(let v):
            value = v
        }

        // Messages below never echo `value`: they reach a public log line and the public
        // `status().rejectionReason`, and a gateway URL may carry credentials. The truncated
        // forms are the one exception, as `value` is then one of four fixed strings.
        let lower = value.lowercased()
        let candidate: String
        if ["http:", "https:", "http:/", "https:/"].contains(lower) {
            issues.append(.init(field: .apiUrl, message: "Info.plist \(apiURLKey) is \(value.debugDescription): the "
                + "URL was cut off at \"//\", which an .xcconfig file reads as the start of a comment. "
                + "Set the bare host instead, e.g. SHEEPIT_API_URL = sheepit.example.com (or "
                + "sheepit.example.com/_sheepit); SheepitKit prepends https://. \(noFallback)"))
            return ""
        } else if lower.contains("://") {
            candidate = value
        } else if lower.hasPrefix("http:") || lower.hasPrefix("https:") {
            issues.append(.init(field: .apiUrl, message: "Info.plist \(apiURLKey) starts with a "
                + "scheme but has no \"//\" after it. Set the bare host instead, e.g. SHEEPIT_API_URL = "
                + "sheepit.example.com; SheepitKit prepends https://. \(noFallback)"))
            return ""
        } else {
            candidate = "https://" + value
        }

        if SheepitClient.apiURLRejectionReason(for: candidate) != nil {
            issues.append(.init(field: .apiUrl, message: "Info.plist \(apiURLKey) does not form a "
                + "usable URL: it needs a host, e.g. sheepit.example.com or "
                + "sheepit.example.com/_sheepit. \(noFallback)"))
            return ""
        }
        return candidate
    }

    private enum Lookup {
        case absent
        case unusable(String)
        /// The exact key is missing but a spelling variant of it is present.
        case misspelled(String)
        case value(String)
    }

    /// Trimmed, unquoted string value of `key`. Present-but-empty, an unexpanded `$(…)`, and a
    /// near-miss spelling with the exact key missing are unusable, not absent: each means the
    /// build was meant to supply a value and did not. The value is never echoed, since this also
    /// reads the API key.
    private static func lookup(_ key: String, in info: [String: Any]) -> Lookup {
        guard let raw = info[key] else {
            let found = nearMissKeys(for: key, in: info)
            guard !found.isEmpty else { return .absent }
            let names = found.map(\.debugDescription).joined(separator: ", ")
            return .misspelled("Info.plist has no \(key) entry but has \(names). Key names are "
                + "case-sensitive: rename it to exactly \(key).")
        }
        guard let string = raw as? String else {
            return .unusable("Info.plist \(key) must be a String, not \(type(of: raw)).")
        }
        let trimmed = unquoted(string.trimmingCharacters(in: .whitespacesAndNewlines))
        let fix = "Check that Project → Info → Configurations assigns your .xcconfig to this "
            + "target for every build configuration (Debug AND Release), and that the entry is in "
            + "the target's Info tab (Custom iOS Target Properties) with the value $(BUILD_SETTING)."
        if trimmed.isEmpty {
            return .unusable("Info.plist \(key) is empty: its build setting is not defined for this "
                + "build configuration. \(fix)")
        }
        if trimmed.contains("$(") || trimmed.contains("${") {
            return .unusable("Info.plist \(key) holds an unexpanded build-setting reference, so the "
                + "xcconfig value never reached it. \(fix) A plist copied as a resource, rather "
                + "than the target's own Info.plist, is not expanded.")
        }
        return .value(trimmed)
    }

    /// Present keys other than `key` that differ from it only in case, whitespace or punctuation
    /// (`SheepitAPIUrl`, `SHEEPIT_API_URL`, `"SheepitAPIURL "`), sorted so the message is
    /// deterministic. Such a name is made of `key`'s letters plus separators, so echoing it
    /// leaks nothing. Other spellings (`SheepitURL`) are not guessed at: they read as absent,
    /// and the hosted-default notice makes that visible.
    private static func nearMissKeys(for key: String, in info: [String: Any]) -> [String] {
        let wanted = normalized(key)
        return info.keys
            .filter { $0 != key && normalized($0) == wanted }
            .sorted()
    }

    private static func normalized(_ name: String) -> String {
        String(name.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Drops one leading and one trailing `"` or `'` independently, then re-trims: an xcconfig
    /// value written as `"https://host"` arrives as `"https:` (the closing quote went with the
    /// `//` comment), and must still get the `//` hint.
    private static func unquoted(_ value: String) -> String {
        var s = Substring(value)
        if let first = s.first, first == "\"" || first == "'" { s = s.dropFirst() }
        if let last = s.last, last == "\"" || last == "'" { s = s.dropLast() }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
