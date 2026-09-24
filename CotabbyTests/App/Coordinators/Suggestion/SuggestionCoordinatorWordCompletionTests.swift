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
                    let text = request.prefixText.hasSuffix(" ") ? "" : suffix
                    return .init(generation: request.generation, rawText: text, text: text, latency: 0.01)
                }
                rig.coordinator.schedulePrediction()
                await waitUntil("No word completion for \(prefix)") { rig.interactionState.activeSession != nil }
                XCTAssertEqual(rig.engine.requests.filter { $0.prefixText == "Please " + prefix }.count, 1, prefix)
                XCTAssertTrue(rig.engine.requests.dropFirst().allSatisfy { $0.prefixText == "Please " + word + " " })
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
            let text = request.prefixText == "Please schedule " ? "a meeting" : " schedule a meeting"
            return .init(generation: request.generation, rawText: text, text: text, latency: 0.01)
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

    func testShortPrefixKeepsFollowingWordsAfterAcceptingWordEnding() async {
        let rig = makeCoordinatorRig(snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "I want to b"))
        defer { rig.coordinator.stop() }
        rig.engine.resultProvider = { request in
            .init(generation: request.generation, rawText: "uild a spaceship", text: "uild a spaceship", latency: 0.01)
        }
        rig.coordinator.schedulePrediction()
        await waitUntil { rig.interactionState.activeSession != nil }
        XCTAssertEqual(rig.interactionState.activeSession?.fullText, "uild a spaceship")
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
        XCTAssertEqual(rig.inserter.insertedChunks, ["uild"])
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, " a spaceship")
        XCTAssertEqual(rig.engine.requests.count, 1, "The following words were already generated.")
    }

    func testBoundaryPreferenceWaitsThenGeneratesAfterSpace() async {
        let rig = makeCoordinatorRig(snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello"),
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(debounceMilliseconds: 1, suggestWithinWords: false))
        defer { rig.coordinator.stop() }
        rig.coordinator.schedulePrediction()
        await waitUntil { rig.coordinator.state == .idle }
        XCTAssertTrue(rig.engine.requests.isEmpty)
        XCTAssertTrue(rig.overlayController.shownTexts.isEmpty)

        publishText("Hello ", in: rig)
        rig.coordinator.schedulePrediction()
        await waitUntil { rig.interactionState.activeSession != nil }
        XCTAssertEqual(rig.engine.requests.map(\.prefixText), ["Hello "])
    }

    func testBoundaryPreferencePreservesVisibleTailThroughTypingAndRefresh() async {
        let rig = makeCoordinatorRig(snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello "),
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(debounceMilliseconds: 1, suggestWithinWords: false))
        defer { rig.coordinator.stop() }
        let context = rig.interactionState.materializeContext(from: rig.focusProvider.snapshot.context!)
        _ = rig.interactionState.startSession(fullText: "world again", liveContext: context, latency: 0.01)
        rig.overlayController.showSuggestion("world again", geometry: CotabbyTestFixtures.overlayGeometry())

        _ = rig.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .textMutation, characters: "w"))
        publishText("Hello w", in: rig)
        rig.coordinator.schedulePrediction()
        await waitUntil { rig.coordinator.state == .ready(text: "orld again", latency: 0.01) }
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, "orld again")
        XCTAssertTrue(rig.engine.requests.isEmpty)
    }

    func testAcceptedCorrectionWaitsForPublishedTextAndQueuesNextTab() async {
        let rig = makeCoordinatorRig(snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Please recieve "),
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(debounceMilliseconds: 1,
                suggestWithinWords: false, suppressCompletionsOnTypo: true, offerTypoCorrections: true))
        defer { rig.coordinator.stop() }
        let context = rig.interactionState.materializeContext(from: rig.focusProvider.snapshot.context!)
        _ = rig.interactionState.startSession(fullText: "receive", liveContext: context, latency: 0,
            kind: .correction(typoWord: "recieve"))
        rig.overlayController.showSuggestion("receive", geometry: CotabbyTestFixtures.overlayGeometry())
        rig.engine.resultProvider = { request in
            .init(generation: request.generation, rawText: "the package", text: "the package", latency: 0.01)
        }

        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
        XCTAssertEqual(rig.inserter.replacements.map(\.text), ["receive "])
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion(), "Rapid Tab should wait for the continuation.")
        await waitUntil { rig.focusProvider.refreshCount > 0 }
        XCTAssertTrue(rig.engine.requests.allSatisfy { $0.prefixText == "Please receive " },
            "Lookahead must use the corrected word, never stale pre-replacement AX.")
        XCTAssertNil(rig.interactionState.activeSession)

        publishText("Please receive ", in: rig)
        await waitUntil { !rig.inserter.insertedChunks.isEmpty }
        XCTAssertEqual(rig.engine.requests.map(\.prefixText), ["Please receive "])
        XCTAssertEqual(rig.inserter.insertedChunks, ["the"])
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, " package")
    }

    func testFinalAcceptPredictsFromActualInsertedTrailingSpace() async {
        let rig = makeCoordinatorRig(settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(
            suggestWithinWords: false, addSpaceAfterAccept: true))
        defer { rig.coordinator.stop() }
        let context = rig.interactionState.materializeContext(from: rig.focusProvider.snapshot.context!)
        _ = rig.interactionState.startSession(fullText: " world", liveContext: context, latency: 0.01)
        rig.overlayController.showSuggestion(" world", geometry: CotabbyTestFixtures.overlayGeometry())

        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
        XCTAssertEqual(rig.inserter.insertedChunks, [" world "])
        let expected = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello world ")
        XCTAssertEqual(rig.coordinator.pendingSpeculativeContext?.contentSignature, expected.contentSignature)
        await waitUntil { !rig.engine.requests.isEmpty }
        XCTAssertEqual(rig.engine.requests.first?.prefixText, "Hello world ")
    }

    func testBoundaryPreferenceDoesNotCaptureNextTabWhenFinalAcceptAddsNoSpace() {
        let rig = makeCoordinatorRig(settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(suggestWithinWords: false))
        defer { rig.coordinator.stop() }
        let context = rig.interactionState.materializeContext(from: rig.focusProvider.snapshot.context!)
        _ = rig.interactionState.startSession(fullText: " world", liveContext: context, latency: 0.01)
        rig.overlayController.showSuggestion(" world", geometry: CotabbyTestFixtures.overlayGeometry())
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
        XCTAssertEqual(rig.inserter.insertedChunks, [" world"])
        XCTAssertNil(rig.coordinator.pendingSpeculativeContext)
        XCTAssertFalse(rig.coordinator.postExhaustionAcceptanceState.isArmed)
        XCTAssertFalse(rig.coordinator.acceptCurrentSuggestion())
    }

    func testCorrectionTimeoutNeverReoffersOrRepeatsAnUnpublishedReplacement() async {
        for automatic in [false, true] {
            let rig = makeCoordinatorRig(snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Please recieve "),
                settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(debounceMilliseconds: 1,
                    suppressCompletionsOnTypo: true, offerTypoCorrections: true, automaticallyFixTypos: automatic))
            rig.coordinator.schedulePrediction()
            if automatic {
                await waitUntil { !rig.inserter.replacements.isEmpty }
            } else {
                await waitUntil { rig.interactionState.activeSession?.kind.isCorrection == true }
                XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
                XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
            }
            // Keep AX frozen beyond its 400 ms publication ceiling. Neither manual nor automatic
            // correction may interpret this old word as permission to replace it a second time.
            try? await Task.sleep(nanoseconds: 500_000_000)
            XCTAssertEqual(rig.inserter.replacements.count, 1)
            XCTAssertNil(rig.interactionState.activeSession)
            XCTAssertEqual(rig.engine.requests.map(\.prefixText), ["Please receive "])
            XCTAssertFalse(rig.coordinator.postExhaustionAcceptanceState.isArmed)
            rig.coordinator.stop()
        }
    }

    private func publishText(_ text: String, in rig: CoordinatorRig) {
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: text)
        rig.focusProvider.snapshot = FocusSnapshot(applicationName: snapshot.applicationName,
            bundleIdentifier: snapshot.bundleIdentifier, capability: .supported, context: snapshot)
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
