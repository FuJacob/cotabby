import Foundation

/// File overview:
/// Pure relevance ranking for Settings search. The old search was a flat `contains` filter in
/// declaration order, which made common queries feel arbitrary: "ghost" listed whichever item
/// happened to be declared first, a typo found nothing, and multi-word queries only matched when
/// one field contained the whole phrase. This ranker scores every item per query token across its
/// title, keywords, owning pane, and summary, so results come back ordered by how directly they
/// answer the query.
///
/// Lives in `Support/` as a pure rule: no SwiftUI, no app state, fully unit-testable. The UI layer
/// conforms its catalog type (`SettingsItem`) to `SettingsSearchable` and calls `rank`.
///
/// Scoring model, per query token (highest applicable tier wins per field, best field wins per
/// token):
/// - Title: exact > prefix > word prefix > substring > fuzzy subsequence.
/// - Keywords: same tiers, weighted below title so synonyms help without outranking direct hits.
/// - Pane label: lets "emoji" surface the whole Emoji pane's items.
/// - Summary: catches descriptive phrasing ("too big", "on every keystroke").
/// An item matches only when every token matches somewhere; token scores then sum, with a small
/// cohesion bonus when all tokens hit the title. Ties keep declaration order so results stay stable.
enum SettingsSearchRanker {
    /// One scored item, exposed for tests and for callers that want to inspect relevance.
    struct Match<Item> {
        let item: Item
        let score: Double
    }

    /// Items matching `query`, best first. Empty for a blank query.
    static func rank<Item: SettingsSearchable>(_ query: String, in items: [Item]) -> [Item] {
        matches(query, in: items).map(\.item)
    }

    /// Scored matches for `query`, best first. Empty for a blank query.
    static func matches<Item: SettingsSearchable>(_ query: String, in items: [Item]) -> [Match<Item>] {
        let tokens = tokenize(query)
        guard !tokens.isEmpty else { return [] }

        let joinedQuery = tokens.joined(separator: " ")
        let scored: [(offset: Int, match: Match<Item>)] = items.enumerated().compactMap { offset, item in
            guard let score = score(tokens: tokens, joinedQuery: joinedQuery, item: item) else { return nil }
            return (offset, Match(item: item, score: score))
        }

        return scored
            .sorted { lhs, rhs in
                if lhs.match.score != rhs.match.score {
                    return lhs.match.score > rhs.match.score
                }
                return lhs.offset < rhs.offset
            }
            .map(\.match)
    }

    // MARK: - Scoring

    /// Tier weights for one searchable field. `nil` disables a tier for that field.
    private struct FieldWeights {
        let exact: Double
        let prefix: Double
        let wordPrefix: Double
        let substring: Double
        let subsequence: Double?
    }

    private static let titleWeights = FieldWeights(
        exact: 100, prefix: 90, wordPrefix: 80, substring: 60, subsequence: 25
    )
    private static let keywordWeights = FieldWeights(
        exact: 70, prefix: 55, wordPrefix: 50, substring: 40, subsequence: 12
    )
    private static let groupWeights = FieldWeights(
        exact: 35, prefix: 30, wordPrefix: 25, substring: 20, subsequence: nil
    )
    private static let summaryWeights = FieldWeights(
        exact: 30, prefix: 30, wordPrefix: 30, substring: 18, subsequence: nil
    )

    /// Bonus when every query token lands in the title: "ghost size" should place
    /// "Ghost Text Size" above items where the tokens are split across unrelated fields.
    private static let fullTitleCohesionBonus: Double = 15

    /// Bonus when the whole query IS the title. Per-token scoring alone can tie a short title
    /// with a longer one that contains the same words ("Accept Word" vs "Accept Punctuation With
    /// Word"); typing a row's exact name must always win.
    private static let exactTitleBonus: Double = 40

    private static func score(
        tokens: [String],
        joinedQuery: String,
        item: some SettingsSearchable
    ) -> Double? {
        let title = normalize(item.searchTitle)
        let keywords = item.searchKeywords.map(normalize)
        let group = normalize(item.searchGroupLabel)
        let summary = normalize(item.searchSummary)

        var total = 0.0
        var titleHits = 0

        for token in tokens {
            var best = 0.0
            var tokenHitTitle = false

            if let titleScore = fieldScore(token: token, target: title, weights: titleWeights) {
                best = titleScore
                tokenHitTitle = true
            }
            for keyword in keywords {
                if let keywordScore = fieldScore(token: token, target: keyword, weights: keywordWeights),
                   keywordScore > best {
                    best = keywordScore
                    tokenHitTitle = false
                }
            }
            if let groupScore = fieldScore(token: token, target: group, weights: groupWeights),
               groupScore > best {
                best = groupScore
                tokenHitTitle = false
            }
            if let summaryScore = fieldScore(token: token, target: summary, weights: summaryWeights),
               summaryScore > best {
                best = summaryScore
                tokenHitTitle = false
            }

            guard best > 0 else { return nil }
            total += best
            if tokenHitTitle { titleHits += 1 }
        }

        if titleHits == tokens.count {
            total += fullTitleCohesionBonus
        }
        if title == joinedQuery {
            total += exactTitleBonus
        }
        return total
    }

    private static func fieldScore(token: String, target: String, weights: FieldWeights) -> Double? {
        guard !target.isEmpty else { return nil }
        if target == token { return weights.exact }
        if target.hasPrefix(token) { return weights.prefix }
        // Reverse prefix: the user typed past the target ("languages" vs the keyword "language",
        // "screenshots" vs "screenshot"). Both sides must be substantial so a long token does not
        // match every tiny word it happens to start with.
        if token.count >= 4, target.count >= 4, token.hasPrefix(target) { return weights.prefix }
        if words(in: target).contains(where: { word in
            word.hasPrefix(token) || (token.count >= 4 && word.count >= 4 && token.hasPrefix(word))
        }) {
            return weights.wordPrefix
        }
        if target.contains(token) { return weights.substring }
        // Subsequence matching is the typo net ("batery" -> "battery"). Short tokens are skipped:
        // two letters are a subsequence of almost everything and would flood results with noise.
        if let subsequenceWeight = weights.subsequence,
           token.count >= 3,
           isSubsequence(token, of: target) {
            return subsequenceWeight
        }
        return nil
    }

    // MARK: - Text helpers

    /// Lowercased, diacritic-folded comparison form so "café" and "cafe" meet in the middle.
    private static func normalize(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }

    private static func words(in text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Query tokens: normalized words, capped so a pathological paste cannot turn scoring into
    /// quadratic work across the catalog.
    private static func tokenize(_ query: String) -> [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .prefix(8)
            .map { normalize(String($0)) }
            .filter { !$0.isEmpty }
    }

    /// Two-pointer subsequence test: every character of `token` appears in `target` in order.
    private static func isSubsequence(_ token: String, of target: String) -> Bool {
        var tokenIndex = token.startIndex
        for character in target {
            guard tokenIndex < token.endIndex else { return true }
            if token[tokenIndex] == character {
                tokenIndex = token.index(after: tokenIndex)
            }
        }
        return tokenIndex == token.endIndex
    }
}

/// What the ranker needs to know about one searchable setting. Kept as a protocol so the pure
/// ranker never imports the UI catalog type that conforms to it.
protocol SettingsSearchable {
    /// The row's visible title ("Ghost Text Size").
    var searchTitle: String { get }
    /// Synonyms and adjacent vocabulary a user might type instead of the title.
    var searchKeywords: [String] { get }
    /// The owning pane's label ("Appearance"), so pane-name queries surface its items.
    var searchGroupLabel: String { get }
    /// The one-line caption shown under the row, searched for descriptive phrasing.
    var searchSummary: String { get }
}
