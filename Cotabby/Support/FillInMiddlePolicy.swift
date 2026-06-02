import Foundation

/// File overview:
/// Pure rules for fill-in-middle (FIM) prompting: detecting whether a model's vocabulary carries the
/// FIM marker tokens, and assembling a FIM prompt token sequence from the text before and after the
/// caret. FIM lets a base model infill at the cursor conditioned on what comes *after* it, not just
/// before, which is what a correct mid-line completion needs.
///
/// Why this file exists:
/// FIM is a prompt-construction concern, not a decoding one, and it is model-specific (only models
/// trained with FIM markers can do it). Keeping detection and assembly pure makes both unit-testable
/// without a runtime, and leaves the runtime only "tokenize and decode". Detection is an exact match
/// against the well-known marker strings, so a model that lacks them simply falls back to the ordinary
/// base prompt.

/// The three FIM marker token ids a model needs for prefix / suffix / middle infilling.
struct FIMMarkers: Equatable {
    let prefix: Int
    let suffix: Int
    let middle: Int
}

enum FillInMiddlePolicy {
    /// The marker strings this detector recognizes (the llama.cpp / Qwen convention). A model is
    /// FIM-capable here only if all three decode to a single vocabulary token.
    static let prefixMarker = "<|fim_prefix|>"
    static let suffixMarker = "<|fim_suffix|>"
    static let middleMarker = "<|fim_middle|>"

    /// Finds the FIM marker token ids by scanning the vocabulary for tokens whose decoded bytes equal a
    /// marker string. Returns nil unless all three are present (the model is then not FIM-capable, and
    /// the caller falls back to the base prompt). `bytesFor` is the same per-token detokenize the token
    /// profile uses, so a runtime can reuse its vocabulary snapshot.
    static func detectMarkers(vocabSize: Int, bytesFor: (Int) -> [UInt8]) -> FIMMarkers? {
        let prefixBytes = Array(prefixMarker.utf8)
        let suffixBytes = Array(suffixMarker.utf8)
        let middleBytes = Array(middleMarker.utf8)
        var prefix: Int?
        var suffix: Int?
        var middle: Int?
        for id in 0 ..< vocabSize {
            let bytes = bytesFor(id)
            if bytes == prefixBytes {
                prefix = id
            } else if bytes == suffixBytes {
                suffix = id
            } else if bytes == middleBytes {
                middle = id
            }
            if let prefix, let suffix, let middle {
                return FIMMarkers(prefix: prefix, suffix: suffix, middle: middle)
            }
        }
        return nil
    }

    /// Assembles a FIM prompt in prefix-suffix-middle order: `[prefix] prefixTokens [suffix]
    /// suffixTokens [middle]`. The model then generates the text that belongs at the caret. When the
    /// prefix and suffix together exceed `maxTokens`, each is trimmed toward the caret (the prefix keeps
    /// its tail, the suffix keeps its head), so the marker structure and the text nearest the cursor are
    /// preserved. The three marker tokens are always included (they are the prompt's structure), so the
    /// prefix and suffix together are bounded by `maxTokens - 3`.
    static func assemblePromptTokens(
        prefixTokens: [Int32],
        suffixTokens: [Int32],
        markers: FIMMarkers,
        maxTokens: Int
    ) -> [Int32] {
        let budget = max(0, maxTokens - 3)
        // Suffix gets up to half the budget (its head, nearest the caret); the prefix gets the rest of
        // the budget from its tail, so the words right before the caret are always kept.
        let suffixKept = Array(suffixTokens.prefix(min(suffixTokens.count, budget / 2)))
        let prefixKept = Array(prefixTokens.suffix(max(0, budget - suffixKept.count)))

        var tokens: [Int32] = [Int32(markers.prefix)]
        tokens.append(contentsOf: prefixKept)
        tokens.append(Int32(markers.suffix))
        tokens.append(contentsOf: suffixKept)
        tokens.append(Int32(markers.middle))
        return tokens
    }
}
