import XCTest
@testable import Cotabby

/// CI-runnable coverage for the eval's pure scoring layer (no model needed): the matcher rules,
/// the outcome taxonomy, report aggregation, and the dataset's structural invariants. Loading the
/// dataset here also proves the JSON resource actually ships in the test bundle, so the gated
/// model run cannot silently skip because of a packaging regression.
final class LlamaEvalScoringTests: XCTestCase {
    // MARK: - Matcher

    func testMatcherAcceptsWordBoundaryPrefixesInEitherDirection() {
        let matches: [(shown: String, acceptable: [String], why: String)] = [
            ("revised proposal by Friday", ["revised proposal"], "shown extends the reference"),
            ("revised", ["revised proposal"], "shown stops early inside the reference"),
            ("Revised Proposal.", ["revised proposal"], "case and punctuation fold"),
            ("revised   proposal", ["revised proposal"], "whitespace collapses"),
            ("don't forget", ["dont forget"], "punctuation folds out of words"),
            ("regards", ["regards"], "identical single ASCII word"),
            ("散歩に行きたい", ["散歩"], "CJK run matches on a character prefix"),
            ("Thursday works", ["Wednesday", "Thursday"], "any acceptable reference may match")
        ]
        for example in matches {
            XCTAssertTrue(
                LlamaEvalScorer.matches(shown: example.shown, acceptable: example.acceptable),
                example.why
            )
        }
    }

    func testMatcherRejectsDifferentWordsAndDegenerateInputs() {
        let mismatches: [(shown: String, acceptable: [String], why: String)] = [
            ("the proposal", ["revised proposal"], "different first word"),
            ("regard", ["regards"], "single ASCII words need exact equality, not a prefix"),
            ("映画を見たい", ["散歩"], "different CJK run"),
            ("散", ["散歩"], "a one-character CJK overlap is below the two-character floor"),
            ("  ", ["anything"], "whitespace-only shown text"),
            ("...", ["anything"], "punctuation-only shown text folds to no words"),
            ("revised proposal", ["!!!"], "punctuation-only reference folds to no words"),
            ("anything", [], "no acceptable references")
        ]
        for example in mismatches {
            XCTAssertFalse(
                LlamaEvalScorer.matches(shown: example.shown, acceptable: example.acceptable),
                example.why
            )
        }
    }

    // MARK: - Outcomes

    func testPositiveOutcomes() {
        XCTAssertEqual(LlamaEvalScorer.outcome(shownText: "next steps soon", for: positiveCase()), .correctInsert)
        XCTAssertEqual(LlamaEvalScorer.outcome(shownText: "elephants dancing", for: positiveCase()), .wrongShown)
        XCTAssertEqual(LlamaEvalScorer.outcome(shownText: nil, for: positiveCase()), .acceptableSuppression)
        XCTAssertEqual(LlamaEvalScorer.outcome(shownText: nil, for: positiveCase(mustShow: true)), .missedShow)
    }

    func testPositiveEmptyShownTextCountsAsSuppression() {
        XCTAssertEqual(LlamaEvalScorer.outcome(shownText: "", for: positiveCase()), .acceptableSuppression)
        XCTAssertEqual(LlamaEvalScorer.outcome(shownText: "", for: positiveCase(mustShow: true)), .missedShow)
    }

    func testPositiveWithoutReferencesScoresAnyShownTextAsWrong() {
        XCTAssertEqual(LlamaEvalScorer.outcome(shownText: "next steps", for: positiveCase(acceptable: [])), .wrongShown)
    }

    func testNegativeRewardsOnlySuppression() {
        let negative = LlamaEvalCase(
            id: "n", tags: ["t"], precedingText: "asdf ",
            expectation: .init(kind: .negative, reason: "gibberish")
        )
        XCTAssertEqual(LlamaEvalScorer.outcome(shownText: nil, for: negative), .correctSuppression)
        XCTAssertEqual(LlamaEvalScorer.outcome(shownText: "anything", for: negative), .wrongShown)
    }

    func testForbiddenJudgesOnlyTheForbiddenSubstringsCaseInsensitively() {
        let forbidden = forbiddenCase(["<|im_end|>", "Regards"])
        XCTAssertEqual(LlamaEvalScorer.outcome(shownText: "ten seconds", for: forbidden), .correctInsert)
        XCTAssertEqual(LlamaEvalScorer.outcome(shownText: "ok<|im_end|>", for: forbidden), .wrongShown)
        XCTAssertEqual(LlamaEvalScorer.outcome(shownText: "Best REGARDS", for: forbidden), .wrongShown)
        XCTAssertEqual(LlamaEvalScorer.outcome(shownText: nil, for: forbidden), .correctSuppression)
        XCTAssertEqual(LlamaEvalScorer.outcome(shownText: "anything", for: forbiddenCase([])), .correctInsert)
    }

    func testScoresMatchTheNonNegativeTaxonomy() {
        XCTAssertEqual(LlamaEvalOutcome.correctInsert.score, 1.0)
        XCTAssertEqual(LlamaEvalOutcome.correctSuppression.score, 1.0)
        XCTAssertEqual(LlamaEvalOutcome.acceptableSuppression.score, 0.3)
        XCTAssertEqual(LlamaEvalOutcome.wrongShown.score, 0.0)
        XCTAssertEqual(LlamaEvalOutcome.missedShow.score, 0.0)
    }

    // MARK: - Decoding

    func testDecodingFillsOptionalFieldsWithDefaults() throws {
        let json = #"[{"id":"x","tags":["t"],"precedingText":"Hi ","expectation":{"kind":"positive"}}]"#
        let decoded = try XCTUnwrap(JSONDecoder().decode([LlamaEvalCase].self, from: Data(json.utf8)).first)
        XCTAssertEqual(decoded.applicationName, "TestApp")
        XCTAssertEqual(decoded.bundleIdentifier, "com.example.TestApp")
        XCTAssertEqual(decoded.trailingText, "")
        XCTAssertTrue(decoded.isMultiLineEnabled)
        XCTAssertEqual(decoded.expectation, LlamaEvalExpectation(kind: .positive))
    }

    func testDecodingRejectsUnknownExpectationKind() {
        let json = #"{"kind":"maybe"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(LlamaEvalExpectation.self, from: Data(json.utf8)))
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
            case .recall:
                XCTAssertFalse(
                    evalCase.expectation.mustContain.isEmpty,
                    "\(evalCase.id) is recall-kind but lists nothing it must contain"
                )
            }
        }
    }

    // MARK: - Recall dataset invariants

    private func loadRecallDataset() throws -> [LlamaEvalCase] {
        let url = try XCTUnwrap(
            Bundle(for: LlamaEvalScoringTests.self)
                .url(forResource: "llama-recall-cases", withExtension: "json"),
            "llama-recall-cases.json must ship in the test bundle"
        )
        return try LlamaEvalCase.loadDataset(from: url)
    }

    func testRecallDatasetLoadsAndHasUniqueIDs() throws {
        let cases = try loadRecallDataset()
        XCTAssertGreaterThanOrEqual(cases.count, 20)
        XCTAssertEqual(Set(cases.map(\.id)).count, cases.count, "recall case ids must be unique")
        XCTAssertTrue(
            cases.allSatisfy { $0.expectation.kind == .recall },
            "every case in the recall dataset must use the recall expectation kind"
        )
    }

    /// The invariant that makes this suite a recall test rather than a guessing test: whatever the
    /// completion is required to reproduce has to be present in the context the model is given.
    /// Without this, a case could silently drift into demanding a fact the model was never told,
    /// and a "failure" would really be a demand to hallucinate.
    func testRecallFactsAreActuallyPresentInTheContext() throws {
        for evalCase in try loadRecallDataset() {
            let context = [
                evalCase.precedingText,
                evalCase.visualContextSummary ?? "",
                evalCase.clipboardContext ?? ""
            ].joined(separator: " ")
            for fact in evalCase.expectation.mustContain {
                XCTAssertTrue(
                    LlamaEvalScorer.containsAll(shown: context, required: [fact]),
                    "\(evalCase.id) requires '\(fact)' but no part of its context contains it"
                )
            }
        }
    }

    func testRecallDatasetCoversEveryContextSource() throws {
        let tags = Set(try loadRecallDataset().flatMap(\.tags))
        for required in ["screen", "field", "field-long", "overflow", "clipboard"] {
            XCTAssertTrue(tags.contains(required), "recall dataset lost its \(required) coverage")
        }
    }

    func testDatasetCoversTheCoreTags() throws {
        let tags = Set(try loadDataset().flatMap(\.tags))
        for required in ["email", "chat", "prose", "code", "cjk", "midword", "negative", "scaffolding"] {
            XCTAssertTrue(tags.contains(required), "dataset lost its \(required) coverage")
        }
    }

    // MARK: - Report aggregation

    /// Three positives: one correct insert, one wrong show, one acceptable suppression.
    private func mixedReport() -> LlamaEvalReport {
        LlamaEvalReport(modelLabel: "test", results: [
            result(positiveCase(id: "hit", tags: ["email"]), shown: "next steps", latency: 0.1),
            result(positiveCase(id: "miss", tags: ["email", "chat"]), shown: "garbage", latency: 0.3),
            result(positiveCase(id: "quiet", tags: ["chat"]), shown: nil, stage: "normalizer", latency: 0.2)
        ])
    }

    func testReportMetrics() {
        let report = mixedReport()
        XCTAssertEqual(report.shownCount, 2)
        XCTAssertEqual(report.precisionWhenShown, 0.5, accuracy: 0.0001)
        XCTAssertEqual(report.wrongShowRate, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(report.positiveCoverage, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(report.qualityScore, (1.0 + 0.0 + 0.3) / 3.0, accuracy: 0.0001)
        XCTAssertEqual(report.latencyPercentile(0.5), 0.2, accuracy: 0.0001)
    }

    func testPositiveCoverageIgnoresNonPositiveCases() {
        let negative = LlamaEvalCase(
            id: "n", tags: ["t"], precedingText: "asdf ",
            expectation: .init(kind: .negative, reason: "gibberish")
        )
        let report = LlamaEvalReport(modelLabel: "test", results: [
            result(positiveCase(), shown: "next steps", latency: 0.1),
            result(negative, shown: "oops", latency: 0.1)
        ])
        XCTAssertEqual(report.positiveCoverage, 1.0)
        XCTAssertEqual(report.shownCount, 2)
        XCTAssertEqual(report.precisionWhenShown, 0.5)
    }

    func testEmptyReportAggregatesToZeroInsteadOfNaN() throws {
        let report = LlamaEvalReport(modelLabel: "empty", results: [])
        XCTAssertEqual(report.qualityScore, 0)
        XCTAssertEqual(report.precisionWhenShown, 0)
        XCTAssertEqual(report.wrongShowRate, 0)
        XCTAssertEqual(report.positiveCoverage, 0)
        XCTAssertEqual(report.latencyPercentile(0.95), 0)
        XCTAssertTrue(report.rendered().hasPrefix("=== Llama suggestion eval: empty — 0 cases ==="))
        // JSONSerialization throws on NaN, so producing the artifact proves every ratio is guarded.
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: report.jsonArtifact()) as? [String: Any])
        XCTAssertEqual(object["caseCount"] as? Int, 0)
        XCTAssertEqual((object["cases"] as? [Any])?.count, 0)
    }

    func testLatencyPercentileUsesRoundedNearestRank() {
        let report = LlamaEvalReport(modelLabel: "test", results: [0.4, 0.1, 0.3, 0.2].map {
            result(positiveCase(), shown: nil, latency: $0)
        })
        XCTAssertEqual(report.latencyPercentile(0), 0.1, accuracy: 0.0001)
        // Rank (4 - 1) * 0.5 = 1.5 rounds away from zero to index 2.
        XCTAssertEqual(report.latencyPercentile(0.5), 0.3, accuracy: 0.0001)
        XCTAssertEqual(report.latencyPercentile(0.95), 0.4, accuracy: 0.0001)
        XCTAssertEqual(report.latencyPercentile(1), 0.4, accuracy: 0.0001)
    }

    func testRenderedReportListsHeadlineOutcomesTagsAndFailures() {
        let lines = mixedReport().rendered().components(separatedBy: "\n")
        XCTAssertEqual(lines, [
            "=== Llama suggestion eval: test — 3 cases ===",
            "qualityScore 0.433 | precisionWhenShown 0.500 | positiveCoverage 0.667 | wrongShowRate 0.333 | shown 2/3",
            "latency p50 200ms p95 300ms max 300ms",
            "outcomes: correctInsert 1 | acceptableSuppression 1 | wrongShown 1",
            "  [chat] n=2 score 0.150 wrongShown 1",
            "  [email] n=2 score 0.500 wrongShown 1",
            "  !! wrongShown miss: \"garbage\""
        ])
    }

    func testRenderedReportMarksMissedShowAsSuppressed() {
        let report = LlamaEvalReport(modelLabel: "test", results: [
            result(positiveCase(id: "must", mustShow: true), shown: nil, latency: 0.1)
        ])
        XCTAssertTrue(report.rendered().hasSuffix("  !! missedShow must: \"<suppressed>\""))
    }

    func testJSONArtifactCarriesAggregatesAndPerCaseDetail() throws {
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: mixedReport().jsonArtifact()) as? [String: Any]
        )
        XCTAssertEqual(object["model"] as? String, "test")
        XCTAssertEqual(object["caseCount"] as? Int, 3)
        XCTAssertEqual(try XCTUnwrap(object["latencyMaxMs"] as? Double), 300, accuracy: 0.001)
        let cases = try XCTUnwrap(object["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.map { $0["id"] as? String }, ["hit", "miss", "quiet"])
        XCTAssertEqual(cases.map { $0["outcome"] as? String }, ["correctInsert", "wrongShown", "acceptableSuppression"])
        XCTAssertTrue(cases[2]["shown"] is NSNull)
        XCTAssertEqual(cases[2]["suppressionStage"] as? String, "normalizer")
        XCTAssertTrue(cases[0]["suppressionStage"] is NSNull)
    }

    // MARK: - Helpers

    private func positiveCase(
        id: String = "p",
        tags: [String] = ["t"],
        mustShow: Bool = false,
        acceptable: [String] = ["next steps"]
    ) -> LlamaEvalCase {
        LlamaEvalCase(
            id: id, tags: tags, precedingText: "send the ",
            expectation: .init(kind: .positive, mustShow: mustShow, acceptable: acceptable)
        )
    }

    private func forbiddenCase(_ forbidden: [String]) -> LlamaEvalCase {
        LlamaEvalCase(
            id: "f", tags: ["t"], precedingText: "notes ",
            expectation: .init(kind: .forbidden, forbidden: forbidden)
        )
    }

    /// Builds a result whose outcome comes from the real scorer, so report fixtures cannot pair
    /// shown text with an outcome the scorer would never produce.
    private func result(
        _ evalCase: LlamaEvalCase,
        shown: String?,
        stage: String? = nil,
        latency: Double
    ) -> LlamaEvalCaseResult {
        LlamaEvalCaseResult(
            evalCase: evalCase,
            shownText: shown,
            rawText: shown ?? "",
            outcome: LlamaEvalScorer.outcome(shownText: shown, for: evalCase),
            suppressionStage: stage,
            latencySeconds: latency
        )
    }
}
