import XCTest
@testable import Cotabby

/// Tests for the constrained beam search, exercised against a scripted `BeamLogitsProvider` that maps
/// a generated-token path to a logits row. This validates the whole search algorithm deterministically
/// without loading a model; the live llama adapter is a thin KV-sync method on the runtime.
final class ConstrainedBeamSearchTests: XCTestCase {

    // MARK: - Fixtures

    /// Records the token paths the search queried, so a test can assert it stopped where expected.
    private final class PathRecorder {
        private(set) var paths: [[Int]] = []
        func record(_ path: [Int]) { paths.append(path) }
    }

    /// A scripted logits provider: returns the row mapped for a path, or a uniform low row otherwise.
    private func provider(
        vocabSize: Int,
        rows: [[Int]: [Float]],
        recorder: PathRecorder? = nil
    ) -> BeamLogitsProvider {
        { path in
            recorder?.record(path)
            return rows[path] ?? [Float](repeating: -20, count: vocabSize)
        }
    }

    private func makeProfile(byteStrings: [String], eog: Set<Int> = []) -> TokenProfile {
        let bytes = byteStrings.map { Array($0.utf8) }
        return TokenProfile.build(
            vocabSize: bytes.count,
            bytesFor: { bytes[$0] },
            isControl: { bytes[$0].isEmpty },
            isEndOfGeneration: { eog.contains($0) }
        )
    }

    private func row(_ values: [Int: Float], vocabSize: Int) -> [Float] {
        var logits = [Float](repeating: -20, count: vocabSize)
        for (id, value) in values {
            logits[id] = value
        }
        return logits
    }

    // MARK: - rankedAdmissibleTokens

    func test_rankedAdmissibleTokens_ordersByLogitAndDropsExcludedAndBlocked() {
        // token 2 is control (empty bytes) -> excluded; token 0 is blocked by the caller.
        let profile = makeProfile(byteStrings: ["a", "b", "", "d"])
        let logits: [Float] = [9, 8, 7, 6]

        let ranked = ConstrainedSampler.rankedAdmissibleTokens(
            logits: logits, profile: profile, admissibleTokenIDs: nil, topK: 10, blockedTokenIDs: [0])

        XCTAssertEqual(ranked, [1, 3], "drops blocked 0 and control 2; orders the rest by logit")
    }

    func test_rankedAdmissibleTokens_capsAtTopK() {
        let profile = makeProfile(byteStrings: ["a", "b", "c", "d"])
        let ranked = ConstrainedSampler.rankedAdmissibleTokens(
            logits: [1, 4, 3, 2], profile: profile, admissibleTokenIDs: nil, topK: 2)
        XCTAssertEqual(ranked, [1, 2])
    }

    // MARK: - search

    func test_search_widthOne_takesTheHighestLogitToken() {
        let profile = makeProfile(byteStrings: ["a", "b"])
        let result = ConstrainedBeamSearch.search(
            nextLogits: provider(vocabSize: 2, rows: [[]: row([0: 2, 1: 1], vocabSize: 2)]),
            profile: profile,
            configuration: BeamSearchConfiguration(beamWidth: 1, maxTokens: 1, topK: 5),
            isSingleLine: false)

        XCTAssertEqual(result.first?.text, "a")
        XCTAssertEqual(result.first?.tokenIDs, [0])
    }

    func test_search_stopsOnEndOfGenerationToken() {
        // Token 2 is EOG with non-empty bytes (so it is not masked as a control token). When it is the
        // chosen next token, the branch completes without emitting it. (Real EOG tokens render empty
        // and are excluded like any control token; this drives the EOG branch directly.)
        let profile = makeProfile(byteStrings: ["a", "b", "Z"], eog: [2])
        let result = ConstrainedBeamSearch.search(
            nextLogits: provider(vocabSize: 3, rows: [
                []: row([0: 5], vocabSize: 3),
                [0]: row([2: 9], vocabSize: 3)
            ]),
            profile: profile,
            configuration: BeamSearchConfiguration(beamWidth: 1, maxTokens: 4, topK: 2),
            isSingleLine: false)

        XCTAssertEqual(result.first?.text, "a")
        XCTAssertEqual(result.first?.tokenIDs, [0])
    }

    func test_search_widerBeamExploresASecondBestFirstTokenThatGreedyMisses() {
        // 0="A" (best first), 1="B" (second). Each leads to a continuation that ends a sentence, so the
        // branches complete cleanly. Greedy only follows "A"; a width-2 beam also reaches "By.".
        let profile = makeProfile(byteStrings: ["A", "B", "x.", "y."])
        let rows: [[Int]: [Float]] = [
            []: row([0: 5, 1: 4], vocabSize: 4),
            [0]: row([2: 9], vocabSize: 4),
            [1]: row([3: 9], vocabSize: 4)
        ]
        let greedy = ConstrainedBeamSearch.search(
            nextLogits: provider(vocabSize: 4, rows: rows), profile: profile,
            configuration: BeamSearchConfiguration(beamWidth: 1, maxTokens: 4, topK: 2),
            isSingleLine: false)
        let beam = ConstrainedBeamSearch.search(
            nextLogits: provider(vocabSize: 4, rows: rows), profile: profile,
            configuration: BeamSearchConfiguration(beamWidth: 2, maxTokens: 4, topK: 2),
            isSingleLine: false)

        XCTAssertFalse(greedy.map(\.text).contains("By."), "greedy only explores the best first token")
        XCTAssertTrue(beam.map(\.text).contains("By."), "a width-2 beam also explores the second-best first token")
    }

    func test_search_doesNotEmitNewlineInSingleLineField() {
        // token 0 is a newline, token 1 is "a". In a single-line field the newline ends a branch
        // without being emitted.
        let profile = makeProfile(byteStrings: ["\n", "a"])
        let result = ConstrainedBeamSearch.search(
            nextLogits: provider(vocabSize: 2, rows: [[]: row([0: 5, 1: 4], vocabSize: 2)]),
            profile: profile,
            configuration: BeamSearchConfiguration(beamWidth: 2, maxTokens: 1, topK: 5),
            isSingleLine: true)

        XCTAssertEqual(result.first?.text, "a")
        XCTAssertFalse(result.contains { $0.text.contains("\n") })
    }

    func test_search_stopsAtSentenceBoundaryAndDoesNotGenerateFurther() {
        // 0="Done", 1=".", 2="More". The completion should stop after the period and never step past.
        let profile = makeProfile(byteStrings: ["Done", ".", "More"])
        let recorder = PathRecorder()
        let result = ConstrainedBeamSearch.search(
            nextLogits: provider(vocabSize: 3, rows: [
                []: row([0: 5], vocabSize: 3),
                [0]: row([1: 5], vocabSize: 3),
                [0, 1]: row([2: 5], vocabSize: 3)
            ], recorder: recorder),
            profile: profile,
            configuration: BeamSearchConfiguration(beamWidth: 1, maxTokens: 6, topK: 5),
            isSingleLine: false)

        XCTAssertEqual(result.first?.text, "Done.")
        XCTAssertFalse(recorder.paths.contains([0, 1]), "search must stop at the sentence and not step past it")
    }

    func test_search_midWord_firstTokenMustContinueTheWord() {
        // token 0 breaks the word (leading punctuation) but has the higher logit; token 1 continues it.
        // Mid-word, only a word-continuing token may start the completion.
        let profile = makeProfile(byteStrings: [", and", "ing"])
        let rows: [[Int]: [Float]] = [[]: row([0: 9, 1: 1], vocabSize: 2)]
        let normal = ConstrainedBeamSearch.search(
            nextLogits: provider(vocabSize: 2, rows: rows), profile: profile,
            configuration: BeamSearchConfiguration(beamWidth: 1, maxTokens: 1, topK: 5),
            isSingleLine: false, isMidWord: false)
        let midWord = ConstrainedBeamSearch.search(
            nextLogits: provider(vocabSize: 2, rows: rows), profile: profile,
            configuration: BeamSearchConfiguration(beamWidth: 1, maxTokens: 1, topK: 5),
            isSingleLine: false, isMidWord: true)

        XCTAssertEqual(normal.first?.tokenIDs, [0], "without mid-word, the highest-logit token wins")
        XCTAssertEqual(midWord.first?.tokenIDs, [1], "mid-word, the word-breaking token is filtered out")
    }

    func test_search_respectsMaxTokenBudget() {
        // No EOG / sentence end: every token keeps generating, so the budget bounds the length.
        let profile = makeProfile(byteStrings: ["a", "b"])
        let result = ConstrainedBeamSearch.search(
            nextLogits: provider(vocabSize: 2, rows: [:]),  // unmapped -> uniform low logits
            profile: profile,
            configuration: BeamSearchConfiguration(beamWidth: 1, maxTokens: 2, topK: 2),
            isSingleLine: false)

        XCTAssertEqual(result.first?.tokenIDs.count, 2)
    }

    // MARK: - Required prefix

    func test_search_requiredPrefix_steersOntoLowLogitRequiredToken() {
        // 0="a", 1="b", 2="z". The model strongly prefers "z" at every step, but a required prefix of
        // "ab" must force "a" then "b" even though both rank far below "z".
        let profile = makeProfile(byteStrings: ["a", "b", "z"])
        let rows: [[Int]: [Float]] = [
            []: row([2: 9, 0: 1], vocabSize: 3),
            [0]: row([2: 9, 1: 1], vocabSize: 3)
        ]
        let unconstrained = ConstrainedBeamSearch.search(
            nextLogits: provider(vocabSize: 3, rows: rows), profile: profile,
            configuration: BeamSearchConfiguration(beamWidth: 1, maxTokens: 2, topK: 5),
            isSingleLine: false)
        let constrained = ConstrainedBeamSearch.search(
            nextLogits: provider(vocabSize: 3, rows: rows), profile: profile,
            configuration: BeamSearchConfiguration(beamWidth: 1, maxTokens: 2, topK: 5),
            isSingleLine: false, requiredPrefix: Array("ab".utf8))

        XCTAssertEqual(unconstrained.first?.text.hasPrefix("z"), true, "unconstrained follows the model's preference")
        XCTAssertEqual(constrained.first?.text, "ab", "the required prefix overrides the model's preference")
    }

    func test_search_requiredPrefix_doesNotStopBeforePrefixIsSatisfied() {
        // 0="a", 1="." (EOG, non-empty bytes), 2="b". The model wants to stop immediately, but with a
        // required prefix of "ab" no returned completion may omit the prefix.
        let profile = makeProfile(byteStrings: ["a", ".", "b"], eog: [1])
        let rows: [[Int]: [Float]] = [
            []: row([1: 9, 0: 1], vocabSize: 3),
            [0]: row([1: 9, 2: 1], vocabSize: 3)
        ]
        let result = ConstrainedBeamSearch.search(
            nextLogits: provider(vocabSize: 3, rows: rows), profile: profile,
            configuration: BeamSearchConfiguration(beamWidth: 1, maxTokens: 3, topK: 5),
            isSingleLine: false, requiredPrefix: Array("ab".utf8))

        XCTAssertFalse(result.isEmpty, "the search still produces a completion")
        XCTAssertTrue(result.allSatisfy { $0.text.hasPrefix("ab") }, "no completion stopped before the prefix was met")
    }

    func test_search_requiredPrefix_spansTokensOfDifferingLengths() {
        // 0="a", 1="bc", 2="ab", 3="c", 4="z". A required prefix of "abc" can be reached either as
        // "ab"+"c" or "a"+"bc"; both must yield exactly "abc".
        let profile = makeProfile(byteStrings: ["a", "bc", "ab", "c", "z"])
        let rows: [[Int]: [Float]] = [
            []: row([4: 9, 2: 5, 0: 1], vocabSize: 5),
            [2]: row([3: 5], vocabSize: 5),
            [0]: row([1: 5], vocabSize: 5)
        ]
        let result = ConstrainedBeamSearch.search(
            nextLogits: provider(vocabSize: 5, rows: rows), profile: profile,
            configuration: BeamSearchConfiguration(beamWidth: 2, maxTokens: 2, topK: 5),
            isSingleLine: false, requiredPrefix: Array("abc".utf8))

        XCTAssertFalse(result.isEmpty)
        XCTAssertTrue(result.allSatisfy { $0.text == "abc" }, "every surviving branch reproduces the required prefix exactly")
    }
}
