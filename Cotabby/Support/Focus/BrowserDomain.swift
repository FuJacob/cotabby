import Foundation

/// File overview:
/// Pure helpers for turning a focused browser tab's URL into a comparable host and deciding whether
/// that host falls under a user-configured disable list. Kept separate from focus capture (where the
/// raw URL is read over Accessibility) so the parsing and matching rules stay trivially testable and
/// reusable, independent of how the URL was obtained.
enum BrowserDomain {
    /// Extracts the lowercased host from a URL string, dropping a leading "www." so "www.bank.com" and
    /// "bank.com" compare equal. Returns nil for URLs without a network host (file://, about:, data:,
    /// empty, unparseable), so non-web focus never matches a domain rule.
    static func host(fromURLString urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let host = components.host,
              !host.isEmpty
        else {
            return nil
        }
        return stripLeadingWWW(host.lowercased())
    }

    /// Whether `host` is covered by `disabledDomains`: an exact match, or a subdomain of a listed
    /// domain ("mail.bank.com" is disabled by "bank.com"). Comparison is case-insensitive and
    /// "www."-insensitive on both sides, and tolerates list entries pasted as full URLs. An empty/nil
    /// host or empty list never matches.
    static func isHostDisabled(_ host: String?, disabledDomains: Set<String>) -> Bool {
        guard let host, !host.isEmpty, !disabledDomains.isEmpty else {
            return false
        }
        for entry in disabledDomains {
            guard let domain = normalize(entry) else { continue }
            if host == domain || host.hasSuffix("." + domain) {
                return true
            }
        }
        return false
    }

    /// Normalizes a configured list entry the same way a parsed host is normalized, tolerating a user
    /// pasting either a full URL ("https://bank.com/login") or a bare host ("bank.com").
    private static func normalize(_ entry: String) -> String? {
        let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let parsed = host(fromURLString: trimmed) {
            return parsed
        }
        return stripLeadingWWW(trimmed.lowercased())
    }

    private static func stripLeadingWWW(_ host: String) -> String {
        guard host.hasPrefix("www."), host.count > 4 else { return host }
        return String(host.dropFirst(4))
    }
}
