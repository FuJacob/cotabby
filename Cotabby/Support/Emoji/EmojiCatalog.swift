import Foundation
import Logging

/// File overview:
/// Loads and indexes the bundled emoji dataset once, exposing a precomputed, lowercased search
/// index for `EmojiMatcher`. Keeping the lowercasing here (instead of inside the per-keystroke
/// matcher) means query-time work stays proportional to the number of records, not the size of
/// each record's text.
///
/// The core initializer is pure (an array of entries in, an index out) so tests can build a small
/// catalog inline. `bundled(in:)` is the only impure entry point and degrades to an empty catalog
/// rather than crashing if the resource is missing.
///
/// `Resources/Emoji/emoji.json` is generated from GitHub's gemoji dataset (MIT licensed). To refresh
/// it, transform the upstream `db/emoji.json` into this file's `{glyph,name,aliases,keywords,group,
/// unicodeVersion}` shape.
nonisolated struct EmojiCatalog {
    /// An entry paired with its lowercased searchable tokens, computed once at load time.
    struct IndexedEntry: Equatable {
        let entry: EmojiEntry
        let lowerAliases: [String]
        let lowerKeywords: [String]
        let lowerName: String
    }

    let indexed: [IndexedEntry]

    /// Lowercased alias -> first catalog index, so a stored alias (recents, popularity prior) resolves
    /// back to its entry in O(1). First occurrence wins on the rare alias collision.
    let aliasIndex: [String: Int]

    var isEmpty: Bool { indexed.isEmpty }
    var count: Int { indexed.count }

    init(entries: [EmojiEntry]) {
        let indexed = entries.map { entry in
            IndexedEntry(
                entry: entry,
                lowerAliases: entry.aliases.map { $0.lowercased() },
                lowerKeywords: entry.keywords.map { $0.lowercased() },
                lowerName: entry.name.lowercased()
            )
        }
        var aliasIndex: [String: Int] = [:]
        for (index, entry) in indexed.enumerated() {
            for alias in entry.lowerAliases where aliasIndex[alias] == nil {
                aliasIndex[alias] = index
            }
        }
        self.indexed = indexed
        self.aliasIndex = aliasIndex
    }

    /// The entry whose (lowercased) alias matches, or nil. Resolves recent/popular aliases back to
    /// displayable entries for the bare-`:` panel.
    func entry(forAlias alias: String) -> EmojiEntry? {
        guard let index = aliasIndex[alias.lowercased()] else { return nil }
        return indexed[index].entry
    }
}

extension EmojiCatalog {
    /// Decodes the dataset bundled with the app. Returns an empty catalog (and logs) on any failure
    /// so a packaging mistake disables the picker gracefully instead of taking down the app.
    static func bundled(in bundle: Bundle = .main) -> EmojiCatalog {
        guard let url = resourceURL(in: bundle) else {
            CotabbyLogger.app.error("Emoji catalog resource emoji.json not found in bundle")
            return EmojiCatalog(entries: [])
        }
        do {
            let data = try Data(contentsOf: url)
            let entries = try JSONDecoder().decode([EmojiEntry].self, from: data)
            CotabbyLogger.app.info("Emoji catalog loaded \(entries.count) entries")
            return EmojiCatalog(entries: entries)
        } catch {
            CotabbyLogger.app.error("Emoji catalog failed to decode: \(error.localizedDescription)")
            return EmojiCatalog(entries: [])
        }
    }

    /// Xcode may flatten the resource into `Resources/` or preserve the `Emoji/` subfolder depending
    /// on how the file is added, so we probe the likely locations before giving up.
    private static func resourceURL(in bundle: Bundle) -> URL? {
        bundle.url(forResource: "emoji", withExtension: "json")
            ?? bundle.url(forResource: "emoji", withExtension: "json", subdirectory: "Emoji")
            ?? bundle.url(forResource: "emoji", withExtension: "json", subdirectory: "Resources/Emoji")
    }
}
