import Foundation

/// Decides, during decoding, whether the completion accumulated so far should stop generation
/// early, and why.
///
/// The shipping decoder otherwise samples up to a fixed token budget and trims afterward, which lets
/// the model ramble past the point a suggestion is useful. Two early stops apply:
///
/// - **Sentence boundary**: the accumulated text ends at a natural sentence end. A short
///   minimum-token guard avoids degenerate instant stops (for example, the model's first token being
///   a lone period). `SentenceBoundaryClassifier` already rejects decimals, abbreviations, and list
///   markers, so this never truncates "e.g.", "3.14", or a numbered "1." mid-thought.
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
    }

    static func verdict(
        accumulated: String,
        tokensGenerated: Int,
        minimumTokens: Int = 2
    ) -> StopReason? {
        if containsScaffoldingStopMarker(accumulated) {
            return .scaffoldingMarker
        }

        guard tokensGenerated >= minimumTokens else {
            return nil
        }

        return SentenceBoundaryClassifier.endsSentence(accumulated) ? .sentenceBoundary : nil
    }

    static func shouldStop(
        accumulated: String,
        tokensGenerated: Int,
        minimumTokens: Int = 2
    ) -> Bool {
        verdict(
            accumulated: accumulated,
            tokensGenerated: tokensGenerated,
            minimumTokens: minimumTokens
        ) != nil
    }

    private static func containsScaffoldingStopMarker(_ text: String) -> Bool {
        // Cheap pre-filter: every stop marker starts with "<", so most prose never reaches the
        // per-marker scan.
        guard text.contains("<") else { return false }
        return ControlTokenMarkers.stopMarkers.contains { text.contains($0) }
    }
}
