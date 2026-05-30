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

        // Thinking-capable models may emit <think>…</think> reasoning blocks. Strip complete
        // blocks first, then any trailing open tag left when generation hit the token limit.
        if let thinkRange = normalized.range(of: "<think>[\\s\\S]*?</think>", options: .regularExpression) {
            normalized.replaceSubrange(thinkRange, with: "")
        }
        if let openTag = normalized.range(of: "<think>[\\s\\S]*", options: .regularExpression) {
            normalized.replaceSubrange(openTag, with: "")
        }

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

        // Backstop for prompt-scaffolding hallucination. Small instruct models sometimes parrot the
        // prompt's section headers ("App:", "Text before caret:", "Continuation:") as the first
        // thing they emit: sometimes as their own line, sometimes inline before the real text, and
        // sometimes as labels the model invents that were never in our prompt at all. None of these
        // are valid ghost text. Stripping a leading run of known labels runs before the single-line
        // collapse so a model that stacks "Task:\nText before caret:\nreal continuation" still
        // surfaces the real continuation instead of collapsing to the first label line. This is a
        // best-effort catch, not the fix: the durable fix is feeding instruct models their own chat
        // template so instructions never read as content in the first place.
        normalized = stripLeadingScaffoldingLabels(normalized)
        normalized = normalized.trimmingCharacters(in: .newlines)

        if request.isMultiLineEnabled {
            // Multi-line mode: keep content up to the first blank-line boundary (double newline)
            // to prevent runaway paragraph generation while still allowing multi-line completions.
            if let blankLine = normalized.range(of: "\n\n") {
                normalized = String(normalized[..<blankLine.lowerBound])
            }
            normalized = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            // Single-line mode: only surface the immediate continuation line.
            if let firstLine = normalized.split(separator: "\n", maxSplits: 1).first {
                normalized = String(firstLine)
            }
        }

        // If the model starts by repeating text that already exists after the caret, we treat the
        // suggestion as unusable. Showing only the remainder often produces confusing mid-word
        // ghosts, so the coordinator should regenerate instead.
        if !request.context.trailingText.isEmpty,
            normalized.hasPrefix(request.context.trailingText) {
            return ""
        }

        // Echo suppression: strip any leading words that repeat the tail of the preceding text.
        // Small models sometimes regurgitate the prompt suffix instead of continuing from it.
        // Word-by-word suffix–prefix overlap catches "hello world " → "world is great" and
        // strips "world" so the ghost text shows only " is great".
        normalized = stripEchoPrefix(normalized, precedingText: request.context.precedingText)

        // Deterministic space management runs AFTER echo suppression because stripping echoed
        // words can expose a leading space (e.g. "world is" → " is"). If the preceding text
        // already ends with whitespace we strip the leading space to prevent double-spacing.
        // When preceding text does NOT end with whitespace, the model's leading space (or the
        // inter-word space exposed by echo suppression) passes through — it's the word boundary
        // the user needs.
        if let lastScalar = request.context.precedingText.unicodeScalars.last,
           CharacterSet.whitespaces.contains(lastScalar) {
            normalized = String(normalized.drop(while: { $0.isWhitespace }))
        }

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

        // Slice the original string at the character position where the last echoed word ends,
        // preserving the original whitespace that follows it (typically the space between words).
        let lastEchoedWord = suggestionWords[bestOverlap - 1]
        let afterLastEchoed = lastEchoedWord.endIndex
        return String(suggestion[afterLastEchoed...])
    }

    /// Section-header labels Cotabby's prompts use, plus close variants small models tend to
    /// hallucinate. Matching is anchored to this known set so legitimate user text that merely
    /// contains a colon ("Note: buy milk", "TODO: ship it") is never treated as scaffolding.
    /// Ordered longest-first at match time so "Text before the caret:" wins over "Text before".
    private static let scaffoldingLabels: [String] = [
        "Text before the caret:",
        "Text before caret:",
        "Text after the caret:",
        "Text after caret:",
        "User Profile Context:",
        "Your style preferences:",
        "Final instruction:",
        "Screen context:",
        "Screen content:",
        "User's clipboard:",
        "Continuation:",
        "Application:",
        "Task:",
        "App:"
    ]

    /// Removes a leading run of known prompt-scaffolding labels (see `scaffoldingLabels`), whether
    /// each sits on its own line or inline before the continuation. Only labels at the very start
    /// are stripped; a label appearing later in the text is left alone because by then it is far
    /// more likely to be real user content than echoed scaffolding.
    private static func stripLeadingScaffoldingLabels(_ text: String) -> String {
        let labelsByLengthDescending = scaffoldingLabels.sorted { $0.count > $1.count }
        var working = text

        while true {
            // Look past leading whitespace/newlines to find the first real token. We only commit to
            // dropping that whitespace if a label actually matches; otherwise `working` is returned
            // untouched so the caller's existing leading-space handling still sees the original.
            let leading = String(working.drop(while: { $0.isWhitespace }))
            guard let label = labelsByLengthDescending.first(where: {
                leading.range(of: $0, options: [.caseInsensitive, .anchored]) != nil
            }) else {
                return working
            }
            working = String(leading.dropFirst(label.count))
        }
    }
}
