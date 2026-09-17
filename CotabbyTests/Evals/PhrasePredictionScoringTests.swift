import XCTest

/// Measurement invariants run without inference in ordinary CI. These tests intentionally use
/// small counterexamples: a benchmark that accepts partial words or ignores suppressed results
/// can claim an improvement even when the user's actual next word gets harder to predict.
final class PhrasePredictionScoringTests: XCTestCase {
    func testCorpusHas1337UniqueBalancedPhrases() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "phrase-prediction-1337", withExtension: "json"))
        let corpus = try JSONDecoder().decode(PhrasePredictionCorpus.self, from: Data(contentsOf: url))
        try corpus.validate()
        for phrase in corpus.phrases {
            XCTAssertTrue(phrase.id.hasPrefix(phrase.category + "-"))
            let words = PhrasePredictionScorer.wordRanges(in: phrase.text)
            let checkpoints = PhrasePredictionScorer.checkpoints(for: phrase, mode: .word)
            XCTAssertEqual(checkpoints.count, words.count - 1)
            for checkpoint in checkpoints {
                XCTAssertTrue(phrase.text.hasPrefix(checkpoint.prefix + checkpoint.expectedWord))
            }
        }
    }

    func testInvalidCorpusFailsInsteadOfChangingDenominators() {
        let corpus = PhrasePredictionCorpus(version: 1, language: "en", provenance: "test", phrases: [phrase()])
        XCTAssertThrowsError(try corpus.validate())
    }

    func testWordReplayContainsOnlyPreviouslyTypedText() {
        let checkpoints = PhrasePredictionScorer.checkpoints(for: phrase("Please send it."), mode: .word)
        XCTAssertEqual(checkpoints.map(\.prefix), ["Please ", "Please send "])
        XCTAssertEqual(checkpoints.map(\.expectedWord), ["send", "it"])
        XCTAssertEqual(checkpoints.map(\.wordIndex), [1, 2])
        XCTAssertEqual(checkpoints.map(\.typedCharacters), [0, 0])
    }

    func testCharacterReplayNeverScoresAnAlreadyCompleteWord() {
        let checkpoints = PhrasePredictionScorer.checkpoints(for: phrase("A cat naps."), mode: .character)
        XCTAssertEqual(checkpoints.map(\.prefix), ["A ", "A c", "A ca", "A cat ", "A cat n", "A cat na", "A cat nap"])
        XCTAssertEqual(checkpoints.map(\.typedWordPrefix), ["", "c", "ca", "", "n", "na", "nap"])
        XCTAssertEqual(checkpoints.filter { $0.typedCharacters == 0 }.count, 2)
    }

    func testExactFirstWordIgnoresCaseAndTerminalPunctuationButNotOtherWords() {
        let point = checkpoint(expected: "cat")
        XCTAssertTrue(PhrasePredictionScorer.isCorrect(shown: "CAT, sleeping", at: point))
        XCTAssertTrue(PhrasePredictionScorer.isCorrect(shown: " cat.", at: point))
        for wrong in ["catalog", "cats", "ca", "dog cat", "cat's", "cat-like", "cat-", "cat'", ". cat", ""] {
            XCTAssertFalse(PhrasePredictionScorer.isCorrect(shown: wrong, at: point), wrong)
        }
        XCTAssertFalse(PhrasePredictionScorer.isCorrect(shown: nil, at: point))
    }

    func testMidwordOutputMustJoinAtTheCaret() {
        let point = checkpoint(expected: "schedule", typed: "sched")
        XCTAssertTrue(PhrasePredictionScorer.isCorrect(shown: "ule for tomorrow", at: point))
        for wrong in [" ule", "ul", "schedule", "ules", "ule's", "\nule", ".ule"] {
            XCTAssertFalse(PhrasePredictionScorer.isCorrect(shown: wrong, at: point), wrong)
        }
    }

    func testContractionsHyphensNumbersAndUnicodeRemainWholeWords() {
        let text = "We don't need twenty-one café tables in 2026."
        let words = PhrasePredictionScorer.wordRanges(in: text).map { String(text[$0]) }
        XCTAssertEqual(words, ["We", "don't", "need", "twenty-one", "café", "tables", "in", "2026"])
        XCTAssertTrue(PhrasePredictionScorer.isCorrect(shown: "DON’T worry", at: checkpoint(expected: "don't")))
        XCTAssertFalse(PhrasePredictionScorer.isCorrect(shown: "dont", at: checkpoint(expected: "don't")))
        XCTAssertFalse(PhrasePredictionScorer.isCorrect(shown: "twenty one", at: checkpoint(expected: "twenty-one")))
        XCTAssertTrue(PhrasePredictionScorer.isCorrect(shown: "cafe\u{301}", at: checkpoint(expected: "café")))
    }

    func testReplayPreservesPunctuationAndNewlinesInPrefixes() {
        let checkpoints = PhrasePredictionScorer.checkpoints(for: phrase("Hi,\nplease don't go."), mode: .word)
        XCTAssertEqual(checkpoints.map(\.prefix), ["Hi,\n", "Hi,\nplease ", "Hi,\nplease don't "])
    }

    func testSuppressionAndFailuresCannotImproveAccuracy() {
        let observations = [observation("cat"), observation("dog"), observation(nil), observation(nil, error: "load failed")]
        let metrics = PhrasePredictionMetrics(observations)
        XCTAssertEqual(metrics.checkpoints, 4)
        XCTAssertEqual(metrics.correct, 1)
        XCTAssertEqual(metrics.errors, 1)
        XCTAssertEqual(metrics.accuracy, 0.25)
        XCTAssertEqual(metrics.coverage, 0.5)
        XCTAssertEqual(metrics.precisionWhenShown, 0.5)
        XCTAssertNil(PhrasePredictionMetrics([observation(nil)]).precisionWhenShown)
    }

    func testEmptyMetricsAndUnavailableLatenciesAreNotInventedZeros() {
        let empty = PhrasePredictionMetrics([])
        XCTAssertNil(empty.accuracy)
        XCTAssertNil(empty.latencyP50Milliseconds)
        let gated = PhrasePredictionObservation(checkpoint: checkpoint(), raw: "", shown: nil,
                                              suppression: "pre-generation-gate", latencyMilliseconds: 0, error: nil)
        XCTAssertNil(PhrasePredictionMetrics([gated]).latencyP50Milliseconds)
        let measured = PhrasePredictionMetrics([observation("cat", latency: 100), observation(nil, latency: 300)])
        XCTAssertEqual(measured.latencyP50Milliseconds, 100)
        XCTAssertEqual(measured.latencyP95Milliseconds, 300)
    }

    func testHierarchicalReportsKeepMicroMacroAndCharacterScoresSeparate() throws {
        let results = [
            PhrasePredictionReport.PhraseResult(phrase: phrase(), observations: [observation("cat")]),
            PhrasePredictionReport.PhraseResult(phrase: .init(id: "b", category: "science", text: "The cat naps."),
                observations: [observation(nil), observation(nil), observation(nil), observation("at", typed: "c")])
        ]
        let report = PhrasePredictionReport(metadata: metadata(), phrases: results)
        XCTAssertEqual(report.suite.nextWord.accuracy, 0.25)
        XCTAssertEqual(report.suite.all.accuracy, 0.4)
        XCTAssertEqual(report.suite.meanPhraseNextWordAccuracy, 0.5)
        XCTAssertEqual(report.meanCategoryNextWordAccuracy, 0.5)
        XCTAssertEqual(report.categories["science"]?.nextWord.accuracy, 0)
        XCTAssertEqual(report.phrases.first?.nextWord.accuracy, 1)
        let decoded = try JSONDecoder().decode(PhrasePredictionReport.self, from: JSONEncoder().encode(report))
        XCTAssertEqual(decoded.suite.nextWord.correct, 1)
        XCTAssertEqual(decoded.metadata.mode, .character)
        XCTAssertEqual(decoded.phrases[1].observations.last?.shown, "at")
        XCTAssertTrue(decoded.rendered().contains("25.00%"))
    }

    private func phrase(_ text: String = "The cat naps.") -> PhrasePredictionCorpus.Phrase {
        .init(id: "a", category: "conversation", text: text)
    }

    private func checkpoint(expected: String = "cat", typed: String = "") -> PhrasePredictionScorer.Checkpoint {
        .init(wordIndex: 1, typedCharacters: typed.count, prefix: "The " + typed, typedWordPrefix: typed, expectedWord: expected)
    }

    private func observation(_ shown: String?, typed: String = "", latency: Double = 100, error: String? = nil) -> PhrasePredictionObservation {
        .init(checkpoint: checkpoint(typed: typed), raw: shown ?? "", shown: shown, suppression: nil, latencyMilliseconds: latency, error: error)
    }

    private func metadata() -> PhrasePredictionReport.Metadata {
        .init(corpusSHA256: "test", corpusVersion: 1, model: "test.gguf", seed: 42,
              mode: .character, configuration: [:], runLabel: "unit test")
    }
}
