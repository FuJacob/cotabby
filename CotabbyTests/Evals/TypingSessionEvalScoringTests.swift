import XCTest

/// The measurement rules run in ordinary CI without a model. The opt-in runtime suite owns
/// timing; these tests make sure partial words, missed output, and cancellation are scored honestly.
final class TypingSessionEvalScoringTests: XCTestCase {
    // MARK: - Useful-word matching

    func testUsefulWordRequiresCompleteSuffixAndExactCaretSpacing() {
        let examples: [(candidate: String, references: [String], useful: Bool, why: String)] = [
            ("ule for tomorrow", ["ule"], true, "complete suffix followed by a space"),
            ("cat.", ["cat"], true, "terminal punctuation ends the word"),
            ("ule", ["ule"], true, "exact suffix with nothing after it"),
            ("ul", ["ule"], false, "partial suffix"),
            (" ule", ["ule"], false, "extra caret whitespace is a broken join"),
            ("catalog", ["cat"], false, "a following letter continues the word"),
            ("caté", ["cat"], false, "a following non-ASCII letter continues the word"),
            ("cat9", ["cat"], false, "a following digit continues the word"),
            ("cat's", ["cat"], false, "an apostrophe continues the word"),
            ("cat-like", ["cat"], false, "a hyphen continues the word"),
            ("Cat", ["cat"], false, "matching is case-sensitive"),
            ("anything", [], false, "no references"),
            ("anything", [""], false, "an empty reference never matches"),
            ("from you", [" soon", "from"], true, "any reference may match")
        ]
        for example in examples {
            XCTAssertEqual(
                TypingSessionScorer.containsUsefulWord(example.candidate, references: example.references),
                example.useful,
                example.why
            )
        }
    }

    // MARK: - Per-step measurement

    func testFirstUsefulOutputIsSeparateFromFirstVisibleAndFinalOutput() {
        var measurement = makeMeasurement()
        measurement.recordVisible("ul", at: 140)
        measurement.recordVisible("ule", at: 170)
        measurement.recordVisible("ule", at: 180)
        measurement.recordVisible("ule tomorrow", at: 200)

        XCTAssertEqual(measurement.firstVisibleMilliseconds, 140)
        XCTAssertEqual(measurement.firstUsefulLatencyMilliseconds, 70)
        XCTAssertEqual(measurement.visibleRevisionCount, 3, "an unchanged repeat is not a revision")
        XCTAssertEqual(measurement.nonUsefulVisibleRevisionCount, 1)
        XCTAssertEqual(measurement.visibleText, "ule tomorrow")
    }

    func testEmptyVisibleTextIsIgnored() {
        var measurement = makeMeasurement()
        measurement.recordVisible("", at: 120)
        XCTAssertNil(measurement.firstVisibleMilliseconds)
        XCTAssertNil(measurement.visibleText)
        XCTAssertEqual(measurement.visibleRevisionCount, 0)
    }

    func testCancellationIncludesDrainButDoesNotPretendToMeasureCPUTime() {
        var measurement = makeMeasurement()
        measurement.generationStartedMilliseconds = 120
        measurement.cancellationRequestedMilliseconds = 160
        measurement.finishedMilliseconds = 190

        XCTAssertNil(measurement.firstUsefulLatencyMilliseconds)
        XCTAssertEqual(measurement.cancellationDrainMilliseconds, 30)
        XCTAssertEqual(measurement.cancelledWithoutUsefulOutputMilliseconds, 70)
        measurement.recordVisible("ule", at: 150)
        XCTAssertEqual(measurement.cancelledWithoutUsefulOutputMilliseconds, 0)
    }

    func testCancellationDrainNeedsBothTimestampsAndNeverGoesNegative() {
        var measurement = makeMeasurement()
        measurement.cancellationRequestedMilliseconds = 200
        XCTAssertNil(measurement.cancellationDrainMilliseconds)
        measurement.finishedMilliseconds = 190
        XCTAssertEqual(measurement.cancellationDrainMilliseconds, 0)
    }

    func testCancelledDebounceHasNoGenerationWork() {
        var measurement = makeMeasurement()
        measurement.cancellationRequestedMilliseconds = 105
        measurement.finishedMilliseconds = 106
        XCTAssertEqual(measurement.cancelledWithoutUsefulOutputMilliseconds, 0)
    }

    func testUncancelledGenerationIsNeverWastedWork() {
        var measurement = makeMeasurement()
        measurement.generationStartedMilliseconds = 120
        measurement.finishedMilliseconds = 400
        XCTAssertEqual(measurement.cancelledWithoutUsefulOutputMilliseconds, 0)
    }

    func testWithdrawnStreamRetainsFirstUsefulTimeButCannotBeAccepted() {
        var measurement = makeMeasurement()
        measurement.recordHidden()
        XCTAssertEqual(measurement.withdrawnSuggestionCount, 0, "hiding nothing withdraws nothing")

        measurement.recordVisible("ule", at: 130)
        measurement.recordHidden()
        measurement.recordHidden()
        XCTAssertNil(measurement.visibleText)
        XCTAssertEqual(measurement.firstUsefulLatencyMilliseconds, 30)
        XCTAssertEqual(measurement.withdrawnSuggestionCount, 1)

        measurement.recordVisible("ule", at: 160)
        XCTAssertEqual(measurement.visibleRevisionCount, 2, "re-showing after a withdrawal is a new revision")
        XCTAssertEqual(measurement.firstUsefulLatencyMilliseconds, 30)
    }

    // MARK: - Percentiles

    func testPercentileUsesRoundedNearestRankAndClampsFraction() {
        XCTAssertNil(TypingSessionScorer.percentile(0.5, values: []), "no useful output has no latency")
        XCTAssertEqual(TypingSessionScorer.percentile(0.5, values: [200, 100, 300]), 200)
        XCTAssertEqual(TypingSessionScorer.percentile(0.95, values: [42]), 42)
        // Rank (4 - 1) * 0.5 = 1.5 rounds away from zero to index 2.
        XCTAssertEqual(TypingSessionScorer.percentile(0.5, values: [400, 100, 300, 200]), 300)
        XCTAssertEqual(TypingSessionScorer.percentile(-1, values: [300, 100]), 100)
        XCTAssertEqual(TypingSessionScorer.percentile(2, values: [300, 100]), 300)
    }

    // MARK: - Fixtures

    func testTracesCoverEditingActionsAndHaveIncreasingDeadlines() {
        let traces = TypingSessionTrace.standard
        XCTAssertEqual(Set(traces.map(\.id)).count, traces.count)
        let actions = Set(traces.flatMap(\.steps).map(\.action))
        XCTAssertEqual(actions, [.type, .backspace, .acceptWord, .moveCaret])
        XCTAssertTrue(traces.flatMap(\.steps).contains { $0.precedingText.contains("\n") })
        XCTAssertTrue(traces.flatMap(\.steps).contains { !$0.trailingText.isEmpty })
        for trace in traces {
            XCTAssertEqual(trace.steps.first?.atMilliseconds, 0)
            XCTAssertGreaterThan(trace.finalPauseMilliseconds, 0)
            for (previous, next) in zip(trace.steps, trace.steps.dropFirst()) {
                XCTAssertLessThan(previous.atMilliseconds, next.atMilliseconds)
                switch next.action {
                case .type, .acceptWord:
                    XCTAssertTrue(next.precedingText.hasPrefix(previous.precedingText), trace.id)
                case .backspace:
                    XCTAssertTrue(previous.precedingText.hasPrefix(next.precedingText), trace.id)
                case .moveCaret:
                    break
                }
            }
        }
    }

    // MARK: - Report

    func testReportRoundTripsMeasurementsAndRetainsMissingLatency() throws {
        let report = TypingSessionEvalReport(
            modelFilename: "test.gguf", seed: 42, debounceMilliseconds: 20,
            sessions: [.init(traceID: "test", cacheMode: "cold", streamingEnabled: true, measurements: [makeMeasurement()])],
            wordCountPreset: "4-7"
        )
        let decoded = try JSONDecoder().decode(TypingSessionEvalReport.self, from: JSONEncoder().encode(report))
        XCTAssertNil(decoded.sessions[0].measurements[0].firstUsefulLatencyMilliseconds)
        XCTAssertEqual(decoded.seed, 42)
        XCTAssertEqual(decoded.wordCountPreset, "4-7")
        XCTAssertEqual(decoded.measurementScope, report.measurementScope)
        XCTAssertTrue(decoded.rendered().contains("p50 n/a"))
    }

    func testRenderedSessionLineCountsOnlyExpectedWordsAndCancelledWaste() {
        var useful = makeMeasurement()
        useful.recordVisible("ule", at: 150)

        var missed = makeMeasurement()
        missed.generationStartedMilliseconds = 120
        missed.cancellationRequestedMilliseconds = 160
        missed.finishedMilliseconds = 190

        // A step with no reference word is excluded from the "expected useful" denominator.
        let unscored = TypingSessionStepMeasurement(
            step: .init(atMilliseconds: 0, action: .moveCaret, precedingText: "the ", usefulContinuations: []),
            inputMilliseconds: 100
        )

        let report = TypingSessionEvalReport(
            modelFilename: "test.gguf", seed: 42, debounceMilliseconds: 20,
            sessions: [
                .init(traceID: "a", cacheMode: "cold", streamingEnabled: false, measurements: [useful, missed, unscored]),
                .init(traceID: "b", cacheMode: "prewarmed", streamingEnabled: true, measurements: [])
            ]
        )
        XCTAssertEqual(report.rendered().components(separatedBy: "\n"), [
            "a [cold, streaming=false] useful 1/2 first-useful p50 50ms p95 50ms cancelled 1 "
                + "cancelled-without-useful elapsed 70ms",
            "b [prewarmed, streaming=true] useful 0/0 first-useful p50 n/a p95 n/a cancelled 0 "
                + "cancelled-without-useful elapsed 0ms"
        ])
    }

    private func makeMeasurement() -> TypingSessionStepMeasurement {
        .init(
            step: .init(atMilliseconds: 0, action: .type, precedingText: "the sched", usefulContinuations: ["ule"]),
            inputMilliseconds: 100
        )
    }
}
