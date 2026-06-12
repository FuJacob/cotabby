import XCTest
@testable import Cotabby

/// CI-runnable coverage for the eval's pure scoring layer (no model needed): the matcher rules,
/// the outcome taxonomy, and the dataset's structural invariants. Loading the dataset here also
/// proves the JSON resource actually ships in the test bundle, so the gated model run cannot
/// silently skip because of a packaging regression.
final class LlamaEvalScoringTests: XCTestCase {
    // MARK: - Matcher

    func testShownExtendingReferenceMatches() {
        XCTAssertTrue(LlamaEvalScorer.matches(shown: "revised proposal by Friday", acceptable: ["revised proposal"]))
    }

    func testShownStoppingEarlyInsideReferenceMatches() {
        XCTAssertTrue(LlamaEvalScorer.matches(shown: "revised", acceptable: ["revised proposal"]))
    }

    func testDifferentFirstWordDoesNotMatch() {
        XCTAssertFalse(LlamaEvalScorer.matches(shown: "the proposal", acceptable: ["revised proposal"]))
    }

    func testCaseAndPunctuationAreFolded() {
        XCTAssertTrue(LlamaEvalScorer.matches(shown: "Revised Proposal.", acceptable: ["revised proposal"]))
    }

    func testWhitespaceIsCollapsed() {
        XCTAssertTrue(LlamaEvalScorer.matches(shown: "revised   proposal", acceptable: ["revised proposal"]))
    }

    func testSingleASCIIWordsRequireExactEquality() {
        XCTAssertTrue(LlamaEvalScorer.matches(shown: "regards", acceptable: ["regards"]))
        XCTAssertFalse(LlamaEvalScorer.matches(shown: "regard", acceptable: ["regards"]))
    }

    func testCJKMatchesOnCharacterPrefix() {
        XCTAssertTrue(LlamaEvalScorer.matches(shown: "散歩に行きたい", acceptable: ["散歩"]))
        XCTAssertFalse(LlamaEvalScorer.matches(shown: "映画を見たい", acceptable: ["散歩"]))
    }

    func testAnyAcceptableCanMatch() {
        XCTAssertTrue(LlamaEvalScorer.matches(shown: "Thursday works", acceptable: ["Wednesday", "Thursday"]))
    }

    func testEmptyShownNeverMatches() {
        XCTAssertFalse(LlamaEvalScorer.matches(shown: "  ", acceptable: ["anything"]))
    }

    // MARK: - Outcomes

    private func positiveCase(mustShow: Bool = false, acceptable: [String] = ["next steps"]) -> LlamaEvalCase {
        LlamaEvalCase(
            id: "p", tags: ["t"], precedingText: "send the ",
            expectation: .init(kind: .positive, mustShow: mustShow, acceptable: acceptable)
        )
    }

    func testPositiveShownMatchingIsCorrectInsert() {
        XCTAssertEqual(
            LlamaEvalScorer.outcome(shownText: "next steps soon", for: positiveCase()),
            .correctInsert
        )
    }

    func testPositiveShownMismatchIsWrongShown() {
        XCTAssertEqual(
            LlamaEvalScorer.outcome(shownText: "elephants dancing", for: positiveCase()),
            .wrongShown
        )
    }

    func testPositiveSuppressedIsAcceptableSuppression() {
        XCTAssertEqual(LlamaEvalScorer.outcome(shownText: nil, for: positiveCase()), .acceptableSuppression)
    }

    func testMustShowSuppressedIsMissedShow() {
        XCTAssertEqual(
            LlamaEvalScorer.outcome(shownText: nil, for: positiveCase(mustShow: true)),
            .missedShow
        )
    }

    func testNegativeSuppressedIsCorrectSuppression() {
        let negative = LlamaEvalCase(
            id: "n", tags: ["t"], precedingText: "asdf ",
            expectation: .init(kind: .negative, reason: "gibberish")
        )
        XCTAssertEqual(LlamaEvalScorer.outcome(shownText: nil, for: negative), .correctSuppression)
        XCTAssertEqual(LlamaEvalScorer.outcome(shownText: "anything", for: negative), .wrongShown)
    }

    func testForbiddenJudgesOnlyTheForbiddenSubstrings() {
        let forbidden = LlamaEvalCase(
            id: "f", tags: ["t"], precedingText: "notes ",
            expectation: .init(kind: .forbidden, forbidden: ["<|im_end|>"])
        )
        XCTAssertEqual(LlamaEvalScorer.outcome(shownText: "ten seconds", for: forbidden), .correctInsert)
        XCTAssertEqual(LlamaEvalScorer.outcome(shownText: "ok<|im_end|>", for: forbidden), .wrongShown)
        XCTAssertEqual(LlamaEvalScorer.outcome(shownText: nil, for: forbidden), .correctSuppression)
    }

    func testScoresMatchTheNonNegativeTaxonomy() {
        XCTAssertEqual(LlamaEvalOutcome.correctInsert.score, 1.0)
        XCTAssertEqual(LlamaEvalOutcome.correctSuppression.score, 1.0)
        XCTAssertEqual(LlamaEvalOutcome.acceptableSuppression.score, 0.3)
        XCTAssertEqual(LlamaEvalOutcome.wrongShown.score, 0.0)
        XCTAssertEqual(LlamaEvalOutcome.missedShow.score, 0.0)
    }

    // MARK: - Dataset invariants

    private func loadDataset() throws -> [LlamaEvalCase] {
        let url = try XCTUnwrap(
            Bundle(for: LlamaEvalScoringTests.self)
                .url(forResource: "llama-eval-cases", withExtension: "json"),
            "llama-eval-cases.json must ship in the test bundle"
        )
        return try LlamaEvalCase.loadDataset(from: url)
    }

    func testDatasetLoadsAndHasUniqueIDs() throws {
        let cases = try loadDataset()
        XCTAssertGreaterThanOrEqual(cases.count, 100)
        XCTAssertEqual(Set(cases.map(\.id)).count, cases.count, "case ids must be unique")
    }

    func testDatasetExpectationsAreWellFormed() throws {
        for evalCase in try loadDataset() {
            XCTAssertFalse(evalCase.tags.isEmpty, "\(evalCase.id) has no tags")
            switch evalCase.expectation.kind {
            case .positive:
                XCTAssertFalse(
                    evalCase.expectation.acceptable.isEmpty,
                    "\(evalCase.id) is positive but lists no acceptable continuations"
                )
            case .negative:
                XCTAssertNotNil(evalCase.expectation.reason, "\(evalCase.id) negative needs a reason")
            case .forbidden:
                XCTAssertFalse(
                    evalCase.expectation.forbidden.isEmpty,
                    "\(evalCase.id) is forbidden-kind but lists no forbidden substrings"
                )
            }
        }
    }

    func testDatasetCoversTheCoreTags() throws {
        let tags = Set(try loadDataset().flatMap(\.tags))
        for required in ["email", "chat", "prose", "code", "cjk", "midword", "negative", "scaffolding"] {
            XCTAssertTrue(tags.contains(required), "dataset lost its \(required) coverage")
        }
    }

    // MARK: - Report aggregation

    func testReportMetrics() {
        let shown = LlamaEvalCaseResult(
            evalCase: positiveCase(), shownText: "next steps", rawText: "next steps",
            outcome: .correctInsert, suppressionStage: nil, latencySeconds: 0.1
        )
        let wrong = LlamaEvalCaseResult(
            evalCase: positiveCase(), shownText: "garbage", rawText: "garbage",
            outcome: .wrongShown, suppressionStage: nil, latencySeconds: 0.3
        )
        let suppressed = LlamaEvalCaseResult(
            evalCase: positiveCase(), shownText: nil, rawText: "",
            outcome: .acceptableSuppression, suppressionStage: "normalizer", latencySeconds: 0.2
        )
        let report = LlamaEvalReport(modelLabel: "test", results: [shown, wrong, suppressed])

        XCTAssertEqual(report.shownCount, 2)
        XCTAssertEqual(report.precisionWhenShown, 0.5, accuracy: 0.0001)
        XCTAssertEqual(report.wrongShowRate, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(report.positiveCoverage, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(report.qualityScore, (1.0 + 0.0 + 0.3) / 3.0, accuracy: 0.0001)
        XCTAssertEqual(report.latencyPercentile(0.5), 0.2, accuracy: 0.0001)
        XCTAssertFalse(report.rendered().isEmpty)
    }
}
