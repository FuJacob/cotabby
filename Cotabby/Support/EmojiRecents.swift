import Foundation

/// File overview:
/// Builds the suggestion list shown when the user types a bare `:` (no query yet). It is pure so it
/// is trivially testable: personal recents first (most recent first), then the curated popularity
/// prior to fill the panel, de-duplicated and resolved against the catalog.
///
/// This is what makes the very first `:` useful instead of empty. A brand-new user with no history
/// sees popular emoji; a returning user sees what they actually reach for. Variant resolution (skin
/// tone / gender) is applied by the caller, the same way it is for query results.
enum EmojiRecents {
    /// Recents-first, popularity-padded suggestions for an empty query, capped at `limit`.
    static func suggestions(
        usage: EmojiUsageSnapshot,
        catalog: EmojiCatalog,
        limit: Int = EmojiMatcher.defaultLimit
    ) -> [EmojiMatch] {
        guard limit > 0 else { return [] }

        var orderedAliases: [String] = []
        var seen = Set<String>()
        func append(_ alias: String) {
            let key = alias.lowercased()
            guard !seen.contains(key) else { return }
            seen.insert(key)
            orderedAliases.append(key)
        }

        usage.recentAliases.forEach(append)
        // Pad from a generous slice of the popularity prior so that, after some recents fail to
        // resolve (a refreshed dataset dropped an alias) or duplicate the prior, we still fill `limit`.
        EmojiPopularity.starterAliases(limit: limit * 3).forEach(append)

        var result: [EmojiMatch] = []
        for alias in orderedAliases {
            guard let entry = catalog.entry(forAlias: alias) else { continue }
            result.append(EmojiMatch(entry: entry))
            if result.count >= limit { break }
        }
        return result
    }
}
