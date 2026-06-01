import Foundation

/// File overview:
/// Pure no-repeat-ngram logic for the deterministic constrained decoder. Given the tokens generated
/// so far, it returns the token ids that must not be emitted next because doing so would repeat an
/// n-gram that already appeared in the output.
///
/// Why this file exists:
/// The constrained decoder selects each token by raw-logit argmax. Greedy argmax has no inherent
/// resistance to repetition (the engine's `repetition_penalty` lives in its own sampler, which the
/// constrained path bypasses), so a base model can fall into a loop — "I think that I think that …"
/// or a single token emitted forever. A hard no-repeat-ngram block is the standard, deterministic
/// remedy: it forbids closing any (n)-gram that the output already contains. Keeping it pure makes
/// the rule exhaustively testable and keeps the decode loop a thin driver.
enum RepetitionGuard {
    /// The token ids that would, if emitted next, repeat an `ngramSize`-gram already present in
    /// `history`. A token `t` is blocked when the last `ngramSize - 1` tokens of `history` (the
    /// pending prefix) already occur earlier in `history` immediately followed by `t`; emitting `t`
    /// would reproduce that whole n-gram a second time.
    ///
    /// Returns an empty set when `ngramSize < 2` (a 1-gram block would forbid every token that ever
    /// appeared, killing normal repetition like "the … the") or when `history` is too short to hold a
    /// full prefix. Operates on token ids, not text, so it is independent of detokenization and works
    /// the same for any vocabulary.
    static func blockedTokens(history: [Int], ngramSize: Int) -> Set<Int> {
        let prefixLength = ngramSize - 1
        guard ngramSize >= 2, history.count >= prefixLength else {
            return []
        }

        // The pending prefix is the suffix of history that a next token would extend into an n-gram.
        let prefix = Array(history.suffix(prefixLength))

        var blocked: Set<Int> = []
        // Every earlier position whose `prefixLength`-gram equals the pending prefix contributes the
        // token that followed it: emitting that token now would repeat the n-gram.
        var start = 0
        let lastPrefixStart = history.count - prefixLength
        while start < lastPrefixStart {
            var matches = true
            for offset in 0 ..< prefixLength where history[start + offset] != prefix[offset] {
                matches = false
                break
            }
            if matches {
                blocked.insert(history[start + prefixLength])
            }
            start += 1
        }
        return blocked
    }
}
