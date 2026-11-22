import Foundation

/// Lowercases a bundled frequency dictionary's entries in its own language before indexing.
///
/// Every lookup lowercases the typed word first (`SymSpellCorrector`, `WordPrefixIndex`), and
/// `TypoCaseTransfer` puts the user's capitalization back on the result, so entries must be stored
/// lowercase too. Most bundled lists are; the Turkish one keeps its source capitalization
/// (`İstanbul`), which made those entries unreachable from a lowercased query and cost a correction
/// one of its two edits on the case alone. Normalizing at load keeps the bundled file byte-identical
/// to the reproducible build its NOTICE hashes describe. Entries that collapse into one spelling sum
/// their counts: they are the same word counted under two capitalizations.
nonisolated enum SpellingDictionaryCaseNormalizer {
    static func lowercased(_ contents: String, locale: Locale) -> String {
        // Already-lowercase lists (all but Turkish today) pass through without being rebuilt.
        guard contents.contains(where: \.isUppercase) else { return contents }

        var counts: [String: Int64] = [:]
        var order: [String] = []
        for line in contents.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count >= 2, let count = Int64(fields[1]) else { continue }
            let word = String(fields[0]).lowercased(with: locale)
            if let existing = counts[word] {
                counts[word] = existing + count
            } else {
                counts[word] = count
                order.append(word)
            }
        }
        // Most frequent first, the order the bundled lists use; ties keep their first appearance.
        let ranked = order.enumerated().sorted { lhs, rhs in
            let left = counts[lhs.element] ?? 0, right = counts[rhs.element] ?? 0
            return left != right ? left > right : lhs.offset < rhs.offset
        }
        return ranked.map { "\($0.element) \(counts[$0.element] ?? 0)" }.joined(separator: "\n")
    }
}
