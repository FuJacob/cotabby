import XCTest

/// The measurement rules run in ordinary CI without a model. The opt-in runtime suite owns
/// timing; these tests make sure partial words, missed output, and cancellation are scored honestly.
final class TypingSessionEvalScoringTests: XCTestCase {
    func testUsefulWordRequiresCompleteSuffixAndExactCaretSpacing() {
        XCTAssertFalse(TypingSessionScorer.containsUsefulWord("ul", references: ["ule"]))
        XCTAssertFalse(TypingSessionScorer.containsUsefulWord(" ule", references: ["ule"]))
        XCTAssertTrue(TypingSessionScorer.containsUsefulWord("ule for tomorrow", references: ["ule"]))
        XCTAssertFalse(TypingSessionScorer.containsUsefulWord("catalog", references: ["cat"]))
        XCTAssertFalse(TypingSessionScorer.containsUsefulWord("cat's", references: ["cat"]))
        XCTAssertTrue(TypingSessionScorer.containsUsefulWord("cat.", references: ["cat"]))
        XCTAssertFalse(TypingSessionScorer.containsUsefulWord("anything", references: []))
    }

    func testFirstUsefulOutputIsSeparateFromFirstVisibleAndFinalOutput() {
        var measurement = makeMeasurement()
        measurement.recordVisible("ul", at: 140)
        measurement.recordVisible("ule", at: 170)
        measurement.recordVisible("ule", at: 180)
        measurement.recordVisible("ule tomorrow", at: 200)
        measurement.finishedMilliseconds = 260

        XCTAssertEqual(measurement.firstVisibleMilliseconds, 140)
        XCTAssertEqual(measurement.firstUsefulLatencyMilliseconds, 70)
        XCTAssertEqual(measurement.visibleRevisionCount, 3)
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

    func testCancelledDebounceHasNoGenerationWork() {
        var measurement = makeMeasurement()
        measurement.cancellationRequestedMilliseconds = 105
        measurement.finishedMilliseconds = 106
        XCTAssertEqual(measurement.cancelledWithoutUsefulOutputMilliseconds, 0)
    }

    func testWithdrawnStreamRetainsFirstUsefulTimeButCannotBeAccepted() {
        var measurement = makeMeasurement()
        measurement.recordVisible("ule", at: 130)
        measurement.recordHidden()
        measurement.recordHidden()
        XCTAssertNil(measurement.visibleText)
        XCTAssertEqual(measurement.firstUsefulLatencyMilliseconds, 30)
        XCTAssertEqual(measurement.withdrawnSuggestionCount, 1)
    }

    func testNoUsefulOutputHasNoLatencyPercentile() {
        XCTAssertNil(TypingSessionScorer.percentile(0.5, values: []))
        XCTAssertEqual(TypingSessionScorer.percentile(0.5, values: [200, 100, 300]), 200)
    }

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

    func testReportRoundTripsMeasurementsAndRetainsMissingLatency() throws {
        let report = TypingSessionEvalReport(
            modelFilename: "test.gguf", seed: 42, debounceMilliseconds: 20,
            sessions: [.init(traceID: "test", cacheMode: "cold", streamingEnabled: true, measurements: [makeMeasurement()])],
            wordCountPreset: "4-7"
        )
        let decoded = try JSONDecoder().decode(TypingSessionEvalReport.self, from: JSONEncoder().encode(report))
        XCTAssertNil(decoded.sessions[0].measurements[0].firstUsefulLatencyMilliseconds)
        XCTAssertEqual(decoded.wordCountPreset, "4-7")
        XCTAssertTrue(decoded.rendered().contains("p50 n/a"))
    }

    private func makeMeasurement() -> TypingSessionStepMeasurement {
        .init(
            step: .init(atMilliseconds: 0, action: .type, precedingText: "the sched", usefulContinuations: ["ule"]),
            inputMilliseconds: 100
        )
    }
}
