import Foundation

/// Chooses the bounded prompt suffix that native sampling may retokenize at the caret.
///
/// `LlamaRuntimeCore` creates this value for each generation or prefill. It supplies decoded token
/// bytes through a closure; this policy owns no native pointers or cache state. A word can span
/// several tokens, so undoing only the final token can strand the model on a spelling such as
/// " int" + "ell" instead of allowing its vocabulary token for " intelligence". This plan backs
/// up to the current word when it fits the existing replay allowance, always preserving exact
/// editor bytes. `TokenHealingBuffer` later removes those bytes from the visible completion.
nonisolated struct TokenHealingPlan {
    let promptTokens: [Int32]
    let replayBytes: [UInt8]

    /// The prompt exactly as tokenized, replaying nothing. Mid-word insertions use this so the
    /// native whitespace mask still constrains their first sampled token: the engine lifts that
    /// mask while it replays a healed prefix and nothing re-applies it afterwards, which let a
    /// completion inside "the|me" begin with " meeting".
    static func unhealed(tokens: [Int32]) -> TokenHealingPlan {
        TokenHealingPlan(promptTokens: tokens, replayBytes: [])
    }

    private init(promptTokens: [Int32], replayBytes: [UInt8]) {
        self.promptTokens = promptTokens
        self.replayBytes = replayBytes
    }

    init(prompt: String, tokens: [Int32], singleLine: Bool, piece: (Int32) -> [UInt8]) {
        let promptBytes = Array(prompt.utf8)
        let limit = TokenHealingBuffer.maximumHealedTokenBytes
        var kept = tokens
        var replay: [UInt8] = []

        // Retain at least one conditioning token (often BOS). Empty/special pieces and tokenizer
        // normalization must never cause us to remove text we cannot replay byte-for-byte.
        if kept.count > 1, let last = kept.last {
            let candidate = piece(last)
            if !candidate.isEmpty, candidate.count <= limit,
               promptBytes.suffix(candidate.count).elementsEqual(candidate),
               !(singleLine && candidate.contains(where: { $0 == 10 || $0 == 13 })) {
                kept.removeLast()
                replay = candidate
            }
        }

        if !replay.isEmpty, let last = prompt.last, last.isLetter || last.isNumber {
            // Include one horizontal separator: vocabularies commonly encode " word" as one
            // token. A newline stays in the conditioning context, especially for single-line UI.
            let start: String.Index
            if let separator = prompt.lastIndex(where: { $0.isWhitespace }) {
                start = prompt[separator].isNewline ? prompt.index(after: separator) : separator
            } else {
                start = prompt.startIndex
            }
            let needed = prompt[start...].utf8.count
            if needed <= limit {
                while replay.count < needed, kept.count > 1, let last = kept.last {
                    let preceding = piece(last)
                    let candidate = preceding + replay
                    guard !preceding.isEmpty, candidate.count <= limit,
                          promptBytes.suffix(candidate.count).elementsEqual(candidate),
                          !(singleLine && candidate.contains(where: { $0 == 10 || $0 == 13 })) else { break }
                    kept.removeLast()
                    replay = candidate
                }
            }
        }
        promptTokens = kept
        replayBytes = replay
    }
}
