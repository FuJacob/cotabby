import Foundation

/// Decides, during decoding, whether the completion accumulated so far should stop generation
/// early, and why.
///
/// The shipping decoder otherwise samples up to a fixed token budget and trims afterward, which lets
/// the model ramble past the point a suggestion is useful. Three early stops apply:
///
/// - **Sentence boundary**: the accumulated text ends at a natural sentence end. A short
///   minimum-token guard avoids degenerate instant stops (for example, the model's first token being
///   a lone period). `SentenceBoundaryClassifier` already rejects decimals, abbreviations, and list
///   markers, so this never truncates "e.g.", "3.14", or a numbered "1." mid-thought.
/// - **Line break** (single-line suggestions only): the model ended the line, so the suggestion
///   ends there too.
/// - **Scaffolding marker**: the accumulated text contains a chat-template stop marker
///   (`<|im_end|>` and friends). The normalizer already truncates the visible text at the first such
///   marker, so everything generated past it is guaranteed-discarded work; stopping at decode time
///   produces the identical suggestion while skipping the rest of the token budget, exactly in the
///   worst case where the model has drifted into template scaffolding. No minimum-token guard: a
///   marker means the model believes the turn is over, no matter how early it appears.
///
/// Both checks inspect only the already-accumulated string (at most a few hundred characters), so
/// they add no per-token vocabulary work in the decode loop.
nonisolated enum DecodeStopPolicy {
    /// Why decoding stopped early. Raw values feed the decode log's `stop_reason` field.
    enum StopReason: String {
        case sentenceBoundary = "sentence_boundary"
        case scaffoldingMarker = "scaffolding_marker"
        case lineBreak = "line_break"
    }

    static func verdict(
        accumulated: String,
        tokensGenerated: Int,
        minimumTokens: Int = 2,
        minimumWords: Int = 0,
        stopsAtLineBreak: Bool = false
    ) -> StopReason? {
        if containsScaffoldingStopMarker(accumulated) {
            return .scaffoldingMarker
        }

        guard tokensGenerated >= minimumTokens else {
            return nil
        }

        // A single-line suggestion ends where the model ends the line — but only once the
        // minimum-token guard has passed. Checked before the guard, a first token of "\n"
        // stopped decode immediately, the normalizer stripped it to empty, and the user got
        // no suggestion at all. The sentence-boundary stop below has the same guard for
        // the same reason (a lone first-token period).
        if stopsAtLineBreak, accumulated.contains(where: \.isNewline) {
            return .lineBreak
        }

        // A sentence end before the preset's minimum word count ("report.") made one ghost a single
        // word and the next a whole phrase; let the model carry on into the next sentence instead.
        if minimumWords > 0, wordCount(of: accumulated) < minimumWords {
            return nil
        }
        return SentenceBoundaryClassifier.endsSentence(accumulated) ? .sentenceBoundary : nil
    }

    /// What to do once the token budget is spent: keep decoding to finish the word in progress, or
    /// stop with this text.
    enum WordCompletion: Equatable {
        case keepDecoding
        case stop(String)
    }

    /// Extra tokens a word in progress may take past the budget: an 18-character tracking number or
    /// a meeting link is several tokens long.
    static let maximumWordCompletionTokens = 16

    /// The budget is counted in tokens, so it can run out inside a word: the copied link stopped at
    /// "https://zoom.us/j/9823" and a tracking number at "1Z999AA1012" (recall eval, 2026-10-21), and
    /// accepting either types a wrong value. Past the budget, decoding continues only until the word
    /// ends: the text is cut at the first whitespace the extra tokens bring. When the budget ends at
    /// a word boundary, the one extra token starts the next word and is dropped.
    static func wordCompletion(textAtBudget: String, accumulated: String, extraTokens: Int) -> WordCompletion {
        guard let last = textAtBudget.last, !last.isWhitespace else { return .stop(textAtBudget) }
        let start = accumulated.index(accumulated.startIndex, offsetBy: min(textAtBudget.count, accumulated.count))
        if let boundary = accumulated[start...].firstIndex(where: \.isWhitespace) {
            return .stop(String(accumulated[..<boundary]))
        }
        return extraTokens >= maximumWordCompletionTokens ? .stop(accumulated) : .keepDecoding
    }

    private static func wordCount(of text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    private static func containsScaffoldingStopMarker(_ text: String) -> Bool {
        // Cheap pre-filter: every stop marker starts with "<", so most prose never reaches the
        // per-marker scan.
        guard text.contains("<") else { return false }
        return ControlTokenMarkers.stopMarkers.contains { text.contains($0) }
    }
}
