import Foundation

/// File overview:
/// Decides whether a proposed completion would mostly retype text that already follows the caret.
///
/// Why this file exists:
/// Local models frequently restart from the text just after the cursor, so a raw completion can be
/// a near-copy of what the field already contains downstream. Accepting it inserts a duplicate. The
/// previous guard in `SuggestionTextNormalizer` only checked a raw `hasPrefix`, which any stray
/// leading glyph (a markdown bullet, a quote, a space) or a case difference defeated. Comparing on a
/// folded view (lowercased, letters and digits only) catches the real-world shapes that plain
/// prefix matching misses, while staying conservative enough not to suppress legitimately short
/// completions that merely share a few characters with the suffix.
enum TrailingDuplicationFilter {
    /// Below this many folded characters we do not trust an overlap. Short coincidental matches
    /// (a shared "the", a shared two-letter stem) are common and must not trigger suppression.
    static let minimumFoldedOverlap = 3

    /// Returns true when `completion` would duplicate text that already follows the caret.
    static func duplicatesTrailingText(_ completion: String, trailingText: String) -> Bool {
        let foldedCompletion = fold(completion)
        guard foldedCompletion.count >= minimumFoldedOverlap else {
            return false
        }
        let foldedTrailing = fold(trailingText)
        guard !foldedTrailing.isEmpty else {
            return false
        }

        // Shape 1: the completion is the start of what already follows the caret.
        if foldedTrailing.hasPrefix(foldedCompletion) {
            return true
        }

        // Shape 2: the completion contains the whole upcoming suffix run, so accepting it would
        // push a second copy of that text in front of the existing one.
        if foldedCompletion.hasPrefix(foldedTrailing), foldedTrailing.count >= minimumFoldedOverlap {
            return true
        }

        // Shape 3: a long leading run of the completion already appears at the caret. Catches the
        // common "model re-emits the next few words" case where the two diverge only after a while.
        let overlap = commonPrefixLength(foldedCompletion, foldedTrailing)
        return overlap >= max(minimumFoldedOverlap, foldedCompletion.count / 2)
    }

    /// Lowercased, letters and digits only. Folding on alphanumerics is what lets a stray leading
    /// bullet or quote in the raw model output still line up against the plain field text.
    private static func fold(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    private static func commonPrefixLength(_ lhs: String, _ rhs: String) -> Int {
        var count = 0
        var lhsIndex = lhs.startIndex
        var rhsIndex = rhs.startIndex
        while lhsIndex < lhs.endIndex, rhsIndex < rhs.endIndex, lhs[lhsIndex] == rhs[rhsIndex] {
            count += 1
            lhsIndex = lhs.index(after: lhsIndex)
            rhsIndex = rhs.index(after: rhsIndex)
        }
        return count
    }
}
