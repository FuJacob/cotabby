import Foundation

/// File overview:
/// A pure, cheap estimate of how many model tokens a string occupies, used to budget the base-model
/// prompt more faithfully than a flat character count without paying for a real tokenizer on the
/// main-actor prompt path.
///
/// It is intentionally an approximation: a word-aware heuristic (roughly four characters per token
/// within a word, every word at least one token) is closer to real subword tokenization than a single
/// global chars-per-token ratio — especially for code or short function words — while staying
/// allocation-light and deterministic for tests. It is not exact, so it is used only for relative
/// budgeting decisions, never to assert a hard token limit.
nonisolated enum TokenCountEstimator {
    static func estimate(_ text: String) -> Int {
        // Split on punctuation as well as whitespace: real subword tokenizers break "can't", "end.",
        // and "func()" into multiple tokens, so gluing punctuation to a word would systematically
        // undercount code and punctuation-heavy prose.
        let words = text.split(whereSeparator: { $0.isWhitespace || $0.isPunctuation })
        guard !words.isEmpty else {
            return 0
        }
        return words.reduce(0) { total, word in
            total + max(1, Int((Double(word.count) / 4.0).rounded()))
        }
    }
}
