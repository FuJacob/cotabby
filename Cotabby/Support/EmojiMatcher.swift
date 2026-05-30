import Foundation

/// File overview:
/// Ranks emoji against a typed query for the inline picker. This is a pure value type: the same
/// query and catalog always produce the same ordered results, which keeps it trivially testable and
/// safe to call on the main actor between keystrokes.
///
/// Ranking favors the canonical `:alias:` tokens, then prefix over substring, then name and keyword
/// hits, with a deterministic tiebreak (shorter matched token first, then original catalog order).
/// The matched-token length tiebreak is what makes `smile` rank `:smile:` above `:smiley:`.
struct EmojiMatcher {
    let catalog: EmojiCatalog

    /// Default number of rows the panel shows. Bounded so a one-character query does not build a
    /// thousand-element result array we immediately discard.
    static let defaultLimit = 24

    func matches(for rawQuery: String, limit: Int = EmojiMatcher.defaultLimit) -> [EmojiMatch] {
        let query = rawQuery.lowercased().trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, limit > 0 else { return [] }

        var scored: [ScoredMatch] = []
        for (index, indexed) in catalog.indexed.enumerated() {
            guard let hit = bestHit(query: query, indexed: indexed) else { continue }
            scored.append(
                ScoredMatch(
                    match: EmojiMatch(entry: indexed.entry),
                    tier: hit.tier,
                    tokenLength: hit.tokenLength,
                    catalogIndex: index
                )
            )
        }

        scored.sort { lhs, rhs in
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            if lhs.tokenLength != rhs.tokenLength { return lhs.tokenLength < rhs.tokenLength }
            return lhs.catalogIndex < rhs.catalogIndex
        }

        return scored.prefix(limit).map { $0.match }
    }

    private struct ScoredMatch {
        let match: EmojiMatch
        let tier: Int
        let tokenLength: Int
        let catalogIndex: Int
    }

    /// Lower tier is a better match. Returns the strongest tier this entry achieves plus the length
    /// of the matched token (for the secondary tiebreak), or `nil` when nothing matches.
    private func bestHit(query: String, indexed: EmojiCatalog.IndexedEntry) -> (tier: Int, tokenLength: Int)? {
        var bestTier = Int.max
        var bestTokenLength = 0

        func record(_ tier: Int, _ tokenLength: Int) {
            guard tier < bestTier else { return }
            bestTier = tier
            bestTokenLength = tokenLength
        }

        for alias in indexed.lowerAliases {
            if alias == query {
                return (0, alias.count)
            }
            if alias.hasPrefix(query) {
                record(1, alias.count)
            } else if alias.contains(query) {
                record(3, alias.count)
            }
        }

        for keyword in indexed.lowerKeywords {
            if keyword == query || keyword.hasPrefix(query) {
                record(2, keyword.count)
            } else if keyword.contains(query) {
                record(4, keyword.count)
            }
        }

        if indexed.lowerName.hasPrefix(query) {
            record(2, indexed.lowerName.count)
        } else if indexed.lowerName.contains(query) {
            record(4, indexed.lowerName.count)
        }

        return bestTier == Int.max ? nil : (bestTier, bestTokenLength)
    }
}
