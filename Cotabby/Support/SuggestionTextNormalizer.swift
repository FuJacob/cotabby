import Foundation

/// File overview:
/// Centralizes the last-mile cleanup that turns raw model output into inline ghost text.
/// Both llama.cpp and Apple's Foundation Models backend feed through this helper so prompt
/// formatting quirks stay in one place instead of drifting across runtime implementations.
///
/// This type is intentionally pure. Given the same request and raw output, it always returns the
/// same normalized suggestion. That makes it safe to share across backends and easy to test later.

/// Why a raw completion was reduced to empty ghost text. Logging this lets on-device evaluation
/// separate "the model produced nothing usable" from "a safety or echo filter dropped a real
/// completion" — the two read identically once the text is empty, but they point at opposite fixes
/// (prompt/model tuning vs. an over-aggressive filter).
enum CompletionSuppressionReason: String, Sendable, Equatable {
    /// The model emitted only whitespace (or nothing) to begin with.
    case emptyGeneration
    /// Raw output existed but was entirely control markers, reasoning blocks, scaffolding labels,
    /// or newlines, so nothing survived normalization.
    case normalizedToEmpty
    /// The completion began by repeating text that already follows the caret.
    case duplicatesTrailingText
    /// The completion echoed the tail of the preceding text in full, leaving nothing new to add.
    case echoesPrecedingText
    /// Printable characters survived but carried control/replacement glyphs the safety gate rejects.
    case unsafeToInsert
}

/// Outcome of normalizing one raw completion: the ghost text, plus the attributable reason when that
/// text is empty. `suppression` is always nil when `text` is non-empty.
struct SuggestionNormalizationResult: Equatable, Sendable {
    let text: String
    let suppression: CompletionSuppressionReason?
}

enum SuggestionTextNormalizer {
    /// Convenience wrapper returning only the ghost text. Callers that want to know *why* an empty
    /// result came back (for diagnostics / on-device decode evaluation) should call
    /// `normalizeDetailed` instead, which is the single source of truth this delegates to.
    static func normalize(
        _ rawSuggestion: String,
        for request: SuggestionRequest,
        promptEchoCandidates: [String] = []
    ) -> String {
        normalizeDetailed(rawSuggestion, for: request, promptEchoCandidates: promptEchoCandidates).text
    }

    /// Normalizes one raw completion and, when the result is empty, attributes the suppression to a
    /// specific cause. This is the distinction the logs need to tell "the model produced nothing
    /// usable" apart from "a safety/echo filter dropped a real completion" — without it, every empty
    /// outcome reads identically as a generic empty result.
    static func normalizeDetailed(
        _ rawSuggestion: String,
        for request: SuggestionRequest,
        promptEchoCandidates: [String] = []
    ) -> SuggestionNormalizationResult {
        let rawHadContent = !rawSuggestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        var normalized = rawSuggestion.replacingOccurrences(of: "\r", with: "")

        // Base models still carry the special tokens of the chat templates they were trained
        // alongside and can emit them as literal text. Strip that scaffolding so the UI layer stays
        // independent of backend formatting: opening/role markers are removed in place, and anything
        // from a stop marker onward (a hallucinated new turn) is truncated. See `ControlTokenMarkers`.
        normalized = ControlTokenMarkers.sanitize(normalized)

        // Thinking-capable models may emit <think>…</think> reasoning blocks. Strip them here so
        // the reasoning text never reaches the continuation logic below.
        normalized = stripThinkBlocks(normalized)

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
        if TrailingDuplicationFilter.duplicatesTrailingText(
            normalized,
            trailingText: request.context.trailingText
        ) {
            return SuggestionNormalizationResult(text: "", suppression: .duplicatesTrailingText)
        }

        // Echo suppression: strip any leading words that repeat the tail of the preceding text.
        // Small models sometimes regurgitate the prompt suffix instead of continuing from it.
        // Word-by-word suffix–prefix overlap catches "hello world " → "world is great" and
        // strips "world" so the ghost text shows only " is great". A full collapse to empty here
        // means the model only re-emitted the preceding text, which we report distinctly below.
        let beforeEchoStrip = normalized
        normalized = stripEchoPrefix(normalized, precedingText: request.context.precedingText)
        let collapsedByEcho = !beforeEchoStrip.isEmpty && normalized.isEmpty

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

        // Final safety gate: never surface control characters, replacement glyphs, or
        // whitespace-only output as ghost text. Returning empty makes the coordinator treat this
        // as "no suggestion" and regenerate rather than insert junk on Tab.
        guard InsertionSafetyGate.isSafeToInsert(normalized) else {
            return SuggestionNormalizationResult(
                text: "",
                suppression: suppressionForEmptyResult(
                    collapsedByEcho: collapsedByEcho,
                    rawHadContent: rawHadContent,
                    normalized: normalized
                )
            )
        }

        return SuggestionNormalizationResult(text: normalized, suppression: nil)
    }

    /// Names the most specific cause of an empty normalization outcome at the safety gate. The gate
    /// rejects empty, whitespace-only, and control/replacement-glyph output alike, so we disambiguate
    /// here: an echo collapse and a genuinely-empty generation are very different signals on device.
    private static func suppressionForEmptyResult(
        collapsedByEcho: Bool,
        rawHadContent: Bool,
        normalized: String
    ) -> CompletionSuppressionReason {
        if collapsedByEcho {
            return .echoesPrecedingText
        }
        let survivingContent = !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if survivingContent {
            // Real characters made it through but carried control/replacement glyphs the gate rejects.
            return .unsafeToInsert
        }
        // Nothing printable survived: either the model emitted only whitespace, or everything it
        // produced was control markers / reasoning / scaffolding that normalization stripped away.
        return rawHadContent ? .normalizedToEmpty : .emptyGeneration
    }

    /// Removes `<think>…</think>` reasoning blocks: complete blocks first, then any dangling open
    /// tag left when generation hit the token limit before the block was closed.
    private static func stripThinkBlocks(_ text: String) -> String {
        // Both patterns below require a literal `<think>`, so this cheap scan lets the common case
        // (no reasoning block — the vast majority of completions) skip regex work entirely.
        // `String.range(of:options:.regularExpression)` compiles its pattern on every call, and
        // this runs on the per-prediction critical path.
        guard text.contains("<think>") else {
            return text
        }
        var result = text
        if let complete = result.range(of: "<think>[\\s\\S]*?</think>", options: .regularExpression) {
            result.replaceSubrange(complete, with: "")
        }
        if let dangling = result.range(of: "<think>[\\s\\S]*", options: .regularExpression) {
            result.replaceSubrange(dangling, with: "")
        }
        return result
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

    /// `scaffoldingLabels` ordered longest-first, computed once. The ordering is what makes
    /// "Text before the caret:" win over a shorter sibling; sorting on every call repeated that
    /// work on the per-prediction critical path for an identical result.
    private static let labelsByLengthDescending: [String] = scaffoldingLabels.sorted { $0.count > $1.count }

    /// Removes a leading run of known prompt-scaffolding labels (see `scaffoldingLabels`), whether
    /// each sits on its own line or inline before the continuation. Only labels at the very start
    /// are stripped; a label appearing later in the text is left alone because by then it is far
    /// more likely to be real user content than echoed scaffolding.
    private static func stripLeadingScaffoldingLabels(_ text: String) -> String {
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
