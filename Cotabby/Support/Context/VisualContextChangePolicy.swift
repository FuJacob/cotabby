import Foundation

/// File overview:
/// Decides whether a refreshed screen excerpt differs from the one already in the prompt in a way
/// the model should see, or only by OCR noise and the user's own typing.
///
/// Why this exists: `VisualContextCoordinator` re-captures the screen every few seconds, and the
/// capture usually contains the very field the user is typing into. Treating every textual
/// difference as new context made each refresh replace the screen section of the prompt, which
/// discards the KV cache from that section onward (up to ~1,200 tokens to re-decode) and retires
/// the visible suggestion through `onInjectedContextReady`, so ghost text vanished every refresh
/// while the user typed. Keeping the previous excerpt when nothing material changed holds the
/// prompt byte-stable across refreshes; real changes (a new chat message, navigation, scrolling)
/// still replace it immediately.
///
/// The comparison is line based because OCR jitter is local: a misread letter changes a word or
/// two inside a line, while a genuine update adds or removes whole lines.
nonisolated enum VisualContextChangePolicy {
    /// A refreshed line counts as the same line when it shares at least this fraction of its words
    /// with some previous line. OCR misreads ("includina" for "including") stay well above it.
    static let lineMatchThreshold = 0.5
    /// A line made mostly of words the user has in the focused field is their own text rendered
    /// on screen, which the prompt already carries as the caret prefix.
    static let fieldEchoThreshold = 0.6
    /// Lines shorter than this many words (timestamps, button labels, "Edited") are too noisy to
    /// count as new content on their own.
    static let minimumLineWords = 3
    /// Content that disappears without anything new appearing (a scrolled-off line) only matters
    /// once enough of it is gone to make the old excerpt misleading.
    static let removedLinesThreshold = 3

    /// - Parameters:
    ///   - previous: The excerpt currently in the prompt, or nil when none is.
    ///   - next: The freshly captured excerpt.
    ///   - fieldText: The focused field's text around the caret, used to ignore the user's own
    ///     typing where it shows up in the capture.
    /// - Returns: true when `next` should replace `previous` in the prompt.
    static func isMaterialChange(previous: String?, next: String, fieldText: String) -> Bool {
        guard let previous else { return true }
        if previous == next { return false }

        let fieldWords = Set(words(in: fieldText))
        let previousLines = contentLines(previous, fieldWords: fieldWords)
        let nextLines = contentLines(next, fieldWords: fieldWords)

        let added = nextLines.filter { line in
            !previousLines.contains { similarity(line, $0) >= lineMatchThreshold }
        }
        if !added.isEmpty { return true }

        let removed = previousLines.filter { line in
            !nextLines.contains { similarity(line, $0) >= lineMatchThreshold }
        }
        return removed.count >= removedLinesThreshold
    }

    /// The word sets of the lines that carry screen content: long enough to mean something and
    /// not an echo of the field the user is typing in.
    private static func contentLines(_ text: String, fieldWords: Set<String>) -> [Set<String>] {
        text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let lineWords = words(in: String(rawLine))
            guard lineWords.count >= minimumLineWords else { return nil }
            let lineSet = Set(lineWords)
            if !fieldWords.isEmpty {
                let echoed = Double(lineSet.intersection(fieldWords).count) / Double(lineSet.count)
                if echoed >= fieldEchoThreshold { return nil }
            }
            return lineSet
        }
    }

    /// Jaccard similarity of two word sets.
    private static func similarity(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        let union = lhs.union(rhs).count
        guard union > 0 else { return 1 }
        return Double(lhs.intersection(rhs).count) / Double(union)
    }

    /// Lowercased letter/digit runs of two or more characters. Single characters are mostly OCR
    /// debris (bullets, stray glyphs) and would make short lines look different for no reason.
    private static func words(in text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { $0.count >= 2 }
            .map(String.init)
    }
}
