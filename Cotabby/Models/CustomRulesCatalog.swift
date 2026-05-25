import Foundation

/// File overview:
/// Defines Cotabby's custom autocomplete "rules" — short imperative style directives the user can
/// add as tags. A rule is one clause of the same shape as the prompt's built-in rules (e.g.
/// "Never use em dashes"), so the renderers can emit each as a single bullet.
///
/// `defaultRules` ship enabled and are what the Reset action restores. `suggestedPalette` is the
/// broader set surfaced as tappable chips so users are never staring at a blank box. `normalize`
/// is the single chokepoint that keeps stored rules bounded and de-duplicated regardless of whether
/// they came from onboarding, settings, the palette, or a future import path.
enum CustomRulesCatalog {
    /// Caps protect the local model's limited context budget and guard against pasted essays.
    static let maxRules = 10
    static let maxRuleLength = 60

    /// Neutral, broadly-safe rules that ship enabled and that Reset restores. Opinionated style
    /// rules (British spelling, lowercase, formal/casual) are intentionally palette-only because
    /// they are wrong defaults for most users.
    static let defaultRules: [String] = [
        "Write concisely",
        "Match my existing tone"
    ]

    /// The full set of tappable suggestions shown in the editor. Includes the defaults so the chip
    /// row stays complete even after a Reset.
    static let suggestedPalette: [String] = [
        "Write concisely",
        "Match my existing tone",
        "Use British spelling",
        "Never use em dashes",
        "Keep a casual tone",
        "Keep a formal tone",
        "Default to lowercase",
        "Avoid exclamation marks"
    ]

    /// Trims, drops empties, truncates over-long rules, de-duplicates case-insensitively (keeping
    /// the first occurrence and its original casing), and caps the count. The single place all rule
    /// mutations pass through.
    static func normalize(_ rules: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for rule in rules {
            let trimmed = rule.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            let bounded = String(trimmed.prefix(maxRuleLength))
            let key = bounded.lowercased()
            guard seen.insert(key).inserted else { continue }

            result.append(bounded)
            if result.count >= maxRules { break }
        }

        return result
    }
}
