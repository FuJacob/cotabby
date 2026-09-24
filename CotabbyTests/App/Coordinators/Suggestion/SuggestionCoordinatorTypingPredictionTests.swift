import Foundation
import XCTest
@testable import Cotabby

/// Replays typing against a deliberately suspended engine. Late callbacks ignore cancellation,
/// proving that work identity and publication checks protect insertion even with a slow backend.
@MainActor
final class SuggestionCoordinatorTypingPredictionTests: XCTestCase {
    func testHiddenCandidateSurvivesMatchingKeysWithoutAnotherRequest() async {
        let engine = ControlledTypingEngine()
        let rig = makeRig(engine)
        defer { rig.coordinator.stop(); engine.finishAll() }
        rig.coordinator.schedulePrediction()
        await waitUntil { engine.requests.count == 1 }
        engine.emit("you the report tomorrow")
        XCTAssertTrue(rig.overlayController.shownTexts.isEmpty, "Streaming off still collects a hidden candidate")

        type("you ", in: rig)
        publish("I'll send you ", in: rig)
        type("the ", in: rig)
        publish("I'll send you the ", in: rig)
        engine.finish("you the report tomorrow")
        await waitUntil { rig.interactionState.activeSession != nil }

        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, "report tomorrow")
        XCTAssertEqual(engine.requests.count, 1)
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
        XCTAssertEqual(rig.inserter.insertedChunks.first?.trimmingCharacters(in: .whitespaces), "report")
    }

    func testTypingAheadOfFirstTokenCanCatchUpWithoutRestarting() async {
        let engine = ControlledTypingEngine()
        let rig = makeRig(engine)
        defer { rig.coordinator.stop(); engine.finishAll() }
        rig.coordinator.schedulePrediction()
        await waitUntil { engine.requests.count == 1 }
        let workID = rig.coordinator.currentWorkID
        type("y", in: rig)
        publish("I'll send y", in: rig)
        engine.emit("you the report")
        engine.finish("you the report")
        await waitUntil { rig.interactionState.activeSession != nil }
        XCTAssertEqual(rig.coordinator.currentWorkID, workID)
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, "ou the report")
        XCTAssertEqual(engine.requests.count, 1)
    }

    func testDivergentTypingRestartsAndOldCallbacksCannotResurrectTheCandidate() async {
        let engine = ControlledTypingEngine()
        let rig = makeRig(engine)
        defer { rig.coordinator.stop(); engine.finishAll() }
        rig.coordinator.schedulePrediction()
        await waitUntil { engine.requests.count == 1 }
        engine.emit("you the report")
        type("everyone ", in: rig)
        publish("I'll send everyone ", in: rig)
        await waitUntil { engine.requests.count == 2 }
        engine.emit("you the report tomorrow", request: 0)
        engine.finish("you the report tomorrow", request: 0)
        XCTAssertTrue(rig.overlayController.shownTexts.isEmpty)
        engine.finish("a copy", request: 1)
        await waitUntil { rig.interactionState.activeSession != nil }
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, "a copy")
        XCTAssertEqual(engine.requests[1].prefixText, "I'll send everyone ")
    }

    func testFinalAnswerWaitsForExactAXPublication() async {
        let engine = ControlledTypingEngine()
        let rig = makeRig(engine)
        defer { rig.coordinator.stop(); engine.finishAll() }
        rig.coordinator.schedulePrediction()
        await waitUntil { engine.requests.count == 1 }
        engine.emit("you the report")
        type("you ", in: rig)
        engine.finish("you the report")
        await waitUntil { rig.coordinator.typingPrediction?.isFinal == true }
        XCTAssertNil(rig.interactionState.activeSession)
        XCTAssertFalse(rig.inputMonitor.shouldConsumeAcceptKeyProvider())

        publish("I'll send you ", in: rig)
        await waitUntil { rig.interactionState.activeSession != nil }
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, "the report")
        XCTAssertEqual(engine.requests.count, 1)
    }

    func testFinalBufferedDuringPauseStillSurvivesAnotherMatchingKey() async {
        let engine = ControlledTypingEngine()
        let rig = makeRig(engine)
        defer { rig.coordinator.stop(); engine.finishAll() }
        rig.coordinator.schedulePrediction()
        await waitUntil { engine.requests.count == 1 }
        type("y", in: rig)
        publish("I'll send y", in: rig)
        engine.finish("you the report")
        await waitUntil { rig.coordinator.typingPrediction?.isFinal == true }
        type("o", in: rig)
        publish("I'll send yo", in: rig)
        await waitUntil { rig.interactionState.activeSession != nil }
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, "u the report")
        XCTAssertEqual(engine.requests.count, 1)
    }

    func testUnfinishedPredictionCannotStarveLatestText() async {
        let engine = ControlledTypingEngine()
        let rig = makeRig(engine)
        defer { rig.coordinator.stop(); engine.finishAll() }
        rig.coordinator.schedulePrediction()
        await waitUntil { engine.requests.count == 1 }
        type("you ", in: rig)
        publish("I'll send you ", in: rig)
        await waitUntil(timeout: 1) { engine.requests.count == 2 }
        XCTAssertEqual(engine.requests[1].prefixText, "I'll send you ")
        engine.finish("you the obsolete version", request: 0)
        engine.finish("the report", request: 1)
        await waitUntil { rig.interactionState.activeSession != nil }
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, "the report")
    }

    func testVisibleStreamKeepsGrowingThroughMatchingTypingButStopsOnTab() async {
        let engine = ControlledTypingEngine()
        let rig = makeRig(engine, streaming: true)
        defer { rig.coordinator.stop(); engine.finishAll() }
        rig.coordinator.schedulePrediction()
        await waitUntil { engine.requests.count == 1 }
        engine.emit("you the ")
        await waitUntil { rig.interactionState.activeSession != nil }
        let workID = rig.coordinator.currentWorkID
        type("you ", in: rig)
        publish("I'll send you ", in: rig)
        engine.emit("you the report tomorrow ")
        await waitUntil { rig.interactionState.activeSession?.remainingText.contains("report") == true }
        XCTAssertEqual(rig.coordinator.currentWorkID, workID)
        XCTAssertFalse(rig.interactionState.activeSession?.remainingText.hasPrefix("you") == true)
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
        XCTAssertNotEqual(rig.coordinator.currentWorkID, workID)
        let acceptedTail = rig.interactionState.activeSession?.remainingText
        engine.finish("you the report tomorrow morning")
        await Task.yield()
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, acceptedTail)
        XCTAssertEqual(rig.inserter.insertedChunks.first?.trimmingCharacters(in: .whitespaces), "the")
    }

    func testTypingThroughEntirePartialKeepsUnfinishedContinuationHiddenUntilItArrives() async {
        let engine = ControlledTypingEngine()
        let rig = makeRig(engine, streaming: true)
        defer { rig.coordinator.stop(); engine.finishAll() }
        rig.coordinator.schedulePrediction()
        await waitUntil { engine.requests.count == 1 }
        engine.emit("you ")
        await waitUntil { rig.interactionState.activeSession != nil }
        type("you ", in: rig)
        XCTAssertNil(rig.interactionState.activeSession)
        XCTAssertFalse(rig.inputMonitor.shouldConsumeAcceptKeyProvider())
        publish("I'll send you ", in: rig)
        engine.finish("you the report")
        await waitUntil { rig.interactionState.activeSession != nil }
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, "the report")
        XCTAssertEqual(engine.requests.count, 1)
    }

    func testAnotherFocusSequenceCannotReceiveSameTextCandidate() async {
        let engine = ControlledTypingEngine()
        let rig = makeRig(engine)
        defer { rig.coordinator.stop(); engine.finishAll() }
        rig.coordinator.schedulePrediction()
        await waitUntil { engine.requests.count == 1 }
        publish("I'll send ", sequence: 2, in: rig)
        await waitUntil { engine.requests.count == 2 }
        engine.finish("you the wrong report", request: 0)
        engine.finish("a letter", request: 1)
        await waitUntil { rig.interactionState.activeSession != nil }
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, "a letter")
    }

    func testFullyTypedFinalPredictionRequestsTheNextWords() async {
        let engine = ControlledTypingEngine()
        let rig = makeRig(engine)
        defer { rig.coordinator.stop(); engine.finishAll() }
        rig.coordinator.schedulePrediction()
        await waitUntil { engine.requests.count == 1 }
        engine.emit("you ")
        type("you ", in: rig)
        publish("I'll send you ", in: rig)
        engine.finish("you ")
        await waitUntil { engine.requests.count == 2 }
        engine.finish("the report", request: 1)
        await waitUntil { rig.interactionState.activeSession != nil }
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, "the report")
        XCTAssertEqual(engine.requests[1].prefixText, "I'll send you ")
    }

    func testDismissalAndEmojiCaptureCancelHiddenPrediction() async {
        for emojiCapture in [false, true] {
            let engine = ControlledTypingEngine()
            let rig = makeRig(engine)
            defer { rig.coordinator.stop(); engine.finishAll() }
            rig.coordinator.schedulePrediction()
            await waitUntil { engine.requests.count == 1 }
            if emojiCapture { rig.coordinator.emojiInputObserver = { _ in true } }
            _ = rig.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(
                kind: emojiCapture ? .textMutation : .dismissal, characters: emojiCapture ? ":" : ""))
            XCTAssertNil(rig.coordinator.typingPrediction)
            engine.finish("you the report")
            await Task.yield()
            XCTAssertNil(rig.interactionState.activeSession)
        }
    }

    func testEndpointDoesNotEnableBackgroundCollectionOrRetainRequestsAcrossKeys() async {
        let engine = ControlledTypingEngine()
        let rig = makeRig(engine, engineKind: .openAICompatible)
        defer { rig.coordinator.stop(); engine.finishAll() }
        rig.coordinator.schedulePrediction()
        await waitUntil { engine.requests.count == 1 }
        XCTAssertNil(rig.coordinator.typingPrediction)
        XCTAssertFalse(engine.hasPartialCallback(request: 0))
        let workID = rig.coordinator.currentWorkID
        type("you ", in: rig)
        XCTAssertNotEqual(rig.coordinator.currentWorkID, workID)
    }

    func testDisabledPredictionRestartsOnTypingWithoutChangingStreamingPreference() async {
        for streaming in [false, true] {
            let engine = ControlledTypingEngine()
            let rig = makeRig(engine, streaming: streaming, predictAhead: false)
            defer { rig.coordinator.stop(); engine.finishAll() }
            rig.coordinator.schedulePrediction()
            await waitUntil { engine.requests.count == 1 }
            XCTAssertNil(rig.coordinator.typingPrediction)
            XCTAssertEqual(engine.hasPartialCallback(request: 0), streaming)
            let workID = rig.coordinator.currentWorkID
            type("you ", in: rig)
            publish("I'll send you ", in: rig)
            XCTAssertNotEqual(rig.coordinator.currentWorkID, workID)
            await waitUntil { engine.requests.count == 2 }
            engine.finish("you the obsolete report", request: 0)
            engine.finish("the current report", request: 1)
            await waitUntil { rig.interactionState.activeSession != nil }
            XCTAssertEqual(rig.interactionState.activeSession?.remainingText, "the current report")
        }
    }

    func testTurningPredictionOffDiscardsAnInFlightCandidateAndRejectsLateDelivery() async {
        let engine = ControlledTypingEngine()
        let rig = makeRig(engine)
        defer { rig.coordinator.stop(); engine.finishAll() }
        rig.coordinator.schedulePrediction()
        await waitUntil { engine.requests.count == 1 }
        engine.emit("you the old report")
        XCTAssertNotNil(rig.coordinator.typingPrediction)

        rig.coordinator.handleSuggestionSettingsChange(CotabbyTestFixtures.settingsSnapshot(
            selectedEngine: .appleIntelligence, debounceMilliseconds: 1, predictAheadWhileTyping: false))
        XCTAssertNil(rig.coordinator.typingPrediction)
        await waitUntil { engine.requests.count == 2 }
        XCTAssertFalse(engine.hasPartialCallback(request: 1))
        engine.emit("you the old report tomorrow", request: 0)
        engine.finish("you the old report tomorrow", request: 0)
        engine.finish("everyone the updated report", request: 1)
        await waitUntil { rig.interactionState.activeSession != nil }
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, "everyone the updated report")
    }

    private func makeRig(_ engine: ControlledTypingEngine, streaming: Bool = false, predictAhead: Bool = true,
                         engineKind: SuggestionEngineKind = .appleIntelligence) -> CoordinatorRig {
        makeCoordinatorRig(snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "I'll send "),
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(selectedEngine: engineKind,
                debounceMilliseconds: 1, streamSuggestionsWhileGenerating: streaming,
                predictAheadWhileTyping: predictAhead), generationEngine: engine)
    }

    private func type(_ text: String, in rig: CoordinatorRig) {
        _ = rig.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .textMutation, characters: text))
    }

    private func publish(_ text: String, sequence: UInt64 = 1, in rig: CoordinatorRig) {
        let raw = CotabbyTestFixtures.focusedInputSnapshot(precedingText: text, focusChangeSequence: sequence)
        let snapshot = FocusSnapshot(applicationName: raw.applicationName, bundleIdentifier: raw.bundleIdentifier,
                                     capability: .supported, context: raw)
        rig.focusProvider.snapshot = snapshot
        rig.focusProvider.snapshotSubject.send(snapshot)
    }
}

/// Test-owned single calls deliberately remain resumable after cancellation to exercise stale delivery.
@MainActor
private final class ControlledTypingEngine: SuggestionGenerating {
    private(set) var requests: [SuggestionRequest] = []
    private var callbacks: [Int: @MainActor (SuggestionResult) -> Void] = [:]
    private var continuations: [Int: CheckedContinuation<SuggestionResult, Never>] = [:]

    func generateSuggestion(for request: SuggestionRequest) async throws -> SuggestionResult {
        try await generateSuggestion(for: request, onPartial: nil)
    }

    func generateSuggestion(for request: SuggestionRequest,
                            onPartial: (@MainActor (SuggestionResult) -> Void)?) async throws -> SuggestionResult {
        let index = requests.count
        requests.append(request)
        callbacks[index] = onPartial
        return await withCheckedContinuation { continuations[index] = $0 }
    }

    func emit(_ text: String, request index: Int = 0) {
        callbacks[index]?(result(text, request: index))
    }

    func finish(_ text: String, request index: Int = 0) {
        guard let continuation = continuations.removeValue(forKey: index) else { return }
        continuation.resume(returning: result(text, request: index))
    }

    func finishAll() {
        for index in Array(continuations.keys) { finish("", request: index) }
    }

    func hasPartialCallback(request index: Int) -> Bool { callbacks[index] != nil }

    private func result(_ text: String, request index: Int) -> SuggestionResult {
        SuggestionResult(generation: requests[index].generation, rawText: text, text: text, latency: 0.1)
    }

    func resetCachedGenerationContext() async {}
}
