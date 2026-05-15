import Foundation

/// File overview:
/// Centralizes the last-mile cleanup that turns raw model output into inline ghost text.
/// Both llama.cpp and Apple's Foundation Models backend feed through this helper so prompt
/// formatting quirks stay in one place instead of drifting across runtime implementations.
///
/// This type is intentionally pure. Given the same request and raw output, it always returns the
/// same normalized suggestion. That makes it safe to share across backends and easy to test later.
enum SuggestionTextNormalizer {
    static func normalize(
        _ rawSuggestion: String,
        for request: SuggestionRequest,
        promptEchoCandidates: [String] = []
    ) -> String {
        var normalized = rawSuggestion.replacingOccurrences(of: "\r", with: "")

        // Some runtimes echo the prompt or include chat-template control markers in the response.
        // Removing them here keeps the UI layer independent from backend-specific formatting.
        normalized = normalized.replacingOccurrences(of: "<|im_end|>", with: "")
        normalized = normalized.replacingOccurrences(of: "<|im_start|>", with: "")

        for prompt in [request.prompt] + promptEchoCandidates {
            if !prompt.isEmpty, normalized.hasPrefix(prompt) {
                normalized.removeFirst(prompt.count)
                normalized = normalized.trimmingCharacters(in: .controlCharacters.union(.newlines))
            }
        }

        // Apple Intelligence uses a separate instructions channel and a short task prompt, so the
        // model may echo only the visible prefix text instead of the full prompt payload.
        if !request.prefixText.isEmpty, normalized.hasPrefix(request.prefixText) {
            normalized.removeFirst(request.prefixText.count)
        }

        normalized = normalized.trimmingCharacters(in: .controlCharacters.union(.newlines))

        // Small instruction-tuned models often emit one or more leading newlines before the actual
        // continuation text. We trim those formatting-only tokens first so a response like
        // "\ndelicious" does not get misread as "the first line is empty".
        //
        // We intentionally do this before collapsing to a single line. Otherwise the old logic
        // would split on the first newline, keep the empty prefix before it, and drop the real
        // continuation that followed.
        normalized = normalized.trimmingCharacters(in: .newlines)

        // Inline autocomplete should only surface the immediate continuation, not a paragraph.
        if let firstLine = normalized.split(separator: "\n", maxSplits: 1).first {
            normalized = String(firstLine)
        }

        // If the model starts by repeating text that already exists after the caret, we treat the
        // suggestion as unusable. Showing only the remainder often produces confusing mid-word
        // ghosts, so the coordinator should regenerate instead.
        if !request.context.trailingText.isEmpty,
            normalized.hasPrefix(request.context.trailingText) {
            return ""
        }

        // Deterministic space management: the user owns the word boundary, not the model.
        // If the preceding text already ends with whitespace, strip any leading whitespace
        // the model added to prevent double-spacing. If it doesn't, the model's leading
        // space (or lack of one) passes through untouched — it's either a correct mid-word
        // completion or a natural word break the model chose.
        if let lastScalar = request.context.precedingText.unicodeScalars.last,
           CharacterSet.whitespaces.contains(lastScalar) {
            normalized = String(normalized.drop(while: { $0.isWhitespace }))
        }

        // Echo suppression: strip any leading words that repeat the tail of the preceding text.
        // Small models sometimes regurgitate the prompt suffix instead of continuing from it.
        // Word-by-word suffix–prefix overlap catches "hello world " → "world is great" and
        // strips "world" so the ghost text shows only "is great".
        normalized = stripEchoPrefix(normalized, precedingText: request.context.precedingText)

        return normalized
    }

    /// Finds the longest suffix of `precedingText` (at any word offset) that matches a prefix
    /// of `suggestion`, then strips that overlap. Returns empty if the entire suggestion is echoed.
    ///
    /// The previous version only checked one alignment (last-N vs first-N). This version tries
    /// every starting offset in the preceding tail, so "hi i like" + "i like to eat" correctly
    /// finds the 2-word overlap "i like" starting at offset -2.
    private static func stripEchoPrefix(_ suggestion: String, precedingText: String) -> String {
        let suggestionWords = suggestion.split(whereSeparator: { $0.isWhitespace })
        guard !suggestionWords.isEmpty else { return suggestion }

        let precedingWords = precedingText.split(whereSeparator: { $0.isWhitespace })
        guard !precedingWords.isEmpty else { return suggestion }

        // Cap the search window — if the model echoes 15+ words something is deeply wrong
        // and the whole suggestion should be dropped by the empty-result guard anyway.
        let maxSearchDepth = min(precedingWords.count, 15)

        // Try every starting offset in the preceding tail. For each offset, check if the
        // words from that position to the end of preceding text match the start of the
        // suggestion. Track the longest overlap found.
        var bestOverlap = 0
        for startOffset in 1...maxSearchDepth {
            let tailSlice = precedingWords.suffix(startOffset)
            let headSlice = suggestionWords.prefix(startOffset)

            // Tail is longer than suggestion — can't fully match at this offset
            guard tailSlice.count == headSlice.count else { continue }

            let matches = zip(tailSlice, headSlice).allSatisfy {
                $0.0.caseInsensitiveCompare(String($0.1)) == .orderedSame
            }

            if matches {
                bestOverlap = startOffset
            }
        }

        guard bestOverlap > 0 else { return suggestion }

        if bestOverlap >= suggestionWords.count {
            return ""
        }

        return suggestionWords.dropFirst(bestOverlap).joined(separator: " ")
    }
}
