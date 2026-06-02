import Foundation

/// File overview:
/// Pure, deterministic token selection over a single step's logits, plus a confidence helper that
/// averages per-step log-probabilities. Selection skips excluded (control) tokens, optionally
/// restricts to a set of admissible ids, and returns the surviving token with the highest logit.
///
/// Why this file exists:
/// Constrained decoding needs a selection step that is fully reproducible: the same logits and the
/// same constraints must always yield the same token, so behavior is testable and a suggestion can
/// be explained after the fact. This sampler is therefore deterministic argmax with no RNG and no
/// temperature. `topK` only bounds how large the candidate pool is before the argmax — it is a cost
/// guard, not a source of randomness, so a smaller `topK` can only ever change the result by
/// excluding lower-logit tokens that would not have won anyway among the unexcluded candidates. The
/// admissibility set (when present) is the byte-prefix constraint computed elsewhere; passing nil
/// means "no prefix constraint". Keeping this logic pure keeps the engine integration thin: the
/// runtime supplies logits and the precomputed constraints, and this returns an id (or nil when
/// nothing survives).
enum ConstrainedSampler {
    /// Selects the highest-logit token that survives the constraints, or nil when none survive.
    ///
    /// Survivors are tokens that are in-range, not `profile.isExcluded`, and — when
    /// `admissibleTokenIDs` is non-nil — members of that set. `topK` bounds the candidate pool by
    /// pre-ranking on logit before filtering: only the `topK` highest-logit token ids are considered.
    /// Because selection is a plain argmax, bounding the pool cannot change which token wins unless
    /// the winner sat outside the top `topK` by raw logit, so callers trade recall for cost by
    /// lowering `topK`. A `topK` of zero or negative considers no candidates and returns nil.
    ///
    /// Determinism note: ties on logit are broken by the lower token id, so equal-logit inputs still
    /// produce a single stable result.
    ///
    /// `blockedTokenIDs` is a per-step block-list (defaults to empty) layered on top of the static
    /// profile exclusions: a blocked id is skipped exactly like a control token. The decoder uses it
    /// for dynamic constraints such as no-repeat-ngram, which the static profile cannot express.
    static func selectToken(
        logits: [Float],
        profile: TokenProfile,
        admissibleTokenIDs: Set<Int>?,
        topK: Int,
        blockedTokenIDs: Set<Int> = []
    ) -> Int? {
        guard topK > 0, !logits.isEmpty else {
            return nil
        }
        if let admissible = admissibleTokenIDs, admissible.isEmpty {
            // An explicit empty admissible set means the prefix constraint admits nothing this step.
            return nil
        }

        let candidates = candidatePool(count: logits.count, logits: logits, limit: topK)

        var best: Int?
        var bestLogit: Float = -.infinity
        for id in candidates {
            if profile.isExcluded(id) {
                continue
            }
            if blockedTokenIDs.contains(id) {
                continue
            }
            if let admissible = admissibleTokenIDs, !admissible.contains(id) {
                continue
            }
            let logit = logits[id]
            // Strict greater-than keeps the first-seen (lower-id, because the pool is id-ordered after
            // the top-k cut) token on ties, which makes the result independent of iteration quirks.
            if best == nil || logit > bestLogit {
                best = id
                bestLogit = logit
            }
        }
        return best
    }

    /// The admissible token ids for a step, ranked highest-logit first. Survivors are the same set
    /// `selectToken` would consider — in-range, not `profile.isExcluded`, not in `blockedTokenIDs`,
    /// and, when `admissibleTokenIDs` is non-nil, members of that set — and at most `topK` are
    /// returned. This is the multi-candidate form of `selectToken`: the beam search expands a branch
    /// across these instead of committing to the single best. Ties break by lower id for determinism.
    static func rankedAdmissibleTokens(
        logits: [Float],
        profile: TokenProfile,
        admissibleTokenIDs: Set<Int>?,
        topK: Int,
        blockedTokenIDs: Set<Int> = []
    ) -> [Int] {
        guard topK > 0, !logits.isEmpty else {
            return []
        }
        if let admissible = admissibleTokenIDs, admissible.isEmpty {
            return []
        }
        let survivors = (0 ..< logits.count).filter { id in
            !profile.isExcluded(id)
                && !blockedTokenIDs.contains(id)
                && (admissibleTokenIDs?.contains(id) ?? true)
        }
        let ranked = survivors.sorted { lhs, rhs in
            if logits[lhs] != logits[rhs] {
                return logits[lhs] > logits[rhs]
            }
            return lhs < rhs
        }
        return Array(ranked.prefix(topK))
    }

    /// Average per-step log-probability of a sequence of chosen tokens, a confidence summary suitable
    /// for the existing low-confidence suppression policy.
    ///
    /// `fullRows[i]` is the full logits vector at step `i` and `chosenLogits[i]` is the logit of the
    /// token actually committed at step `i` (the caller already knows which id it picked, so it passes
    /// the scalar rather than the id). For each step this computes the softmax log-probability of the
    /// chosen token, `chosenLogit - logSumExp(row)`, and returns the mean across steps. Returns nil
    /// when there are no steps or the two inputs disagree in length, since an average is undefined
    /// then. Pure and deterministic: a numerically stable log-sum-exp (shifted by the row maximum)
    /// makes the result independent of constant offsets in the logits.
    static func averageLogProb(of chosenLogits: [Float], over fullRows: [[Float]]) -> Double? {
        guard !chosenLogits.isEmpty, chosenLogits.count == fullRows.count else {
            return nil
        }
        var total = 0.0
        for (chosen, row) in zip(chosenLogits, fullRows) {
            guard !row.isEmpty else {
                return nil
            }
            total += Double(chosen) - logSumExp(row)
        }
        return total / Double(chosenLogits.count)
    }

    /// The softmax log-probability of the token at `index` in `row`: `row[index] - logSumExp(row)`.
    /// This is the single-step form of `averageLogProb`, for decoders that score each chosen token as
    /// they go instead of retaining every logits row (retaining full rows for a whole completion would
    /// cost vocab-size floats per step). Returns nil for an empty row or an out-of-range index.
    static func logProb(ofTokenAt index: Int, in row: [Float]) -> Double? {
        guard !row.isEmpty, index >= 0, index < row.count else {
            return nil
        }
        return Double(row[index]) - logSumExp(row)
    }

    /// The token ids to consider this step, ordered by id. When `limit` is at least `count` every id
    /// is returned (still id-ordered). Otherwise the ids are ranked by descending logit, the top
    /// `limit` are kept, and that subset is re-sorted by id so downstream tie-breaking stays stable.
    private static func candidatePool(count: Int, logits: [Float], limit: Int) -> [Int] {
        guard limit < count else {
            return Array(0..<count)
        }
        let ranked = (0..<count).sorted { lhs, rhs in
            if logits[lhs] != logits[rhs] {
                return logits[lhs] > logits[rhs]
            }
            // Stable id ordering for equal logits so the kept set is deterministic at the cut line.
            return lhs < rhs
        }
        return ranked.prefix(limit).sorted()
    }

    /// Numerically stable log(sum(exp(row))): subtract the max before exponentiating so large logits
    /// do not overflow. The caller guarantees `row` is non-empty.
    private static func logSumExp(_ row: [Float]) -> Double {
        let maxLogit = Double(row.max() ?? 0)
        var sumExp = 0.0
        for value in row {
            sumExp += exp(Double(value) - maxLogit)
        }
        return maxLogit + log(sumExp)
    }
}
