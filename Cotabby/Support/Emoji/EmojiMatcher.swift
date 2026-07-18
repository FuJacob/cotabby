import Foundation

/// File overview:
/// Ranks emoji against a typed query for the inline picker. This is a pure value type: the same
/// query, catalog, and usage snapshot always produce the same ordered results, which keeps it
/// trivially testable and safe to call on the main actor between keystrokes.
///
/// Relevance tiers (lower is better), evaluated per entry:
///   0  exact alias
///   1  alias prefix, or a curated synonym whose key the query exactly matches (`lol` -> 😂)
///   2  keyword/name prefix, or a synonym whose key the query is a prefix of
///   3  alias substring
///   4  keyword/name substring
///   5  fuzzy (typo) match, only as a fallback when stronger results are sparse
///
/// Within a tier the order is: personal favorites first (recent or frequent), then the shorter
/// matched token (so `smile` beats `smiley`), then the curated popularity prior, then catalog order.
/// Favorites and popularity only break ties inside a tier, so relevance is never sacrificed to make
/// a popular or frequently-used emoji jump ahead of a genuinely better match.
nonisolated struct EmojiMatcher {
    let catalog: EmojiCatalog

    /// Default number of rows the panel shows. Bounded so a one-character query does not build a
    /// thousand-element result array we immediately discard.
    static let defaultLimit = 24

    /// Fuzzy matching only kicks in for queries this long, so a one- or two-character query cannot
    /// pull in loosely-related typo candidates.
    private static let minFuzzyQueryLength = 3

    /// Relevance tiers. Named so the synonym and fuzzy passes can share the lexical scale.
    private enum Tier {
        static let exactAlias = 0
        static let aliasPrefix = 1
        static let synonymExact = 1
        static let keywordOrNamePrefix = 2
        static let synonymPrefix = 2
        static let aliasSubstring = 3
        static let keywordOrNameSubstring = 4
        static let fuzzy = 5
    }

    func matches(
        for rawQuery: String,
        usage: EmojiUsageSnapshot = .empty,
        limit: Int = EmojiMatcher.defaultLimit
    ) -> [EmojiMatch] {
        let query = rawQuery.lowercased().trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, limit > 0 else { return [] }

        let synonyms = EmojiSynonymCatalog.boostedAliases(for: query)

        var scored: [ScoredMatch] = []
        var matchedIndices = Set<Int>()
        for (index, indexed) in catalog.indexed.enumerated() {
            guard let hit = lexicalHit(query: query, synonyms: synonyms, indexed: indexed) else { continue }
            matchedIndices.insert(index)
            scored.append(makeScored(indexed: indexed, index: index, tier: hit.tier, tokenLength: hit.tokenLength, usage: usage))
        }

        // Fuzzy fallback runs only when lexical results are sparse and the query is long enough to be
        // discriminating, so typos still resolve ("hapy" -> 😄) without polluting result sets that
        // already have strong lexical matches.
        if scored.count < limit, query.count >= Self.minFuzzyQueryLength {
            let queryChars = Array(query)
            for (index, indexed) in catalog.indexed.enumerated() where !matchedIndices.contains(index) {
                guard let hit = fuzzyHit(queryChars: queryChars, queryCount: query.count, indexed: indexed) else { continue }
                scored.append(makeScored(indexed: indexed, index: index, tier: hit.tier, tokenLength: hit.tokenLength, usage: usage))
            }
        }

        scored.sort(by: Self.isOrderedBefore)
        return scored.prefix(limit).map { $0.match }
    }

    /// Suggestions for a bare `:` (no query): the user's recents first, padded with popular emoji.
    /// Kept here so callers can ask the matcher for "what to show before any typing" symmetrically
    /// with `matches(for:)`.
    func recents(usage: EmojiUsageSnapshot, limit: Int = EmojiMatcher.defaultLimit) -> [EmojiMatch] {
        EmojiRecents.suggestions(usage: usage, catalog: catalog, limit: limit)
    }

    private struct ScoredMatch {
        let match: EmojiMatch
        let tier: Int
        /// 0 when the emoji is a personal favorite (recent or frequent), 1 otherwise.
        let favoriteBucket: Int
        let tokenLength: Int
        let popularityRank: Int
        let catalogIndex: Int
    }

    private func makeScored(
        indexed: EmojiCatalog.IndexedEntry,
        index: Int,
        tier: Int,
        tokenLength: Int,
        usage: EmojiUsageSnapshot
    ) -> ScoredMatch {
        let primaryAlias = indexed.lowerAliases.first ?? indexed.lowerName
        return ScoredMatch(
            match: EmojiMatch(entry: indexed.entry),
            tier: tier,
            favoriteBucket: usage.isFavorite(primaryAlias) ? 0 : 1,
            tokenLength: tokenLength,
            popularityRank: EmojiPopularity.rank(forAlias: primaryAlias),
            catalogIndex: index
        )
    }

    private static func isOrderedBefore(_ lhs: ScoredMatch, _ rhs: ScoredMatch) -> Bool {
        if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
        if lhs.favoriteBucket != rhs.favoriteBucket { return lhs.favoriteBucket < rhs.favoriteBucket }
        if lhs.tokenLength != rhs.tokenLength { return lhs.tokenLength < rhs.tokenLength }
        if lhs.popularityRank != rhs.popularityRank { return lhs.popularityRank < rhs.popularityRank }
        return lhs.catalogIndex < rhs.catalogIndex
    }

    /// Lower tier is a better match. Returns the strongest tier this entry achieves plus the length
    /// of the matched token (for the secondary tiebreak), or `nil` when nothing matches. Synonyms are
    /// recorded with token length 0 so an intent hit leads its tier ahead of literal prefix hits.
    private func lexicalHit(
        query: String,
        synonyms: (exact: Set<String>, prefix: Set<String>),
        indexed: EmojiCatalog.IndexedEntry
    ) -> (tier: Int, tokenLength: Int)? {
        var best: (tier: Int, tokenLength: Int)?
        func merge(_ candidate: (tier: Int, tokenLength: Int)?) {
            best = Self.betterHit(best, candidate)
        }

        for alias in indexed.lowerAliases {
            merge(Self.aliasHit(query: query, alias: alias))
            merge(Self.synonymHit(synonyms: synonyms, alias: alias))
        }
        for keyword in indexed.lowerKeywords {
            merge(Self.keywordHit(query: query, keyword: keyword))
        }
        merge(Self.nameHit(query: query, name: indexed.lowerName))

        return best
    }

    /// Keeps the stronger of two hits: lower tier wins, then the shorter matched token.
    private static func betterHit(
        _ current: (tier: Int, tokenLength: Int)?,
        _ candidate: (tier: Int, tokenLength: Int)?
    ) -> (tier: Int, tokenLength: Int)? {
        guard let candidate else { return current }
        guard let current else { return candidate }
        if candidate.tier < current.tier { return candidate }
        if candidate.tier == current.tier, candidate.tokenLength < current.tokenLength { return candidate }
        return current
    }

    private static func aliasHit(query: String, alias: String) -> (tier: Int, tokenLength: Int)? {
        if alias == query { return (Tier.exactAlias, alias.count) }
        if alias.hasPrefix(query) { return (Tier.aliasPrefix, alias.count) }
        if alias.contains(query) { return (Tier.aliasSubstring, alias.count) }
        return nil
    }

    /// Synonym hits use token length 0 so an intent match leads its tier ahead of literal prefixes.
    private static func synonymHit(
        synonyms: (exact: Set<String>, prefix: Set<String>),
        alias: String
    ) -> (tier: Int, tokenLength: Int)? {
        if synonyms.exact.contains(alias) { return (Tier.synonymExact, 0) }
        if synonyms.prefix.contains(alias) { return (Tier.synonymPrefix, 0) }
        return nil
    }

    private static func keywordHit(query: String, keyword: String) -> (tier: Int, tokenLength: Int)? {
        if keyword == query || keyword.hasPrefix(query) { return (Tier.keywordOrNamePrefix, keyword.count) }
        if keyword.contains(query) { return (Tier.keywordOrNameSubstring, keyword.count) }
        return nil
    }

    private static func nameHit(query: String, name: String) -> (tier: Int, tokenLength: Int)? {
        if name.hasPrefix(query) { return (Tier.keywordOrNamePrefix, name.count) }
        if name.contains(query) { return (Tier.keywordOrNameSubstring, name.count) }
        return nil
    }

    // MARK: - Fuzzy fallback

    /// Caps how much longer a candidate may be than the query for a subsequence match, so a short
    /// query cannot match a long unrelated word that merely contains its letters in order.
    private static let maxSubsequenceGap = 4

    private func fuzzyHit(
        queryChars: [Character],
        queryCount: Int,
        indexed: EmojiCatalog.IndexedEntry
    ) -> (tier: Int, tokenLength: Int)? {
        var bestLength: Int?
        func consider(_ candidate: String) {
            guard Self.isFuzzyMatch(queryChars: queryChars, queryCount: queryCount, candidate: candidate) else { return }
            bestLength = Swift.min(bestLength ?? Int.max, candidate.count)
        }
        for alias in indexed.lowerAliases { consider(alias) }
        consider(indexed.lowerName)

        guard let length = bestLength else { return nil }
        return (Tier.fuzzy, length)
    }

    /// A fuzzy match is a bounded edit distance (handles transpositions and single typos, e.g.
    /// "recieve" -> "receive") or a length-capped subsequence (handles dropped letters and light
    /// abbreviations, e.g. "thnk" -> "thinking").
    private static func isFuzzyMatch(queryChars: [Character], queryCount: Int, candidate: String) -> Bool {
        let candidateChars = Array(candidate)
        let bound = queryCount <= 4 ? 1 : 2
        if abs(candidateChars.count - queryCount) <= bound,
           osaDistance(queryChars, candidateChars) <= bound {
            return true
        }
        if candidateChars.count <= queryCount + maxSubsequenceGap,
           isSubsequence(queryChars, candidateChars) {
            return true
        }
        return false
    }

    /// True when every character of `needle` appears in `haystack` in order (not necessarily
    /// contiguously).
    private static func isSubsequence(_ needle: [Character], _ haystack: [Character]) -> Bool {
        guard !needle.isEmpty else { return true }
        var matched = 0
        for character in haystack where character == needle[matched] {
            matched += 1
            if matched == needle.count { return true }
        }
        // The in-loop guard returns true the instant all of `needle` is matched, so reaching here
        // means the haystack was exhausted first.
        return false
    }

    /// Optimal string alignment distance: Levenshtein plus adjacent transpositions as a single edit.
    /// Strings here are short emoji aliases, so the full matrix is cheap and easier to verify than a
    /// rolling-row variant.
    private static func osaDistance(_ source: [Character], _ target: [Character]) -> Int {
        let sourceCount = source.count
        let targetCount = target.count
        if sourceCount == 0 { return targetCount }
        if targetCount == 0 { return sourceCount }

        var distance = Array(repeating: Array(repeating: 0, count: targetCount + 1), count: sourceCount + 1)
        for row in 0...sourceCount { distance[row][0] = row }
        for column in 0...targetCount { distance[0][column] = column }

        for row in 1...sourceCount {
            for column in 1...targetCount {
                let cost = source[row - 1] == target[column - 1] ? 0 : 1
                var value = Swift.min(
                    distance[row - 1][column] + 1,
                    distance[row][column - 1] + 1,
                    distance[row - 1][column - 1] + cost
                )
                if row > 1, column > 1, source[row - 1] == target[column - 2], source[row - 2] == target[column - 1] {
                    value = Swift.min(value, distance[row - 2][column - 2] + 1)
                }
                distance[row][column] = value
            }
        }
        return distance[sourceCount][targetCount]
    }
}
