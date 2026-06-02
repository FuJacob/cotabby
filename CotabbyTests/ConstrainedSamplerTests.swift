import XCTest
@testable import Cotabby

/// Pure-function tests for deterministic constrained selection and the confidence helper. No RNG is
/// involved, so every selection is an exact, repeatable argmax under the given constraints.
final class ConstrainedSamplerTests: XCTestCase {

    /// Profile of plain non-control, non-EOG tokens with single-letter bytes, one per logit slot.
    private func plainProfile(count: Int, control: Set<Int> = []) -> TokenProfile {
        TokenProfile.build(
            vocabSize: count,
            bytesFor: { [UInt8(65 + ($0 % 26))] },
            isControl: { control.contains($0) },
            isEndOfGeneration: { _ in false }
        )
    }

    // MARK: - selectToken

    func test_select_returnsHighestLogit() {
        let logits: [Float] = [0.1, 2.5, 1.0, -3.0]
        let id = ConstrainedSampler.selectToken(
            logits: logits,
            profile: plainProfile(count: 4),
            admissibleTokenIDs: nil,
            topK: 4
        )
        XCTAssertEqual(id, 1)
    }

    func test_select_skipsExcludedControlTokens() {
        // Token 1 has the highest logit but is control, so it must be skipped in favor of token 2.
        let logits: [Float] = [0.1, 5.0, 2.0, 1.0]
        let id = ConstrainedSampler.selectToken(
            logits: logits,
            profile: plainProfile(count: 4, control: [1]),
            admissibleTokenIDs: nil,
            topK: 4
        )
        XCTAssertEqual(id, 2)
    }

    func test_select_honorsAdmissibleSet() {
        // Highest logit is token 0, but only {2, 3} are admissible, so token 2 (higher of the two) wins.
        let logits: [Float] = [9.0, 8.0, 3.0, 2.0]
        let id = ConstrainedSampler.selectToken(
            logits: logits,
            profile: plainProfile(count: 4),
            admissibleTokenIDs: [2, 3],
            topK: 4
        )
        XCTAssertEqual(id, 2)
    }

    func test_select_emptyAdmissibleSet_returnsNil() {
        // An explicit empty constraint admits nothing this step.
        let logits: [Float] = [1.0, 2.0, 3.0]
        let id = ConstrainedSampler.selectToken(
            logits: logits,
            profile: plainProfile(count: 3),
            admissibleTokenIDs: [],
            topK: 3
        )
        XCTAssertNil(id)
    }

    func test_select_allExcluded_returnsNil() {
        let logits: [Float] = [1.0, 2.0, 3.0]
        let id = ConstrainedSampler.selectToken(
            logits: logits,
            profile: plainProfile(count: 3, control: [0, 1, 2]),
            admissibleTokenIDs: nil,
            topK: 3
        )
        XCTAssertNil(id)
    }

    func test_select_admissibleIDOutOfRange_isIgnored() {
        // An admissible id with no logit slot must not crash or be selected; the in-range admissible
        // token wins instead.
        let logits: [Float] = [1.0, 4.0]
        let id = ConstrainedSampler.selectToken(
            logits: logits,
            profile: plainProfile(count: 2),
            admissibleTokenIDs: [1, 99],
            topK: 2
        )
        XCTAssertEqual(id, 1)
    }

    func test_select_tieBrokenByLowerID() {
        // Equal logits must resolve to the lower id so the result is stable.
        let logits: [Float] = [5.0, 5.0, 5.0]
        let id = ConstrainedSampler.selectToken(
            logits: logits,
            profile: plainProfile(count: 3),
            admissibleTokenIDs: nil,
            topK: 3
        )
        XCTAssertEqual(id, 0)
    }

    func test_select_topKBoundsCandidatePool() {
        // topK=2 keeps only the two highest-logit ids {0, 3}; the lower-logit ids 1 and 2 are never
        // considered. Token 0 is excluded (control), so token 3 wins from within the bounded pool.
        let logits: [Float] = [9.0, 1.0, 2.0, 8.0]
        let id = ConstrainedSampler.selectToken(
            logits: logits,
            profile: plainProfile(count: 4, control: [0]),
            admissibleTokenIDs: nil,
            topK: 2
        )
        XCTAssertEqual(id, 3)
    }

    func test_select_topKTooSmallToReachAdmissible_returnsNil() {
        // Admissible token 2 has a low logit; topK=1 keeps only the global max (token 0), which is not
        // admissible, so nothing survives. Demonstrates that topK trades recall for cost.
        let logits: [Float] = [9.0, 8.0, 0.5]
        let id = ConstrainedSampler.selectToken(
            logits: logits,
            profile: plainProfile(count: 3),
            admissibleTokenIDs: [2],
            topK: 1
        )
        XCTAssertNil(id)
    }

    func test_select_topKZero_returnsNil() {
        let id = ConstrainedSampler.selectToken(
            logits: [1.0, 2.0],
            profile: plainProfile(count: 2),
            admissibleTokenIDs: nil,
            topK: 0
        )
        XCTAssertNil(id)
    }

    func test_select_emptyLogits_returnsNil() {
        let id = ConstrainedSampler.selectToken(
            logits: [],
            profile: plainProfile(count: 0),
            admissibleTokenIDs: nil,
            topK: 4
        )
        XCTAssertNil(id)
    }

    func test_select_isDeterministicAcrossRepeatedCalls() {
        let logits: [Float] = [0.3, 0.31, 0.305, 0.31]
        let profile = plainProfile(count: 4)
        let first = ConstrainedSampler.selectToken(
            logits: logits, profile: profile, admissibleTokenIDs: nil, topK: 4
        )
        for _ in 0..<20 {
            let again = ConstrainedSampler.selectToken(
                logits: logits, profile: profile, admissibleTokenIDs: nil, topK: 4
            )
            XCTAssertEqual(again, first)
        }
        // Tie between ids 1 and 3 resolves to the lower id.
        XCTAssertEqual(first, 1)
    }

    func test_select_skipsBlockedTokens() {
        // Token 1 has the highest logit but is blocked (e.g. by the repetition guard), so the
        // next-highest unblocked token wins.
        let logits: [Float] = [0.1, 5.0, 2.0, 1.0]
        let id = ConstrainedSampler.selectToken(
            logits: logits,
            profile: plainProfile(count: 4),
            admissibleTokenIDs: nil,
            topK: 4,
            blockedTokenIDs: [1]
        )
        XCTAssertEqual(id, 2)
    }

    func test_select_allBlocked_returnsNil() {
        let logits: [Float] = [1.0, 2.0, 3.0]
        let id = ConstrainedSampler.selectToken(
            logits: logits,
            profile: plainProfile(count: 3),
            admissibleTokenIDs: nil,
            topK: 3,
            blockedTokenIDs: [0, 1, 2]
        )
        XCTAssertNil(id)
    }

    // MARK: - candidatePool equivalence (top-K selection without a full sort)

    /// Deterministic, seedable RNG so the randomized equivalence sweep is reproducible across runs and
    /// machines (no dependence on `SystemRandomNumberGenerator`).
    private struct SplitMix64: RandomNumberGenerator {
        private var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var mixed = state
            mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
            return mixed ^ (mixed >> 31)
        }
    }

    /// Reference selection that mirrors the *old* implementation exactly: rank the whole vocabulary by
    /// (logit desc, id asc), keep the top `topK`, then argmax the survivors. `selectToken` now skips
    /// the full sort, so this is the oracle the fast path must reproduce bit-for-bit.
    private func referenceSelect(
        logits: [Float],
        control: Set<Int>,
        admissible: Set<Int>?,
        topK: Int,
        blocked: Set<Int>
    ) -> Int? {
        guard topK > 0, !logits.isEmpty else { return nil }
        if let admissible, admissible.isEmpty { return nil }
        let ranked = (0 ..< logits.count).sorted { lhs, rhs in
            if logits[lhs] != logits[rhs] { return logits[lhs] > logits[rhs] }
            return lhs < rhs
        }
        let pool = Array(ranked.prefix(topK)).sorted()
        var best: Int?
        var bestLogit: Float = -.infinity
        for id in pool {
            if control.contains(id) || blocked.contains(id) { continue }
            if let admissible, !admissible.contains(id) { continue }
            if best == nil || logits[id] > bestLogit {
                best = id
                bestLogit = logits[id]
            }
        }
        return best
    }

    /// The fast top-K selection must match the old full-sort behavior for every combination of vocab
    /// size, tie structure, topK cut, exclusions, blocks, and admissibility. Logits are quantized to a
    /// few distinct values on many trials so exact-tie cut-line behavior (lower id wins) is exercised
    /// heavily, which is where a hand-rolled top-K is most likely to diverge from a full sort.
    func test_select_matchesFullSortReferenceAcrossRandomInputs() {
        var rng = SplitMix64(seed: 0xC0FFEE_D00D)
        for trial in 0 ..< 4000 {
            let count = Int.random(in: 1 ... 120, using: &rng)
            // Alternate between coarse (tie-heavy) and fine logit granularity.
            let distinctValues = trial.isMultiple(of: 2) ? 4 : 64
            let logits = (0 ..< count).map { _ in
                Float(Int.random(in: 0 ..< distinctValues, using: &rng))
            }
            let control = Set((0 ..< count).filter { _ in Int.random(in: 0 ..< 5, using: &rng) == 0 })
            let blocked = Set((0 ..< count).filter { _ in Int.random(in: 0 ..< 6, using: &rng) == 0 })
            let admissible: Set<Int>? = Int.random(in: 0 ..< 3, using: &rng) == 0
                ? nil
                : Set((0 ..< count).filter { _ in Int.random(in: 0 ..< 2, using: &rng) == 0 })
            let topK = Int.random(in: 0 ... (count + 2), using: &rng)

            let actual = ConstrainedSampler.selectToken(
                logits: logits,
                profile: plainProfile(count: count, control: control),
                admissibleTokenIDs: admissible,
                topK: topK,
                blockedTokenIDs: blocked
            )
            let expected = referenceSelect(
                logits: logits,
                control: control,
                admissible: admissible,
                topK: topK,
                blocked: blocked
            )
            XCTAssertEqual(
                actual,
                expected,
                "trial \(trial): count=\(count) topK=\(topK) diverged from full-sort reference"
            )
        }
    }

    /// Cut-line tie-break: when the top-`topK` boundary falls in a run of equal logits, the lower ids
    /// must be the ones kept (so the selected token is the lowest id in the tied run), exactly as the
    /// previous full sort guaranteed. A large vocab makes a regression in the bounded selection obvious.
    func test_select_largeVocabEqualLogits_keepsLowestIDsAtCut() {
        let count = 5000
        let logits = [Float](repeating: 1.0, count: count)
        let id = ConstrainedSampler.selectToken(
            logits: logits,
            profile: plainProfile(count: count),
            admissibleTokenIDs: nil,
            topK: 20
        )
        // All logits equal -> the kept pool is ids 0...19 and argmax breaks to the lowest id.
        XCTAssertEqual(id, 0)
    }

    // MARK: - averageLogProb

    func test_averageLogProb_uniformRow_matchesNegativeLogVocab() {
        // Every logit equal -> each token's probability is 1/N, so log-prob is -ln(N) every step.
        let row: [Float] = [0, 0, 0, 0]
        let value = ConstrainedSampler.averageLogProb(of: [0, 0], over: [row, row])
        XCTAssertNotNil(value)
        XCTAssertEqual(value ?? .nan, -log(4.0), accuracy: 1e-9)
    }

    func test_averageLogProb_isInvariantToConstantOffset() {
        // Adding a constant to every logit in a row leaves softmax (and thus the log-prob) unchanged.
        let base: [Float] = [1.0, 2.0, 0.5]
        let shifted: [Float] = base.map { $0 + 100.0 }
        let plain = ConstrainedSampler.averageLogProb(of: [2.0], over: [base])
        let offset = ConstrainedSampler.averageLogProb(of: [102.0], over: [shifted])
        XCTAssertNotNil(plain)
        XCTAssertNotNil(offset)
        XCTAssertEqual(plain ?? .nan, offset ?? .nan, accuracy: 1e-6)
    }

    func test_averageLogProb_averagesAcrossSteps() {
        // Two steps with known per-step log-probs; the result is their mean.
        let rowA: [Float] = [0, 0] // chosen logit 0 -> log(0.5)
        let rowB: [Float] = [0, 0, 0, 0] // chosen logit 0 -> log(0.25)
        let value = ConstrainedSampler.averageLogProb(of: [0, 0], over: [rowA, rowB])
        let expected = (log(0.5) + log(0.25)) / 2.0
        XCTAssertEqual(value ?? .nan, expected, accuracy: 1e-9)
    }

    func test_averageLogProb_emptyInput_returnsNil() {
        XCTAssertNil(ConstrainedSampler.averageLogProb(of: [], over: []))
    }

    func test_averageLogProb_lengthMismatch_returnsNil() {
        XCTAssertNil(ConstrainedSampler.averageLogProb(of: [1.0], over: [[1.0], [2.0]]))
    }

    func test_averageLogProb_emptyRow_returnsNil() {
        XCTAssertNil(ConstrainedSampler.averageLogProb(of: [1.0], over: [[]]))
    }

    // MARK: - logProb (single-step)

    func test_logProb_uniformRow_matchesNegativeLogVocab() {
        // Uniform logits -> every token has probability 1/N -> log-prob is -ln(N).
        let row: [Float] = [0, 0, 0, 0]
        let value = ConstrainedSampler.logProb(ofTokenAt: 2, in: row)
        XCTAssertEqual(value ?? .nan, -log(4.0), accuracy: 1e-9)
    }

    func test_logProb_matchesAverageLogProbForSingleStep() {
        // The single-step helper must agree with averaging one row, since the decoder accumulates the
        // former where the offline confidence helper uses the latter.
        let row: [Float] = [1.0, 2.0, 0.5, -1.0]
        let single = ConstrainedSampler.logProb(ofTokenAt: 1, in: row)
        let averaged = ConstrainedSampler.averageLogProb(of: [row[1]], over: [row])
        XCTAssertNotNil(single)
        XCTAssertEqual(single ?? .nan, averaged ?? .nan, accuracy: 1e-9)
    }

    func test_logProb_isInvariantToConstantOffset() {
        let base: [Float] = [1.0, 2.0, 0.5]
        let shifted: [Float] = base.map { $0 + 50.0 }
        let plain = ConstrainedSampler.logProb(ofTokenAt: 0, in: base)
        let offset = ConstrainedSampler.logProb(ofTokenAt: 0, in: shifted)
        XCTAssertEqual(plain ?? .nan, offset ?? .nan, accuracy: 1e-6)
    }

    func test_logProb_outOfRangeIndex_returnsNil() {
        XCTAssertNil(ConstrainedSampler.logProb(ofTokenAt: 5, in: [1.0, 2.0]))
        XCTAssertNil(ConstrainedSampler.logProb(ofTokenAt: -1, in: [1.0, 2.0]))
    }

    func test_logProb_emptyRow_returnsNil() {
        XCTAssertNil(ConstrainedSampler.logProb(ofTokenAt: 0, in: []))
    }
}
