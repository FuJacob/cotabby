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

        normalized = stripCurrentTokenPrefixOverlap(
            normalized,
            precedingText: request.context.precedingText
        )

        normalized = repairedWordBoundaryIfNeeded(
            normalized,
            precedingText: request.context.precedingText
        )

        guard !isLikelyUIMetadataLeak(normalized) else {
            return ""
        }

        guard !isLikelyOCRCorruption(normalized) else {
            return ""
        }

        guard !isLikelyAuxiliaryContextCopy(normalized, for: request) else {
            return ""
        }

        guard !isLikelyAnswerInsteadOfContinuation(normalized, for: request) else {
            return ""
        }

        guard !isAssistantMetaResponse(normalized) else {
            return ""
        }

        guard !containsLongRepeatedPhraseFromDraft(normalized, precedingText: request.context.precedingText) else {
            return ""
        }

        guard !isShortPhraseCopiedFromDraft(normalized, precedingText: request.context.precedingText) else {
            return ""
        }

        guard !isLowValueGenericContinuation(normalized, for: request) else {
            return ""
        }

        return normalized
    }

    /// Rejects short filler completions that are grammatically plausible but context-poor.
    ///
    /// The model can always finish "what should I" with "be doing" or "do next"; showing that in the
    /// overlay is worse than showing nothing because it teaches the user the app is guessing. This
    /// gate is deliberately narrow: it only catches tiny, common autocomplete clichés after the model
    /// has already produced them.
    private static func isLowValueGenericContinuation(
        _ suggestion: String,
        for request: SuggestionRequest
    ) -> Bool {
        let compact = suggestion
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".?!,;: "))

        guard !compact.isEmpty else {
            return false
        }

        let hardBlockedPhrases: Set<String> = [
            "be doing",
            "be doing next",
            "do next",
            "write next",
            "say next",
            "type next",
            "be writing",
            "be saying",
            "be typing"
        ]
        if hardBlockedPhrases.contains(compact) {
            return true
        }

        let words = compact.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count <= 4 else {
            return false
        }

        let genericWords: Set<String> = [
            "be", "do", "doing", "next", "now", "here", "there",
            "this", "that", "thing", "something", "anything", "write",
            "say", "type", "continue", "more", "better"
        ]

        let hasOnlyGenericWords = words.allSatisfy { genericWords.contains($0) }
        guard hasOnlyGenericWords else {
            return false
        }

        return lacksConcreteAuxiliaryContext(request)
    }

    /// Rejects short suggestions that look copied from surrounding app chrome rather than generated
    /// from the user's draft. This catches chat timestamps like "23h" and "(23 hrs)" even if the model
    /// ignored the prompt instruction to treat visible text as reference material.
    private static func isLikelyUIMetadataLeak(_ suggestion: String) -> Bool {
        let compact = suggestion
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        guard !compact.isEmpty else {
            return false
        }

        if PromptContextSanitizer.isStandaloneUIMetadata(compact) {
            return true
        }

        let words = compact.split { !$0.isLetter && !$0.isNumber }
        guard words.count <= 4 else {
            return false
        }

        let relativeTimePattern =
            #"(?i)^\(?\d{1,3}\s*(s|sec|secs|second|seconds|m|min|mins|minute|minutes|h|hr|hrs|hour|hours|d|day|days|w|wk|wks|week|weeks|mo|mos|month|months|y|yr|yrs|year|years)\)?$"#

        return compact.range(
            of: relativeTimePattern,
            options: .regularExpression
        ) != nil
    }

    /// Drops visible OCR mistakes before they reach the overlay.
    ///
    /// The goal is deliberately narrower than "reject any token containing both letters and digits".
    /// Real writing often includes mixed alphanumeric terms such as `M1`, `HTML5`, `OAuth2`, `3D`,
    /// or `1st`. What we want to catch here are longer, lowercase, word-like fragments where a digit
    /// appears to have replaced a letter, especially when several such fragments show up in one
    /// suggestion copied from noisy OCR.
    private static func isLikelyOCRCorruption(_ suggestion: String) -> Bool {
        let words = suggestion
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)

        let suspiciousWordCount = words.reduce(into: 0) { count, word in
            if isLikelyOCRCorruptedWord(word) {
                count += 1
            }
        }
        return suspiciousWordCount >= 2
    }

    private static func isLikelyOCRCorruptedWord(_ word: String) -> Bool {
        let scalarView = word.unicodeScalars
        let letterCount = scalarView.count(where: { CharacterSet.letters.contains($0) })
        let digitCount = scalarView.count(where: { CharacterSet.decimalDigits.contains($0) })
        guard letterCount >= 4, digitCount == 1 else {
            return false
        }

        let lowercased = word.lowercased()
        guard lowercased == word else {
            return false
        }

        // Keep common mixed tokens that are usually genuine model numbers, standards, versions, or
        // ordinals rather than OCR damage.
        let safePatterns = [
            #"^\d+(st|nd|rd|th)$"#,
            #"^[a-z]{1,6}\d{1,3}$"#,
            #"^\d{1,2}[a-z]{1,3}$"#,
            #"^[a-z]{1,3}\d[a-z]{1,3}$"#
        ]
        if safePatterns.contains(where: { pattern in
            lowercased.range(of: pattern, options: .regularExpression) != nil
        }) {
            return false
        }

        return lowercased.range(
            of: #"^(?:\d[a-z]{4,}|[a-z]{2,}\d[a-z]{2,}|[a-z]{6,}\d)$"#,
            options: .regularExpression
        ) != nil
    }

    /// Prevents the model from turning screen/field context into the continuation itself.
    ///
    /// We still want context to contribute names and topics. What we do not want is a long copied
    /// fragment from the chat/document above the input, especially when OCR has already distorted it.
    /// The threshold deliberately starts at five words so short useful completions like "the timeline"
    /// can still reuse concrete context words.
    private static func isLikelyAuxiliaryContextCopy(
        _ suggestion: String,
        for request: SuggestionRequest
    ) -> Bool {
        let suggestionTokens = comparableContextTokens(from: suggestion)
        guard suggestionTokens.count >= 5 else {
            return false
        }

        let auxiliaryText = [
            request.fieldContextText,
            request.visualContextSummary,
            request.clipboardContext
        ]
            .compactMap { $0 }
            .joined(separator: "\n")

        let auxiliaryTokens = Set(comparableContextTokens(from: auxiliaryText))
        guard !auxiliaryTokens.isEmpty else {
            return false
        }

        let overlapCount = suggestionTokens.filter { auxiliaryTokens.contains($0) }.count
        let longOverlapCount = suggestionTokens.filter {
            $0.count >= 4 && auxiliaryTokens.contains($0)
        }.count
        let overlapRatio = Double(overlapCount) / Double(suggestionTokens.count)

        return overlapRatio >= 0.65 && longOverlapCount >= 3
    }

    /// Rejects completions where the model answers text the user is composing instead of continuing it.
    /// This is common with question-shaped drafts such as "do you think..." where small instruct
    /// models return "sure, I think..." as if they were the recipient.
    private static func isLikelyAnswerInsteadOfContinuation(
        _ suggestion: String,
        for request: SuggestionRequest
    ) -> Bool {
        let draft = recentSentenceFragment(
            in: request.context.precedingText
        )
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let response = suggestion
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        guard !draft.isEmpty, !response.isEmpty else {
            return false
        }

        let questionStems = [
            "do you", "does this", "did you", "can you", "could you", "would you",
            "should we", "should i", "what", "why", "how", "when", "where",
            "is it", "are we", "will we", "will it"
        ]
        let looksQuestionLike = questionStems.contains { draft.hasPrefix($0) }
            || draft.contains("?")
        guard looksQuestionLike else {
            return false
        }

        let answerPrefixes = [
            "sure", "yes", "yeah", "yep", "no", "nope", "i think", "i don't think",
            "probably", "maybe", "it should", "we should", "we will", "you should"
        ]
        return answerPrefixes.contains { prefix in
            response == prefix
                || response.hasPrefix("\(prefix),")
                || response.hasPrefix("\(prefix) ")
        }
    }

    /// Narrows question/answer detection to the sentence nearest the caret.
    ///
    /// Inline completion runs against the full text before the caret, but the "model answered the
    /// user instead of continuing" heuristic should only inspect the current sentence or line. An
    /// earlier `?` elsewhere in the field should not suppress natural continuations near the caret.
    private static func recentSentenceFragment(in draft: String) -> String {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }

        let boundaryCharacters: Set<Character> = [".", "?", "!", "\n"]
        let searchable: Substring

        // A terminal `?` still belongs to the current sentence, so search for an earlier boundary
        // instead of treating the trailing punctuation as "start a new sentence after this."
        if let lastCharacter = trimmed.last,
           boundaryCharacters.contains(lastCharacter) {
            searchable = trimmed[..<trimmed.index(before: trimmed.endIndex)]
        } else {
            searchable = trimmed[...]
        }

        guard let boundaryIndex = searchable.lastIndex(where: { boundaryCharacters.contains($0) }) else {
            return trimmed
        }

        let fragment = trimmed[trimmed.index(after: boundaryIndex)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return fragment.isEmpty ? trimmed : String(fragment)
    }

    /// Rejects chat-assistant boilerplate that should never appear in inline autocomplete.
    ///
    /// Tabby is not asking the model to be an assistant in a conversation; it is asking for raw text
    /// that can be inserted into the user's focused field. Phrases like "as an LLM" or "I can't"
    /// mean the model broke role, so the safest UI behavior is to show no suggestion.
    private static func isAssistantMetaResponse(_ suggestion: String) -> Bool {
        let compact = suggestion
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

        guard !compact.isEmpty else {
            return false
        }

        let blockedPrefixes = [
            "i'm sorry",
            "i am sorry",
            "sorry, but",
            "as an ai",
            "as a language model",
            "as an llm",
            "i can't",
            "i cannot",
            "i'm unable",
            "i am unable"
        ]
        if blockedPrefixes.contains(where: { compact.hasPrefix($0) }) {
            return true
        }

        let blockedFragments = [
            "as an ai",
            "as a language model",
            "as an llm",
            "created by openai",
            "created by an ai",
            "i don't have access",
            "i do not have access",
            "i can't assist",
            "i cannot assist"
        ]
        return blockedFragments.contains { compact.contains($0) }
    }

    /// Catches model output that is not a prefix echo but still reuses a long interior phrase from the
    /// draft. In the UI this reads like the suggestion is talking back to the user or looping over the
    /// sentence already typed.
    private static func containsLongRepeatedPhraseFromDraft(
        _ suggestion: String,
        precedingText: String
    ) -> Bool {
        let suggestionTokens = draftCopyTokens(from: suggestion)
        let precedingTokens = draftCopyTokens(from: precedingText)
        guard suggestionTokens.count >= 5, precedingTokens.count >= 5 else {
            return false
        }

        let minimumOverlap = 4
        var precedingPhrases = Set<String>()
        for length in minimumOverlap...min(precedingTokens.count, 8) {
            guard precedingTokens.count >= length else { continue }
            for start in 0...(precedingTokens.count - length) {
                precedingPhrases.insert(precedingTokens[start..<(start + length)].joined(separator: " "))
            }
        }

        for length in minimumOverlap...min(suggestionTokens.count, 8) {
            guard suggestionTokens.count >= length else { continue }
            for start in 0...(suggestionTokens.count - length) {
                let phrase = suggestionTokens[start..<(start + length)].joined(separator: " ")
                if precedingPhrases.contains(phrase) {
                    return true
                }
            }
        }

        return false
    }

    /// Blocks short copied phrases that are too small for the long-overlap detector.
    ///
    /// Autocomplete may reuse one concrete word from the draft, but a whole two- or three-word
    /// phrase from earlier in the same field usually reads as a loop. The user is already past that
    /// phrase; showing it again after the caret is worse than showing no suggestion.
    private static func isShortPhraseCopiedFromDraft(
        _ suggestion: String,
        precedingText: String
    ) -> Bool {
        let suggestionTokens = draftCopyTokens(from: suggestion)
        guard (2...4).contains(suggestionTokens.count) else {
            return false
        }

        let precedingTokens = draftCopyTokens(from: precedingText)
        guard precedingTokens.count > suggestionTokens.count else {
            return false
        }

        for start in 0...(precedingTokens.count - suggestionTokens.count) {
            let candidate = Array(precedingTokens[start..<(start + suggestionTokens.count)])
            if candidate == suggestionTokens {
                return true
            }
        }

        return false
    }

    /// Fixes a narrow but common model formatting error: after a lowercase word, some small models
    /// return a title-cased next word without the required leading space. We repair that exact shape
    /// so "this" + "Text Okay" displays as "this Text Okay" instead of "thisText Okay".
    private static func repairedWordBoundaryIfNeeded(
        _ suggestion: String,
        precedingText: String
    ) -> String {
        guard let firstSuggestionScalar = suggestion.unicodeScalars.first,
              let lastPrecedingScalar = precedingText.unicodeScalars.last,
              CharacterSet.uppercaseLetters.contains(firstSuggestionScalar),
              CharacterSet.lowercaseLetters.contains(lastPrecedingScalar)
        else {
            return suggestion
        }

        return " \(suggestion)"
    }

    private static func trailingToken(in text: String) -> String {
        guard let range = text.range(
            of: #"[A-Za-z0-9_]+$"#,
            options: .regularExpression
        ) else {
            return ""
        }

        return String(text[range])
    }

    private static func comparableContextTokens(from text: String) -> [String] {
        let normalized = text
            .lowercased()
            .replacingOccurrences(of: "5", with: "s")
            .replacingOccurrences(of: "0", with: "o")
            .replacingOccurrences(of: "1", with: "i")

        return tokenizedLowercaseWordsAndNumbers(from: normalized)
    }

    /// Tokenizes text that came from the focused field itself.
    ///
    /// The draft is not OCR-sourced, so numeric tokens must stay numeric. Rewriting `15` to `is`
    /// is useful when matching OCR-corrupted auxiliary context, but it creates false draft-copy
    /// matches for legitimate continuations like "is things" after "we have 15 things...".
    private static func draftCopyTokens(from text: String) -> [String] {
        tokenizedLowercaseWordsAndNumbers(from: text.lowercased())
    }

    private static func tokenizedLowercaseWordsAndNumbers(from text: String) -> [String] {
        return text
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func lacksConcreteAuxiliaryContext(_ request: SuggestionRequest) -> Bool {
        let auxiliaryContext = [
            request.fieldContextText,
            request.visualContextSummary,
            request.clipboardContext,
            request.suffixText
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .joined(separator: "\n")

        guard !auxiliaryContext.isEmpty else {
            return true
        }

        let contentWords = auxiliaryContext
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .filter { $0.count >= 4 }

        return contentWords.count < 3
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

        let remainder = suggestionWords.dropFirst(bestOverlap).joined(separator: " ")
        if needsInsertedWordBoundary(
            before: remainder,
            after: precedingText
        ) {
            return " \(remainder)"
        }

        return remainder
    }

    /// Converts whole-word model output into the missing mid-word tail.
    ///
    /// Local models often return the completed word even when the user has already typed its prefix:
    /// `minu` -> `minutes?`. Inline autocomplete inserts exactly what the overlay shows, so keeping
    /// the whole word would produce `minuminutes?`. Stripping the current token overlap makes the
    /// displayed ghost text behave like system autocomplete: only `tes?` is offered.
    private static func stripCurrentTokenPrefixOverlap(
        _ suggestion: String,
        precedingText: String
    ) -> String {
        guard let firstSuggestionScalar = suggestion.unicodeScalars.first,
              CharacterSet.alphanumerics.contains(firstSuggestionScalar)
        else {
            return suggestion
        }

        let currentToken = trailingToken(in: precedingText)
        guard !currentToken.isEmpty,
              suggestion.count > currentToken.count,
              suggestion.lowercased().hasPrefix(currentToken.lowercased())
        else {
            return suggestion
        }

        let remainderStart = suggestion.index(
            suggestion.startIndex,
            offsetBy: currentToken.count
        )
        let remainder = String(suggestion[remainderStart...])
        let compactRemainder = remainder.trimmingCharacters(in: .whitespacesAndNewlines)

        // A one-character tail like "r" (for "bette" -> "better") reads as noisy in the overlay
        // and users perceive it as a regression. We drop this shape and let the pipeline request a
        // richer continuation instead of surfacing micro-completions.
        if !compactRemainder.contains(where: \.isWhitespace),
           compactRemainder.count <= 1 {
            return ""
        }

        return remainder
    }

    /// Echo stripping rebuilds text from word tokens, so it can accidentally remove the separator
    /// between the user's last typed word and the remaining suggestion. If the remainder begins with a
    /// letter/number and the draft also ends with one, restore the natural word boundary.
    private static func needsInsertedWordBoundary(
        before suggestion: String,
        after precedingText: String
    ) -> Bool {
        guard let firstSuggestionScalar = suggestion.unicodeScalars.first,
              let lastPrecedingScalar = precedingText.unicodeScalars.last
        else {
            return false
        }

        return CharacterSet.alphanumerics.contains(firstSuggestionScalar)
            && CharacterSet.alphanumerics.contains(lastPrecedingScalar)
    }
}
