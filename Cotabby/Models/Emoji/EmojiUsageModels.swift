import Foundation

/// File overview:
/// The pure value type the emoji ranker reads to personalize results. It is a snapshot: the matcher
/// and recents helper take it by value so they stay pure and testable, while `EmojiUsageStore` owns
/// the mutable, persisted state and hands out fresh snapshots.
///
/// Usage is keyed by an emoji's primary alias (e.g. `joy`), not its glyph, so a concept's signal is
/// stable across skin-tone and gender variants: using 👍🏽 still boosts the 👍 concept, and recents
/// render in the user's current variant preference at display time.
nonisolated struct EmojiUsageSnapshot: Equatable, Sendable {
    /// Primary aliases of recently committed emoji, most recent first, de-duplicated.
    let recentAliases: [String]
    /// Primary alias -> number of times committed.
    let frequency: [String: Int]

    static let empty = EmojiUsageSnapshot(recentAliases: [], frequency: [:])

    /// Commits before frequency alone marks an alias a favorite. Recency marks it regardless, so a
    /// just-used emoji floats up immediately even on first use.
    static let frequentThreshold = 2

    /// Whether an alias is a personal favorite. Favorites float to the front of their relevance tier
    /// in the matcher, so your go-to emoji lead among equally-relevant options without ever jumping
    /// ahead of a more relevant match in a stronger tier.
    func isFavorite(_ alias: String) -> Bool {
        let key = alias.lowercased()
        if frequency[key, default: 0] >= Self.frequentThreshold { return true }
        return recentAliases.contains(key)
    }
}
