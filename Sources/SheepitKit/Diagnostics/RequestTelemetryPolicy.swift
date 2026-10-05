import Foundation

/// Which URLs `SheepitClient.recordRequest(...)` may record, and the privacy-reduced form it
/// records them in. Built once from `SheepitConfig.requestTelemetryHosts` and `apiUrl` when the
/// client is constructed; immutable and `Sendable` afterwards, so a check takes no lock.
///
/// - Allowlist: an entry is a bare host name, matched exactly and case-insensitively (one trailing
///   `.` and IPv6 brackets are ignored on both sides). An entry `*.example.com` matches every
///   subdomain of `example.com` at any depth, but NOT `example.com` itself — list the apex
///   separately. A wildcard over a single label (`*.com`, `*.localhost`) is refused; there is no
///   public-suffix list, so `*.co.uk` is still accepted. An entry carrying a scheme, port, path,
///   userinfo, query, whitespace, a control character or a `*` anywhere but the leading `*.` —
///   checked again after `URLComponents` percent-decodes it — or with a leading dot or an empty
///   label, is ignored and counted in `ignoredEntries` (the client reports them as one
///   `request_telemetry.invalid_host` diagnostic).
/// - Hosts are compared in the form `URLComponents.host` returns, and every entry is passed
///   through `URLComponents` too, so an entry and a request URL are canonicalized by the same
///   Foundation on the same OS. Measured on macOS 27: an IDN's `xn--` (punycode) host comes back
///   decoded (`bücher.example`), and an entry in either form matches it.
/// - The SDK's own API is never recorded, allowlisted or not: a URL on `apiUrl`'s host whose path
///   is `apiUrl`'s path or below it (any path, when `apiUrl` has none). Scheme and port are not
///   compared, so the exclusion errs towards dropping. This is what stops a host-wide network
///   interceptor that also sees the SDK's own failing uploads from feeding them back as events.
///   When `apiUrl` has no path AND its host is allowlisted, that is EVERY request to the host —
///   `apiHostExcluded` is then set, and the client reports it once
///   (`request_telemetry.api_host_excluded`). A proxy that rewrites the host defeats the
///   exclusion; the limiter is what bounds that loop.
struct RequestTelemetryPolicy: Sendable {
    /// The parts of a request URL that are sent. Never the query, fragment or userinfo.
    struct Target: Equatable, Sendable {
        /// `scheme://host[:port]path` — the port only when it is not the scheme's default.
        let url: String
        /// Lowercased, without a trailing `.`; IPv6 without brackets.
        let host: String
        /// The percent-encoded path, verbatim; `/` when the URL has none.
        let path: String
    }

    private let exactHosts: Set<String>
    /// Each entry is a suffix that starts with `.`, e.g. `.example.com` for `*.example.com`.
    private let subdomainSuffixes: [String]
    private let sdkHost: String?
    /// `apiUrl`'s path without its trailing `/`; empty when the SDK owns the whole host.
    private let sdkPath: String
    /// Allowlist entries that could not be used. Reported once, by the client.
    let ignoredEntries: Int
    /// `apiUrl`'s host when `apiUrl` has no path and that host is allowlisted: every request to
    /// it is excluded as the SDK's own. Reported once, by the client.
    let apiHostExcluded: String?

    init(hosts: [String], apiUrl: String) {
        var exact = Set<String>()
        var suffixes: [String] = []
        var ignored = 0
        for entry in hosts {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            let wildcard = trimmed.hasPrefix("*.")
            guard let host = Self.normalizedEntry(wildcard ? String(trimmed.dropFirst(2)) : trimmed),
                  !wildcard || host.contains(".") else {
                ignored += 1
                continue
            }
            if wildcard { suffixes.append("." + host) } else { exact.insert(host) }
        }
        exactHosts = exact
        subdomainSuffixes = suffixes
        ignoredEntries = ignored

        let base = URL(string: HTTPClient.normalizedBaseURLString(apiUrl))
            .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
        sdkHost = base?.host.map(Self.normalizedHost)
        var path = base?.percentEncodedPath ?? ""
        while path.hasSuffix("/") { path.removeLast() }
        sdkPath = path
        if path.isEmpty, let sdkHost, Self.matches(sdkHost, exact: exact, suffixes: suffixes) {
            apiHostExcluded = sdkHost
        } else {
            apiHostExcluded = nil
        }
    }

    /// True when nothing is allowlisted — `recordRequest` then returns before parsing the URL.
    var isEmpty: Bool { exactHosts.isEmpty && subdomainSuffixes.isEmpty }

    /// The recordable form of `url`, or nil when it has no host, its host is not allowlisted, or
    /// it is the SDK's own API.
    func target(for url: URL) -> Target? {
        guard !isEmpty,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let rawHost = components.host, !rawHost.isEmpty,
              let scheme = components.scheme?.lowercased(), !scheme.isEmpty else { return nil }
        let host = Self.normalizedHost(rawHost)
        guard !host.isEmpty, isAllowlisted(host) else { return nil }
        let path = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        guard !isSDKOwn(host: host, path: path) else { return nil }

        var origin = scheme + "://" + (host.contains(":") ? "[\(host)]" : host)
        if let port = components.port, port != Self.defaultPort(for: scheme) {
            origin += ":\(port)"
        }
        return Target(url: origin + path, host: host, path: path)
    }

    private func isAllowlisted(_ host: String) -> Bool {
        Self.matches(host, exact: exactHosts, suffixes: subdomainSuffixes)
    }

    private static func matches(_ host: String, exact: Set<String>, suffixes: [String]) -> Bool {
        exact.contains(host) || suffixes.contains { host.hasSuffix($0) }
    }

    private func isSDKOwn(host: String, path: String) -> Bool {
        guard let sdkHost, host == sdkHost else { return false }
        return sdkPath.isEmpty || path == sdkPath || path.hasPrefix(sdkPath + "/")
    }

    private static func defaultPort(for scheme: String) -> Int? {
        switch scheme {
        case "http", "ws": return 80
        case "https", "wss": return 443
        default: return nil
        }
    }

    /// Lowercased, IPv6 brackets and one trailing `.` removed.
    static func normalizedHost(_ host: String) -> String {
        var out = host.lowercased()
        if out.hasPrefix("["), out.hasSuffix("]") { out = String(out.dropFirst().dropLast()) }
        if out.hasSuffix(".") { out.removeLast() }
        return out
    }

    /// A usable allowlist entry, normalized, or nil. An IPv6 address (two or more `:`) is
    /// accepted; a single `:` can only be a port, which an entry may not carry. A DNS name is then
    /// canonicalized by `URLComponents`, as `target(for:)`'s hosts are (see the type doc), and
    /// checked AGAIN in that form: `URLComponents` percent-decodes, so `exa%2Fmple.com` only
    /// shows its `/` after canonicalization. A name `URLComponents` cannot parse, one with a
    /// leading dot or an empty label (`a..b`), or one with a control character is refused —
    /// it could never match a request host.
    private static func normalizedEntry(_ entry: String) -> String? {
        let host = normalizedHost(entry.trimmingCharacters(in: .whitespacesAndNewlines))
        guard isUsable(host) else { return nil }
        if host.contains(":") { return host }
        guard let parsed = URLComponents(string: "http://" + host)?.host else { return nil }
        let canonical = normalizedHost(parsed)
        guard isUsable(canonical), !canonical.contains(":"),
              !canonical.split(separator: ".", omittingEmptySubsequences: false).contains(where: \.isEmpty)
        else { return nil }
        return canonical
    }

    private static func isUsable(_ host: String) -> Bool {
        !host.isEmpty
            && host.rangeOfCharacter(from: forbidden) == nil
            && host.filter({ $0 == ":" }).count != 1
    }

    private static let forbidden = CharacterSet(charactersIn: "/?#@*[]\\ ")
        .union(.whitespacesAndNewlines)
        .union(.controlCharacters)
}
