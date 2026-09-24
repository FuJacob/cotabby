import Foundation

/// File overview:
/// Content rules for a normalized completion that no font, geometry, or model setting can fix:
/// shapes the eval showed are wrong essentially every time they appear.
///
/// - No word content ("," ":" "." "…"): the model wanted to attach punctuation to the previous
///   word or end a sentence the user is still writing. Six eval cases, all wrong.
/// - Closing punctuation right after the user typed a space ("Best " → ", regards"): accepting
///   would produce "Best ," and the rest is guesswork.
/// - Scaffolding: forum/chat UI residue ("[User 0001]", "12:03 PM · 1 min read · Reply"), stray
///   HTML in prose, and the model talking back about the prompt ("I'm not sure what you mean by…").
/// - Repetition: a short word sequence looping back to back (". Hi S. Hi S. Hi S.") is the model
///   stuck, not a continuation. Measured live on a small base model mid-word: it happens on short
///   partial words with thin context.
/// - Copying: the completion restarts the words the user just wrote (". Hi Sarah, thanks for s"
///   right after "Hi Sarah, thanks for s"). Only the tail before the caret counts: a document that
///   repeats a paragraph elsewhere makes reproducing it the right prediction (measured live in a
///   note holding the same paragraph twice, a whole-window rule threw away 168 of 179 completions).
enum CompletionContentPolicy {
    enum Rejection: Equatable {
        case noWordContent
        case punctuationAfterSpace
        case scaffolding
        case repetitiveContent
        case copiesPrecedingText
    }

    /// Words of the text before the caret a completion must repeat to count as copying; shorter
    /// overlaps are ordinary phrasing.
    static let copiedRunWords = 4
    /// Characters before the caret the copied run is taken from.
    static let copySearchWindow = 120

    /// Punctuation that closes or continues the previous word and never starts a new one.
    private static let closingPunctuation: Set<Character> = [",", ".", ";", ":", "!", "?", "…"]

    private static let metaPhrases: [String] = [
        "i'm not sure what you mean",
        "i am not sure what you mean",
        "as an ai",
        "as a language model",
        "i cannot help",
        "i can't help",
        "i don't understand the question"
    ]

    static func rejection(for completion: String, precedingText: String) -> Rejection? {
        if !hasWordContent(completion) {
            return .noWordContent
        }
        if startsWithClosingPunctuationAfterSpace(completion, precedingText: precedingText) {
            return .punctuationAfterSpace
        }
        if looksLikeScaffolding(completion, precedingText: precedingText) {
            return .scaffolding
        }
        if isRepetitive(completion) {
            return .repetitiveContent
        }
        if copiesPrecedingText(completion, precedingText: precedingText) {
            return .copiesPrecedingText
        }
        return nil
    }

    /// True when a sequence of one to three words repeats itself three or more times in a row.
    static func isRepetitive(_ completion: String) -> Bool {
        let words = completion.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
        for period in 1...3 where words.count >= period * 3 {
            var run = 0
            for index in period..<words.count {
                run = words[index] == words[index - period] ? run + 1 : 0
                if run >= period * 2 {
                    return true
                }
            }
        }
        return false
    }

    /// True when the completion contains the last `copiedRunWords` words before the caret in
    /// order: the model went back and repeated what was just written instead of continuing it.
    /// Punctuation and case are ignored so "s." matches "s"; four words are enough that ordinary
    /// shared phrasing ("thanks for the") never trips it.
    static func copiesPrecedingText(_ completion: String, precedingText: String) -> Bool {
        let words = contentWords(completion)
        let recent = contentWords(String(precedingText.suffix(copySearchWindow)))
        let run = copiedRunWords
        guard words.count >= run, recent.count >= run else { return false }
        let tail = recent.suffix(run).joined(separator: " ")
        for start in 0...(words.count - run) where words[start..<start + run].joined(separator: " ") == tail {
            return true
        }
        return false
    }

    private static func contentWords(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" })
            .map(String.init)
    }

    static func hasWordContent(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }

    static func startsWithClosingPunctuationAfterSpace(_ completion: String, precedingText: String) -> Bool {
        guard let last = precedingText.last, last == " " || last == "\t" else { return false }
        guard let first = completion.first else { return false }
        return closingPunctuation.contains(first)
    }

    static func looksLikeScaffolding(_ completion: String, precedingText: String) -> Bool {
        let trimmed = completion.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        // "[User 0001]", "[quote]", "[/b]" and similar bracketed markers opening the completion.
        if trimmed.range(of: #"^\[/?[A-Za-z][A-Za-z0-9 _-]{0,24}\]"#, options: .regularExpression) != nil {
            return true
        }
        // Social/forum UI chrome: several " · " separators in one line.
        if trimmed.components(separatedBy: " · ").count >= 3 {
            return true
        }
        // HTML tags in a field whose own text carries none.
        if trimmed.range(of: #"</?[a-zA-Z][a-zA-Z0-9]*(\s[^<>]*)?>"#, options: .regularExpression) != nil,
           !precedingText.contains("<") {
            return true
        }
        return metaPhrases.contains { lowered.hasPrefix($0) || lowered.contains(" \($0)") }
    }
}
