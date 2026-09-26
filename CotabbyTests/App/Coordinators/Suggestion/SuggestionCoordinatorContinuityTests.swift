import Foundation
import XCTest
@testable import Cotabby

/// Replays the visible typing experience across prediction, presentation, insertion, and AX
/// publication. The recording rig keeps the engine and host editor deterministic while the real
/// coordinator owns cancellation and promotion of following words.
@MainActor
final class SuggestionCoordinatorContinuityTests: XCTestCase {
    func testConfiguredEndpointWaitsForCorrectionAcceptanceAndPublicationBeforeRequesting() async {
        let rig = makeCoordinatorRig(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Please recieve "),
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(
                selectedEngine: .openAICompatible, debounceMilliseconds: 1,
                suppressCompletionsOnTypo: true, offerTypoCorrections: true
            )
        )
        defer { rig.coordinator.stop() }
        rig.coordinator.symSpellCorrector.loadForTesting(contents: "receive 100\n")
        rig.engine.resultProvider = { request in
            SuggestionResult(generation: request.generation, rawText: "the package", text: "the package", latency: 0.01)
        }
        rig.coordinator.schedulePrediction()
        await waitUntil { rig.interactionState.activeSession?.kind.isCorrection == true }
        XCTAssertNil(rig.coordinator.preparedContinuation)
        XCTAssertTrue(rig.engine.requests.isEmpty, "An unaccepted hypothetical edit must not create endpoint traffic")
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
        XCTAssertTrue(rig.engine.requests.isEmpty)
        publish(CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Please receive "), in: rig)
        await waitUntil { !rig.engine.requests.isEmpty }
        XCTAssertTrue(rig.engine.requests.allSatisfy { $0.prefixText == "Please receive " })
    }

    func testUnknownWordEndingRetainsFollowingWordsUntilTheVisibleEndingIsAccepted() async {
        let rig = makeCoordinatorRig(snapshot: CotabbyTestFixtures.focusedInputSnapshot(
            precedingText: "Use Zorbquux"
        ))
        defer { rig.coordinator.stop() }
        rig.engine.resultProvider = { request in
            // Pin only the invented joined word's lexical evidence. This keeps the integration
            // replay independent of the user's installed spell-checking dictionaries.
            rig.coordinator.suggestionStreamingState.spellingAssessments["Zorbquuxbeam"] = .uncorrectableTypo
            return SuggestionResult(generation: request.generation, rawText: "beam for the device",
                                    text: "beam for the device", latency: 0.01)
        }

        rig.coordinator.schedulePrediction()
        await waitUntil { rig.interactionState.activeSession != nil }

        XCTAssertEqual(rig.interactionState.activeSession?.fullText, "beam for the device")
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, "beam")
        XCTAssertEqual(rig.overlayController.shownTexts, ["beam"])
        XCTAssertTrue(rig.coordinator.acceptEntireSuggestion())
        XCTAssertEqual(rig.inserter.insertedChunks, ["beam"])
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, " for the device")
        XCTAssertEqual(rig.engine.requests.count, 1)
    }

    func testOneWordPresentationFullAcceptInsertsOnlyTheVisibleWordThenOffersTheNext() async {
        let rig = makeCoordinatorRig(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello "),
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(debounceMilliseconds: 1, showFollowingWords: false)
        )
        defer { rig.coordinator.stop() }
        rig.engine.resultProvider = { request in
            SuggestionResult(generation: request.generation, rawText: "world again tomorrow",
                             text: "world again tomorrow", latency: 0.01)
        }

        rig.coordinator.schedulePrediction()
        await waitUntil { rig.interactionState.activeSession != nil }

        XCTAssertEqual(rig.overlayController.shownTexts, ["world"])
        XCTAssertTrue(rig.coordinator.acceptEntireSuggestion())
        XCTAssertEqual(rig.inserter.insertedChunks, ["world"])
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, " again")
        XCTAssertEqual(rig.interactionState.activeSession?.predictedRemainingText, " again tomorrow")
        XCTAssertEqual(rig.engine.requests.count, 1)
    }

    func testStreamingGrowsFollowingWordBufferWithoutRedisplayingTheSameVisibleWord() async {
        let rig = makeCoordinatorRig(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello "),
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(
                debounceMilliseconds: 1, showFollowingWords: false, streamSuggestionsWhileGenerating: true
            )
        )
        let gate = ResultGate()
        defer { gate.resume(text: "world again tomorrow"); rig.coordinator.stop() }
        rig.engine.partialTexts = ["world again ", "world again tomorrow "]
        rig.engine.resultProvider = { request in await gate.wait(for: request) }

        rig.coordinator.schedulePrediction()
        await waitUntil {
            gate.isWaiting && rig.interactionState.activeSession?.fullText == "world again tomorrow "
        }

        XCTAssertEqual(rig.overlayController.shownTexts, ["world"])
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, "world")
        XCTAssertTrue(rig.coordinator.acceptEntireSuggestion())
        XCTAssertEqual(rig.inserter.insertedChunks, ["world"])
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, " again")
        XCTAssertEqual(rig.interactionState.activeSession?.predictedRemainingText, " again tomorrow ")

        gate.resume(text: "world again tomorrow")
        await waitUntil { gate.didReturn }
        await Task.yield()
        XCTAssertEqual(rig.interactionState.activeSession?.consumedCharacterCount, 5,
                       "The cancelled stream's final result must not restart the already accepted word")
    }

    func testAcceptingAStreamedWordNeverRevealsAnIncompleteHiddenFollowingWord() async {
        let rig = makeCoordinatorRig(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello "),
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(
                debounceMilliseconds: 1, showFollowingWords: false, streamSuggestionsWhileGenerating: true
            )
        )
        let gate = ResultGate()
        defer { gate.resume(text: "world again"); rig.coordinator.stop() }
        rig.engine.partialTexts = ["world ag"]
        rig.engine.resultProvider = { request in
            if request.prefixText == "Hello " { return await gate.wait(for: request) }
            return SuggestionResult(generation: request.generation, rawText: "", text: "", latency: 0.01)
        }
        rig.coordinator.schedulePrediction()
        await waitUntil { gate.isWaiting && rig.interactionState.activeSession?.remainingText == "world" }

        XCTAssertEqual(rig.interactionState.activeSession?.predictedRemainingText
            .trimmingCharacters(in: .whitespacesAndNewlines), "world",
            "An unfinished hidden model token is not a usable following word")
        rig.engine.partialTexts = []
        XCTAssertTrue(rig.coordinator.acceptEntireSuggestion())
        XCTAssertEqual(rig.inserter.insertedChunks, ["world"])
        XCTAssertNil(rig.interactionState.activeSession,
                     "Cancelling the stream on acceptance cannot leave its unfinished next word as a ghost")
        XCTAssertFalse(rig.overlayController.shownTexts.contains(" ag"))

        gate.resume(text: "world again")
        await waitUntil { gate.didReturn }
        await Task.yield()
        XCTAssertFalse(rig.overlayController.shownTexts.contains(" ag"))
    }

    func testLocalFallbackPredictsAfterTheCompletedWordAndAttachesTheHiddenContinuation() async {
        let rig = makeCoordinatorRig(snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Please schedu"))
        defer { rig.coordinator.stop() }
        rig.coordinator.symSpellCorrector.loadForTesting(contents: "schedule 100\nscheduled 5\n")
        rig.engine.resultProvider = { request in
            let text = request.prefixText == "Please schedu" ? " schedule a meeting" : "a meeting"
            return SuggestionResult(generation: request.generation, rawText: text, text: text, latency: 0.01)
        }

        rig.coordinator.schedulePrediction()
        await waitUntil { rig.interactionState.activeSession?.fullText == "le a meeting" }

        XCTAssertEqual(rig.engine.requests.map(\.prefixText), ["Please schedu", "Please schedule "])
        XCTAssertEqual(rig.overlayController.shownTexts, ["le"])
        XCTAssertTrue(rig.coordinator.acceptEntireSuggestion())
        XCTAssertEqual(rig.inserter.insertedChunks, ["le"])
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, " a meeting")
        XCTAssertEqual(rig.engine.requests.count, 2, "Acceptance should reveal the prepared tail without a third request")
    }

    func testAXOnlyWordExhaustionPreservesTheInflightContinuation() async {
        let rig = makeCoordinatorRig(snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Please schedu"))
        let gate = ResultGate()
        defer { gate.resume(text: "a meeting"); rig.coordinator.stop() }
        rig.engine.resultProvider = { request in
            if request.prefixText == "Please schedu" {
                return SuggestionResult(generation: request.generation, rawText: "le", text: "le", latency: 0.01)
            }
            return await gate.wait(for: request)
        }
        rig.coordinator.schedulePrediction()
        await waitUntil { gate.isWaiting }

        // AX can publish matching input that the key tap never observed, for example an editor's
        // own text service. Exhaustion through this path must commit the same prepared request as
        // typed-through input, even though no optimistic key-event advancement occurred.
        publishText("Please schedule", in: rig)
        rig.coordinator.handleFocusSnapshotChange(rig.focusProvider.snapshot)
        XCTAssertNil(rig.interactionState.activeSession)
        XCTAssertEqual(rig.coordinator.preparedContinuation?.awaitingCommit, true)
        XCTAssertEqual(rig.engine.requests.map(\.prefixText), ["Please schedu", "Please schedule "])

        gate.resume(text: "a meeting")
        await waitUntil { rig.interactionState.activeSession?.remainingText == " a meeting" }
        XCTAssertEqual(rig.engine.requests.count, 2, "AX-only exhaustion must not restart the prepared generation")
        XCTAssertTrue(rig.inserter.insertedChunks.isEmpty)
    }

    func testRestoredCachedWordEndingImmediatelyPreparesItsFollowingWords() async {
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Please schedu")
        let rig = makeCoordinatorRig(snapshot: snapshot)
        let gate = ResultGate()
        defer { gate.resume(text: "a meeting"); rig.coordinator.stop() }
        let context = rig.interactionState.materializeContext(from: snapshot)
        rig.coordinator.suggestionAnchorCache.record(identityKey: context.suggestionSessionIdentityKey,
            precedingText: context.precedingText, fullText: "le")
        rig.engine.resultProvider = { request in await gate.wait(for: request) }

        rig.coordinator.schedulePrediction()
        await waitUntil { gate.isWaiting }
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, "le")
        XCTAssertEqual(rig.engine.requests.map(\.prefixText), ["Please schedule "],
                       "A cached ending avoids regenerating that word but must still prepare its continuation")

        gate.resume(text: "a meeting")
        await waitUntil { rig.interactionState.activeSession?.fullText == "le a meeting" }
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
        XCTAssertEqual(rig.inserter.insertedChunks, ["le"])
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, " a meeting")
        XCTAssertEqual(rig.engine.requests.count, 1)
    }

    func testCorrectionContinuationStaysHiddenUntilTheExactReplacementPublishes() async {
        let rig = correctionRig()
        defer { rig.coordinator.stop() }
        rig.engine.resultProvider = { request in
            SuggestionResult(generation: request.generation, rawText: "the package", text: "the package", latency: 0.01)
        }
        rig.coordinator.schedulePrediction()
        await waitUntil { rig.coordinator.preparedContinuation?.text == "the package" }

        XCTAssertEqual(rig.engine.requests.map(\.prefixText), ["Please receive "])
        XCTAssertEqual(rig.overlayController.shownTexts, ["receive"])
        XCTAssertEqual(rig.interactionState.activeSession?.kind, .correction(typoWord: "recieve"))
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
        XCTAssertEqual(rig.inserter.replacements.map(\.text), ["receive "])
        XCTAssertNil(rig.interactionState.activeSession)
        XCTAssertFalse(rig.coordinator.usePreparedContinuationIfPossible(), "The old typo is not the prefetch target")

        publishText("Please receives ", in: rig)
        XCTAssertFalse(rig.coordinator.usePreparedContinuationIfPossible(), "A different edit cannot promote the prefetch")
        XCTAssertNil(rig.interactionState.activeSession)

        publishText("Please receive ", in: rig)
        XCTAssertTrue(rig.coordinator.usePreparedContinuationIfPossible())
        await waitUntil { rig.interactionState.activeSession?.remainingText == "the package" }
        // Let the earlier acceptance poll's deadline pass: it must not regenerate after the
        // prepared result was already promoted, even when presentation won that scheduling race.
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(rig.engine.requests.count, 1)
        XCTAssertTrue(rig.inserter.insertedChunks.isEmpty, "Prepared text becomes a ghost, never an automatic insertion")
    }

    func testAcceptingCorrectionPreservesAnInflightContinuationRequest() async {
        let rig = correctionRig()
        let gate = ResultGate()
        defer { gate.resume(text: "the package"); rig.coordinator.stop() }
        rig.engine.resultProvider = { request in await gate.wait(for: request) }
        rig.coordinator.schedulePrediction()
        await waitUntil { gate.isWaiting && rig.interactionState.activeSession?.kind.isCorrection == true }

        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
        publishText("Please receive ", in: rig)
        XCTAssertTrue(rig.coordinator.usePreparedContinuationIfPossible())
        XCTAssertNil(rig.interactionState.activeSession)
        XCTAssertEqual(rig.engine.requests.count, 1)

        gate.resume(text: "the package")
        await waitUntil { rig.interactionState.activeSession?.remainingText == "the package" }
        XCTAssertEqual(rig.engine.requests.count, 1, "The same request should survive correction acceptance")
        XCTAssertEqual(rig.inserter.replacements.count, 1)
    }

    func testFieldSwitchAfterCorrectionPublicationCancelsLookaheadWithoutAnActiveSession() async {
        let rig = correctionRig()
        let gate = ResultGate()
        defer { gate.resume(text: "the package"); rig.coordinator.stop() }
        rig.engine.resultProvider = { request in await gate.wait(for: request) }
        rig.coordinator.schedulePrediction()
        await waitUntil { gate.isWaiting && rig.interactionState.activeSession?.kind.isCorrection == true }

        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
        let refreshCountBeforePublication = rig.focusProvider.refreshCount
        publishText("Please receive ", in: rig)
        await waitUntil { rig.focusProvider.refreshCount > refreshCountBeforePublication }
        XCTAssertTrue(rig.coordinator.usePreparedContinuationIfPossible())
        XCTAssertNil(rig.interactionState.activeSession)
        XCTAssertEqual(rig.coordinator.preparedContinuation?.awaitingCommit, true)

        // The corrected text has already published, so its publication poll may stand down while
        // the engine still runs. There is no active session left to notice a subsequent field switch.
        publish(CotabbyTestFixtures.focusedInputSnapshot(
            elementIdentifier: "other-field", precedingText: "Please receive ", focusChangeSequence: 2
        ), in: rig)
        rig.coordinator.handleSupportedSnapshot(rig.focusProvider.snapshot)
        XCTAssertNil(rig.coordinator.preparedContinuation,
                     "Focus handling must cancel prepared work even when the source session is gone")

        gate.resume(text: "the package")
        await waitUntil { gate.didReturn }
        await Task.yield()
        XCTAssertNil(rig.interactionState.activeSession)
        XCTAssertFalse(rig.coordinator.overlayState.isVisible)
        XCTAssertTrue(rig.inserter.insertedChunks.isEmpty)
        XCTAssertEqual(rig.inserter.replacements.count, 1)
    }

    func testDismissalCancelsCorrectionLookaheadAndALateResultCannotResurrectIt() async {
        let rig = correctionRig()
        let gate = ResultGate()
        defer { gate.resume(text: "the package"); rig.coordinator.stop() }
        rig.engine.resultProvider = { request in await gate.wait(for: request) }
        rig.coordinator.schedulePrediction()
        await waitUntil { gate.isWaiting }

        _ = rig.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .dismissal))
        XCTAssertNil(rig.coordinator.preparedContinuation)
        XCTAssertNil(rig.interactionState.activeSession)

        gate.resume(text: "the package")
        await waitUntil { gate.didReturn }
        await Task.yield()
        XCTAssertNil(rig.coordinator.preparedContinuation)
        XCTAssertNil(rig.interactionState.activeSession)
        XCTAssertFalse(rig.coordinator.overlayState.isVisible)
        XCTAssertTrue(rig.inserter.replacements.isEmpty)
    }

    func testChangingFieldsCancelsCorrectionLookaheadEvenWhenTheTextMatches() async {
        let rig = correctionRig()
        let gate = ResultGate()
        defer { gate.resume(text: "the package"); rig.coordinator.stop() }
        rig.engine.resultProvider = { request in await gate.wait(for: request) }
        rig.coordinator.schedulePrediction()
        await waitUntil { gate.isWaiting }

        let otherField = CotabbyTestFixtures.focusedInputSnapshot(
            elementIdentifier: "other-field", precedingText: "Please recieve ", focusChangeSequence: 2
        )
        publish(otherField, in: rig)
        rig.coordinator.handleFocusSnapshotChange(rig.focusProvider.snapshot)
        XCTAssertNil(rig.coordinator.preparedContinuation)
        XCTAssertNil(rig.interactionState.activeSession)

        gate.resume(text: "the package")
        await waitUntil { gate.didReturn }
        await Task.yield()
        XCTAssertNil(rig.interactionState.activeSession)
        XCTAssertFalse(rig.coordinator.overlayState.isVisible)
        XCTAssertTrue(rig.inserter.replacements.isEmpty)
    }

    func testCorrectionAndItsPreparedContinuationSurviveAXElementTokenChurn() async {
        let rig = makeCoordinatorRig(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(
                precedingText: "Please recieve ", isWebContentField: true
            ),
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(
                debounceMilliseconds: 1, suppressCompletionsOnTypo: true, offerTypoCorrections: true
            )
        )
        rig.coordinator.symSpellCorrector.loadForTesting(contents: "receive 100\n")
        defer { rig.coordinator.stop() }
        rig.engine.resultProvider = { request in
            SuggestionResult(generation: request.generation, rawText: "the package", text: "the package", latency: 0.01)
        }
        rig.coordinator.schedulePrediction()
        await waitUntil { rig.coordinator.preparedContinuation?.text == "the package" }

        // Chromium may replace the AX element token without a focus change. Sequence and exact
        // content still identify the original edit; treating token churn as a field switch would
        // remove the correction just as the user reaches for Tab.
        publish(CotabbyTestFixtures.focusedInputSnapshot(
            elementIdentifier: "recycled-ax-token", precedingText: "Please recieve ",
            isWebContentField: true, focusChangeSequence: 1
        ), in: rig)
        rig.coordinator.handleFocusSnapshotChange(rig.focusProvider.snapshot)
        XCTAssertEqual(rig.interactionState.activeSession?.kind, .correction(typoWord: "recieve"))
        XCTAssertEqual(rig.coordinator.preparedContinuation?.text, "the package")
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
        XCTAssertEqual(rig.inserter.replacements.map(\.text), ["receive "])

        publish(CotabbyTestFixtures.focusedInputSnapshot(
            elementIdentifier: "recycled-ax-token", precedingText: "Please receive ",
            isWebContentField: true, focusChangeSequence: 1
        ), in: rig)
        XCTAssertTrue(rig.coordinator.usePreparedContinuationIfPossible())
        await waitUntil { rig.interactionState.activeSession?.remainingText == "the package" }
        XCTAssertEqual(rig.engine.requests.count, 1)
    }

    private func correctionRig() -> CoordinatorRig {
        let rig = makeCoordinatorRig(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Please recieve "),
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(
                debounceMilliseconds: 1, suppressCompletionsOnTypo: true, offerTypoCorrections: true
            )
        )
        rig.coordinator.symSpellCorrector.loadForTesting(contents: "receive 100\n")
        return rig
    }

    private func publishText(_ text: String, in rig: CoordinatorRig) {
        publish(CotabbyTestFixtures.focusedInputSnapshot(precedingText: text), in: rig)
    }

    private func publish(_ snapshot: FocusedInputSnapshot, in rig: CoordinatorRig) {
        rig.focusProvider.snapshot = FocusSnapshot(applicationName: snapshot.applicationName,
            bundleIdentifier: snapshot.bundleIdentifier, capability: .supported, context: snapshot)
    }

    /// A test-owned engine suspension deliberately ignores task cancellation. Releasing it after
    /// dismissal or a field switch proves that coordinator work identity, not a cooperative mock,
    /// prevents stale results from returning to the screen. Every test resumes its gate in defer.
    @MainActor
    private final class ResultGate {
        private var continuation: CheckedContinuation<SuggestionResult, Never>?
        private var request: SuggestionRequest?
        private(set) var didReturn = false
        var isWaiting: Bool { continuation != nil }

        func wait(for request: SuggestionRequest) async -> SuggestionResult {
            self.request = request
            let result = await withCheckedContinuation { continuation in self.continuation = continuation }
            didReturn = true
            return result
        }

        func resume(text: String) {
            guard let continuation, let request else { return }
            self.continuation = nil
            continuation.resume(returning: SuggestionResult(
                generation: request.generation, rawText: text, text: text, latency: 0.01
            ))
        }
    }
}
