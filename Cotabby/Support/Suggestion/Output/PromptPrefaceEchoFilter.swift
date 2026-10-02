import Foundation

/// File overview:
/// Cuts a completion where it starts writing out Cotabby's own prompt preface.
///
/// The Open Source models are base models: they continue text, and the prompt they continue opens
/// with a preface of conditioning lines (`BaseCompletionPromptRenderer`). When the text before the
/// caret ends where an earlier preface line could follow (an empty chat composer, a finished line),
/// the model sometimes writes one out, and it reached the ghost as a second line: "4 5.6 Sol" then
/// "The user usually writes in". `SuggestionTextNormalizer` already strips scaffolding *labels* at
/// the very start of a completion; this catches preface sentences anywhere in it, keeping only what
/// came before.
///
/// Kept as its own pure type so the phrase list has one owner and a test can hold it to the
/// renderer's actual wording.
nonisolated enum PromptPrefaceEchoFilter {
    /// Preface wording distinctive enough to cut wherever it appears in a completion: no user's
    /// next words plausibly contain these exact phrases.
    static let anywherePhrases = [
        "The user usually writes in",
        "Match the language of the text before the caret",
        "Notes the writer keeps in mind:",
        "Nearby on screen:",
        "On the clipboard:",
        "Later in the same passage:"
    ]

    /// Preface openers that ordinary prose can contain mid-sentence ("a book written by her"), so
    /// they only count at the start of a line, the way the preface writes them.
    static let lineStartPhrases = [
        "Writing style:",
        "Written by "
    ]

    /// `text` up to the first preface echo, with trailing whitespace trimmed. Unchanged when there
    /// is none; empty when the completion is nothing but an echo.
    static func truncated(_ text: String) -> String {
        var cut = text.endIndex
        for phrase in anywherePhrases {
            if let range = text.range(of: phrase), range.lowerBound < cut {
                cut = range.lowerBound
            }
        }
        var lineStart = text.startIndex
        while lineStart < cut {
            let line = text[lineStart...]
            let trimmedStart = line.firstIndex { !$0.isWhitespace || $0.isNewline } ?? line.endIndex
            if lineStartPhrases.contains(where: { text[trimmedStart...].hasPrefix($0) }) {
                cut = min(cut, lineStart)
                break
            }
            guard let newline = line.firstIndex(of: "\n") else { break }
            lineStart = text.index(after: newline)
        }
        guard cut < text.endIndex else { return text }
        var kept = String(text[..<cut])
        while let last = kept.last, last.isWhitespace {
            kept.removeLast()
        }
        return kept
    }
}
