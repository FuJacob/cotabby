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
enum CompletionContentPolicy {
    enum Rejection: Equatable {
        case noWordContent
        case punctuationAfterSpace
        case scaffolding
    }

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
        return nil
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
