import Foundation

/// File overview:
/// Defines Cotabby's custom autocomplete "rules" — short imperative style directives the user can
/// add as tags. A rule is one clause of the same shape as the prompt's built-in rules (e.g.
/// "Never use em dashes"), so the renderers can emit each as a single bullet.
///
/// `defaultRules` is the baseline the editor's "Clear" action restores (currently empty — rules are
/// opt-in). `suggestedPalette` is the
/// broader set surfaced as tappable chips so users are never staring at a blank box. `normalize`
/// is the single chokepoint that keeps stored rules bounded and de-duplicated regardless of whether
/// they came from onboarding, settings, the palette, or a future import path.
enum CustomRulesCatalog {
    /// Caps protect the local model's limited context budget and guard against pasted essays.
    static let maxRules = 10
    static let maxRuleLength = 60

    /// Nothing ships enabled — rules are opt-in. "Clear" in the editor restores this empty state.
    static let defaultRules: [String] = []

    /// Tappable suggestions shown in the editor. Chosen to span the common axes people care about —
    /// tone, length, formatting, locale spelling, and punctuation — so most users find at least one
    /// that fits without typing their own. Several are mutually exclusive on purpose (casual vs
    /// professional, British vs American); they're choices, not a recommended stack.
    static let suggestedPalette: [String] = [
        "Write concisely",
        "Match my tone",
        "Keep it casual",
        "Keep it professional",
        "Avoid jargon",
        "Never use em dashes",
        "Avoid exclamation marks",
        "Don't use emoji",
        "Use British spelling",
        "Use American spelling",
        "Default to lowercase",
        "Use the Oxford comma"
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
