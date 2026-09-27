import XCTest

/// Measurement invariants run without inference in ordinary CI. These tests intentionally use
/// small counterexamples: a benchmark that accepts partial words or ignores suppressed results
/// can claim an improvement even when the user's actual next word gets harder to predict.
final class PhrasePredictionScoringTests: XCTestCase {
    func testWorkerShardsCoverTheSelectionExactlyOnceWithoutEmptyWorkers() throws {
        for count in [1, 2, 14, 1337] {
            for workers in 1...3 {
                let shards = try PhrasePredictionReplayPlan.shards(phraseCount: count, workers: workers)
                XCTAssertEqual(shards.count, min(count, workers))
                XCTAssertTrue(shards.allSatisfy { !$0.isEmpty })
                XCTAssertEqual(shards.flatMap { $0 }.sorted(), Array(0..<count))
                XCTAssertLessThanOrEqual((shards.map(\.count).max() ?? 0) - (shards.map(\.count).min() ?? 0), 1)
            }
        }
        XCTAssertThrowsError(try PhrasePredictionReplayPlan.shards(phraseCount: 0, workers: 3))
        XCTAssertThrowsError(try PhrasePredictionReplayPlan.shards(phraseCount: 1337, workers: 0))
        XCTAssertThrowsError(try PhrasePredictionReplayPlan.shards(phraseCount: 1337, workers: 4))
        XCTAssertEqual(try PhrasePredictionReplayPlan.shards(phraseCount: 5, workers: 2), [[0, 2, 4], [1, 3]])
        XCTAssertEqual(try PhrasePredictionReplayPlan.shards(phraseCount: 2, workers: 3), [[0], [1]])
    }

    func testPairedConditionOrderAlternatesByGlobalPhraseIndex() {
        XCTAssertEqual(PhrasePredictionReplayPlan.conditions(at: 0, mode: .paired), [.none, .screen])
        // Phrase 3 is the second item in worker 0's shard. Its global parity must stay odd.
        XCTAssertEqual(PhrasePredictionReplayPlan.conditions(at: 3, mode: .paired), [.screen, .none])
        XCTAssertEqual(PhrasePredictionReplayPlan.conditions(at: 1, mode: .none), [.none])
        XCTAssertEqual(PhrasePredictionReplayPlan.conditions(at: 1, mode: .screen), [.screen])
    }

    func testParallelCompletionOrderRestoresSerialIdentityInBothCheckpointModes() throws {
        let phrases = (0..<5).map {
            PhrasePredictionCorpus.Phrase(id: "conversation-\($0)", category: "conversation", text: "Please send it.")
        }
        for mode in [PhrasePredictionScorer.Mode.word, .character] {
            for context in [PhrasePredictionScorer.ContextMode.paired, .none, .screen] {
                let serial = phrases.enumerated().flatMap { index, phrase in
                    PhrasePredictionReplayPlan.conditions(at: index, mode: context).map { condition in
                        PhrasePredictionReport.PhraseResult(
                            phrase: phrase, observations: PhrasePredictionScorer.checkpoints(for: phrase, mode: mode).map {
                                PhrasePredictionObservation(checkpoint: $0, raw: "", shown: nil, suppression: "test",
                                                            latencyMilliseconds: 0, error: nil)
                            }, condition: condition
                        )
                    }
                }
                let restored = try PhrasePredictionReplayPlan.orderedResults(
                    Array(serial.reversed()), phrases: phrases, mode: mode, context: context
                )
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                XCTAssertEqual(try encoder.encode(restored), try encoder.encode(serial))
                XCTAssertThrowsError(try PhrasePredictionReplayPlan.orderedResults(
                    Array(serial.dropLast()), phrases: phrases, mode: mode, context: context
                ))
                var duplicate = serial
                duplicate[duplicate.count - 1] = serial[0]
                XCTAssertThrowsError(try PhrasePredictionReplayPlan.orderedResults(
                    duplicate, phrases: phrases, mode: mode, context: context
                ))
                var partial = serial
                partial[0] = .init(phrase: phrases[0], observations: [], condition: serial[0].condition)
                XCTAssertThrowsError(try PhrasePredictionReplayPlan.orderedResults(
                    partial, phrases: phrases, mode: mode, context: context
                ))
            }
        }
    }

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
                XCTAssertTrue(((phrase.scenario?.documentPrefix ?? "") + phrase.text).hasPrefix(checkpoint.prefix + checkpoint.expectedWord))
            }
        }
    }

    func testSmallWellFormedCorpusPassesNonCanonicalValidationOnly() {
        let small = corpus(validPhrases())
        XCTAssertNoThrow(try small.validate(canonical: false))
        assertInvalid(small, canonical: true, "Expected exactly 1337 phrases")
    }

    func testInvalidCorpusFailsInsteadOfChangingDenominators() {
        let valid = validPhrases()
        assertInvalid(PhrasePredictionCorpus(version: 1, language: "en", provenance: "test", phrases: valid),
                      "Unsupported corpus version or language")
        assertInvalid(PhrasePredictionCorpus(version: 2, language: "fr", provenance: "test", phrases: valid),
                      "Unsupported corpus version or language")
        assertInvalid(PhrasePredictionCorpus(version: 2, language: "en", provenance: "", phrases: valid),
                      "Corpus provenance is required")
        assertInvalid(corpus([]), "Empty corpus")
        assertInvalid(corpus([valid[0], scenePhrase(id: valid[0].id, text: "Another distinct sentence here.")]),
                      "Duplicate phrase IDs")
        // Text duplicates are detected after case folding and trimming.
        assertInvalid(corpus([valid[0], scenePhrase(id: "work-2", text: "PLEASE SEND IT.")]), "Duplicate phrase text")
        assertInvalid(corpus([scenePhrase(id: "sports-1", category: "sports", text: "Please send it.")]),
                      "Unexpected categories")
        let sharedScreen = scenePhrase(id: "work-2", text: "Another distinct sentence here.", screen: valid[0].scenario?.screenText ?? "")
        assertInvalid(corpus([valid[0], sharedScreen]), "Each phrase needs its own screen context")
        assertInvalid(corpus([scenePhrase(text: " Please send it.")]), "Untrimmed phrase")
        assertInvalid(corpus([scenePhrase(text: "Send it.")]), "Phrase needs at least three words")
        assertInvalid(corpus([scenePhrase(screen: "Too short to be a screen.")]), "Screen context outside fixture bounds")
    }

    func testCorpusRejectsAReferencePhraseVisibleOnScreen() {
        // Leak detection compares folded words, so case and punctuation cannot hide the answer.
        let leaked = scenePhrase(id: "work-1", text: "Please send it.",
                                 screen: "Morgan wrote: PLEASE send it, thanks for all of your help today.")
        assertInvalid(corpus([leaked]), "Complete reference phrase leaked into context: work-1")
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

    func testCharacterReplayStepsByGraphemeNotScalar() {
        let checkpoints = PhrasePredictionScorer.checkpoints(for: phrase("A cafe\u{301}"), mode: .character)
        XCTAssertEqual(checkpoints.map(\.typedWordPrefix), ["", "c", "ca", "caf"])
        XCTAssertEqual(checkpoints.map(\.expectedWord), Array(repeating: "cafe\u{301}", count: 4))
    }

    func testSingleWordPhraseHasNoScoredCheckpoints() {
        XCTAssertTrue(PhrasePredictionScorer.checkpoints(for: phrase("Hello."), mode: .word).isEmpty)
        XCTAssertTrue(PhrasePredictionScorer.checkpoints(for: phrase("Hello."), mode: .character).isEmpty)
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

    func testPredictedWordJoinsAtTheCaretAndPreservesCase() {
        XCTAssertEqual(PhrasePredictionScorer.predictedWord(shown: "ule for", at: checkpoint(expected: "schedule", typed: "sched")), "schedule")
        XCTAssertEqual(PhrasePredictionScorer.predictedWord(shown: " CAT, sleeping", at: checkpoint()), "CAT")
        XCTAssertNil(PhrasePredictionScorer.predictedWord(shown: nil, at: checkpoint()))
        XCTAssertNil(PhrasePredictionScorer.predictedWord(shown: " \n ", at: checkpoint()))
        // A trailing curly apostrophe means the word continues past the shown text.
        XCTAssertNil(PhrasePredictionScorer.predictedWord(shown: "cat\u{2019}", at: checkpoint()))
    }

    func testWordRangesSkipSymbolsAndKeepSpaceFreeScriptsTogether() {
        let text = "hi 👋 there, state-of-the-art don\u{2019}t --dash 東京に行く"
        let words = PhrasePredictionScorer.wordRanges(in: text).map { String(text[$0]) }
        XCTAssertEqual(words, ["hi", "there", "state-of-the-art", "don\u{2019}t", "dash", "東京に行く"])
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

    func testErroredObservationIsShownButNeverCorrect() {
        let errored = observation("cat", error: "decode failed")
        XCTAssertEqual(errored.predictedWord, "cat")
        XCTAssertTrue(errored.wasShown)
        XCTAssertFalse(errored.correct)
        XCTAssertFalse(observation("  ").wasShown)
    }

    func testMetricLatencyUsesCeilingNearestRankAndSkipsErrors() {
        let metrics = PhrasePredictionMetrics(
            [400.0, 100, 300, 200].map { observation("cat", latency: $0) } + [observation(nil, latency: 999, error: "x")]
        )
        // Nearest rank: ceil(4 * 0.5) = 2nd sample, ceil(4 * 0.95) = 4th sample.
        XCTAssertEqual(metrics.latencyP50Milliseconds, 200)
        XCTAssertEqual(metrics.latencyP95Milliseconds, 400)
        XCTAssertEqual(metrics.errors, 1)
    }

    func testEmptyMetricsAndUnavailableLatenciesAreNotInventedZeros() {
        let empty = PhrasePredictionMetrics([])
        XCTAssertNil(empty.accuracy)
        XCTAssertNil(empty.coverage)
        XCTAssertNil(empty.precisionWhenShown)
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

    func testEmptyReportRendersUnavailableScoresAsNA() {
        let report = PhrasePredictionReport(metadata: metadata(), phrases: [])
        XCTAssertEqual(report.primaryCondition, PhrasePredictionScorer.ContextCondition.none)
        XCTAssertNil(report.meanCategoryNextWordAccuracy)
        XCTAssertNil(report.contextLift)
        XCTAssertEqual(report.errorCount, 0)
        XCTAssertEqual(report.rendered().components(separatedBy: "\n"), [
            "SUITE (none): 0 phrases, next-word n/a (0/0), coverage n/a, precision n/a",
            "Equal-category next-word score: n/a",
            "All character checkpoints: n/a (separate from next-word score)"
        ])
    }

    func testPairedContextScoresDoNotMixDenominatorsAndRetainRegressions() throws {
        let other = PhrasePredictionCorpus.Phrase(id: "b", category: "science", text: "The cat sleeps.")
        let results = [
            PhrasePredictionReport.PhraseResult(phrase: phrase(), observations: [observation(nil), observation("cat")], condition: .none),
            PhrasePredictionReport.PhraseResult(phrase: phrase(), observations: [observation("cat"), observation(nil)], condition: .screen),
            PhrasePredictionReport.PhraseResult(phrase: other, observations: [observation(nil)], condition: .none),
            PhrasePredictionReport.PhraseResult(phrase: other, observations: [observation("cat")], condition: .screen)
        ]
        let report = PhrasePredictionReport(metadata: metadata(), phrases: results)
        XCTAssertEqual(report.suite.phraseCount, 2)
        XCTAssertEqual(report.suite.nextWord.checkpoints, 3)
        XCTAssertEqual(report.suite.nextWord.correct, 2)
        XCTAssertEqual(report.conditions["none"]?.suite.nextWord.correct, 1)
        let lift = try XCTUnwrap(report.contextLift)
        XCTAssertEqual(lift.suiteAccuracyDelta, 1.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(lift.byCategory["science"], 1)
        XCTAssertEqual(lift.byPhrase["a"], 0)
        XCTAssertEqual(lift.improvedCheckpoints, 2)
        XCTAssertEqual(lift.regressedCheckpoints, 1)
        XCTAssertEqual(report.primaryCondition, .screen)
        XCTAssertEqual(report.rendered().components(separatedBy: "\n"), [
            "SUITE (screen): 2 phrases, next-word 66.67% (2/3), coverage 66.67%, precision 100.00%",
            "Equal-category next-word score: 75.00%",
            "conversation: 1 phrases, next-word 50.00% (1/2), coverage 50.00%, precision 100.00%",
            "science: 1 phrases, next-word 100.00% (1/1), coverage 100.00%, precision 100.00%",
            "All character checkpoints: 66.67% (separate from next-word score)",
            "WITHOUT SCREEN: 2 phrases, next-word 33.33% (1/3), coverage 33.33%, precision 100.00%",
            "Screen-context lift: +33.33 percentage points; helped 2, harmed 1 word checkpoints",
            "  conversation lift +0.00 pp",
            "  science lift +100.00 pp"
        ])
    }

    func testUnpairedOrMismatchedCheckpointsHaveNoContextLift() {
        let none = PhrasePredictionReport.PhraseResult(phrase: phrase(), observations: [observation(nil)], condition: .none)
        let screen = PhrasePredictionReport.PhraseResult(phrase: phrase(), observations: [observation("at", typed: "c")], condition: .screen)
        XCTAssertNil(PhrasePredictionReport(metadata: metadata(), phrases: [none]).contextLift)
        XCTAssertNil(PhrasePredictionReport(metadata: metadata(), phrases: [none, screen]).contextLift)
    }

    private func phrase(_ text: String = "The cat naps.") -> PhrasePredictionCorpus.Phrase {
        .init(id: "a", category: "conversation", text: text)
    }

    /// A phrase that satisfies every per-phrase validation rule unless a test overrides one field.
    private func scenePhrase(
        id: String = "work-1",
        category: String = "work",
        text: String = "Please send it.",
        screen: String = "Morgan: the quarterly figures are finally ready for review."
    ) -> PhrasePredictionCorpus.Phrase {
        .init(id: id, category: category, text: text, scenario: .init(
            kind: "chat", applicationName: "Messages", bundleIdentifier: "com.apple.MobileSMS",
            windowTitle: "Morgan", fieldPlaceholder: "Message", documentPrefix: "", screenText: screen
        ))
    }

    private func validPhrases() -> [PhrasePredictionCorpus.Phrase] {
        [
            scenePhrase(),
            scenePhrase(id: "travel-1", category: "travel", text: "The train leaves early.",
                        screen: "Itinerary: platform four, departure listed on the board.")
        ]
    }

    private func corpus(_ phrases: [PhrasePredictionCorpus.Phrase]) -> PhrasePredictionCorpus {
        .init(version: 2, language: "en", provenance: "unit test", phrases: phrases)
    }

    /// Asserts the specific rule that rejected the corpus, so a test cannot pass because an
    /// earlier, unrelated check happened to throw first.
    private func assertInvalid(
        _ corpus: PhrasePredictionCorpus,
        canonical: Bool = false,
        _ expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try corpus.validate(canonical: canonical), file: file, line: line) { error in
            XCTAssertEqual((error as? LocalizedError)?.errorDescription, expected, file: file, line: line)
        }
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
