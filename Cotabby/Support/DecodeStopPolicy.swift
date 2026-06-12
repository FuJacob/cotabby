import Foundation

/// Decides, during decoding, whether the completion accumulated so far already ends at a natural
/// sentence boundary so generation can stop early.
///
/// The shipping decoder otherwise samples up to a fixed token budget and trims afterward, which lets
/// the model ramble past the point a suggestion is useful. Stopping at the first real sentence end
/// keeps completions tight and is latency-positive: it generates fewer tokens. The check inspects
/// only the already-accumulated string, so it adds no per-token vocabulary work in the decode loop.
///
/// A short minimum-token guard avoids degenerate instant stops (for example, the model's first token
/// being a lone period). `SentenceBoundaryClassifier` already rejects decimals, abbreviations, and
/// list markers, so this never truncates "e.g.", "3.14", or a numbered "1." mid-thought.
nonisolated enum DecodeStopPolicy {
    static func shouldStop(
        accumulated: String,
        tokensGenerated: Int,
        minimumTokens: Int = 2
    ) -> Bool {
        guard tokensGenerated >= minimumTokens else {
            return false
        }

        return SentenceBoundaryClassifier.endsSentence(accumulated)
    }
}
