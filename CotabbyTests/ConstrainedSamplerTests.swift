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
