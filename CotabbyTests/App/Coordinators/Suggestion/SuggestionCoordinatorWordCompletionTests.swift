import XCTest
@testable import Cotabby

/// Deterministic interaction replays exercise the production coordinator with synthetic focus
/// and engine boundaries. They cover what isolated model accuracy misses: correction eligibility,
/// transient bad ghosts, exact insertion, dismissal/cache reuse, and cancelled delayed display.
@MainActor
final class SuggestionCoordinatorWordCompletionTests: XCTestCase {
    func testPausingAfterEveryLetterCompletesWithoutReplacingTypedText() async {
        for word in ["because", "schedule", "recommend"] {
            for count in 1..<word.count {
                let prefix = String(word.prefix(count))
                let rig = makeCoordinatorRig(
                    snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Please " + prefix),
                    settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(debounceMilliseconds: 1,
                        suppressCompletionsOnTypo: true, offerTypoCorrections: true))
                let suffix = String(word.dropFirst(count))
                rig.engine.resultProvider = { request in
                    .init(generation: request.generation, rawText: suffix, text: suffix, latency: 0.01)
                }
                rig.coordinator.schedulePrediction()
                await waitUntil("No word completion for \(prefix)") { rig.interactionState.activeSession != nil }
                XCTAssertEqual(rig.engine.requests.count, 1, prefix)
                XCTAssertEqual(rig.interactionState.activeSession?.kind, .continuation, prefix)
                XCTAssertEqual(rig.interactionState.activeSession?.remainingText, suffix, prefix)
                XCTAssertTrue(rig.inserter.replacements.isEmpty, prefix)
                rig.coordinator.stop()
            }
        }
    }

    func testMalformedStreamNeverAppearsAndLocalFallbackAcceptsOnlyMissingLetters() async {
        let rig = makeCoordinatorRig(snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Please schedu"),
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(debounceMilliseconds: 1, streamSuggestionsWhileGenerating: true))
        defer { rig.coordinator.stop() }
        rig.coordinator.symSpellCorrector.loadForTesting(contents: "schedule 100\nscheduled 5\n")
        rig.engine.partialTexts = [" schedule", " schedule a meeting"]
        rig.engine.resultProvider = { request in
            .init(generation: request.generation, rawText: " schedule a meeting", text: " schedule a meeting", latency: 0.01)
        }
        rig.coordinator.schedulePrediction()
        await waitUntil { rig.interactionState.activeSession != nil }
        XCTAssertEqual(rig.overlayController.shownTexts, ["le"])
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
        XCTAssertEqual(rig.inserter.insertedChunks, ["le"])
        XCTAssertTrue(rig.inserter.replacements.isEmpty)
    }

    func testDismissedSuggestionDoesNotReturnFromCacheOrRegeneration() async {
        let rig = makeCoordinatorRig()
        defer { rig.coordinator.stop() }
        rig.coordinator.schedulePrediction()
        await waitUntil { rig.interactionState.activeSession != nil }
        _ = rig.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .dismissal))
        XCTAssertNil(rig.interactionState.activeSession)
        rig.coordinator.schedulePrediction()
        await waitUntil { rig.engine.requests.count == 2 && rig.coordinator.state == .idle }
        XCTAssertEqual(rig.overlayController.shownTexts, [" world"])
    }

    func testShortPrefixOffersOnlyAWordAndNeverInsertsTheUnshownPhrase() async {
        let rig = makeCoordinatorRig(snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "I want to b"))
        defer { rig.coordinator.stop() }
        rig.engine.resultProvider = { request in
            .init(generation: request.generation, rawText: "uild a spaceship", text: "uild a spaceship", latency: 0.01)
        }
        rig.coordinator.schedulePrediction()
        await waitUntil { rig.interactionState.activeSession != nil }
        XCTAssertEqual(rig.interactionState.activeSession?.fullText, "uild")
        XCTAssertTrue(rig.coordinator.acceptEntireSuggestion())
        XCTAssertEqual(rig.inserter.insertedChunks, ["uild"])
    }

    func testCancellationDuringTypingPausePreventsLatePresentation() async {
        let rig = makeCoordinatorRig(snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Please schedu"))
        defer { rig.coordinator.stop() }
        let context = rig.interactionState.materializeContext(from: rig.focusProvider.snapshot.context!)
        rig.coordinator.typingCadence.record(identityKey: context.focusedInputIdentityKey, characters: "u",
                                            at: ProcessInfo.processInfo.systemUptime)
        let workID = rig.coordinator.currentWorkID
        let task = Task { await rig.coordinator.apply(result: .init(generation: context.generation,
            rawText: "le", text: "le", latency: 0.01), workID: workID) }
        await Task.yield()
        rig.coordinator.cancelPredictionWork()
        await task.value
        XCTAssertTrue(rig.overlayController.shownTexts.isEmpty)
        XCTAssertNil(rig.interactionState.activeSession)
    }
}
