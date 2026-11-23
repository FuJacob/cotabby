import XCTest
@testable import Cotabby

/// Replays two chats with the same composer, draft and caret through the real coordinator.
/// Identical text is not identical context: every path that could carry a suggestion across a
/// conversation switch (visible tail, anchor cache, late result, streamed partial, speculative
/// exemption, screen context) must retire it on the navigation signal alone.
@MainActor
final class SuggestionConversationIsolationTests: SuggestionCoordinatorRigTestCase {
    func test_navigationImmediatelyRetiresVisibleSuggestionAndCachedTail() async {
        let rig = retained(makeCoordinatorRig())
        rig.coordinator.schedulePrediction()
        await waitUntil { rig.coordinator.overlayState.isVisible }
        let oldContext = rig.interactionState.currentContext!

        rig.publishFocusedInput(CotabbyTestFixtures.focusedInputSnapshot(focusChangeSequence: 2))
        XCTAssertNil(rig.interactionState.activeSession)
        XCTAssertFalse(rig.coordinator.overlayState.isVisible)
        XCTAssertFalse(rig.coordinator.acceptCurrentSuggestion())
        XCTAssertTrue(rig.inserter.insertedChunks.isEmpty)
        XCTAssertNil(rig.coordinator.suggestionAnchorCache.remainder(
            identityKey: oldContext.suggestionSessionIdentityKey, precedingText: oldContext.precedingText
        ))
    }

    func test_lateResultWithIdenticalDraftIsDroppedAfterNavigation() async {
        let rig = retained(makeCoordinatorRig())
        let source = rig.interactionState.materializeContext(from: rig.focusProvider.snapshot.context!)
        // Deliberately skip the publisher: apply must defend itself on its fresh snapshot alone.
        rig.setFocusedInput(CotabbyTestFixtures.focusedInputSnapshot(focusChangeSequence: 2))
        await rig.coordinator.apply(result: SuggestionResult(
            generation: source.generation, rawText: " old chat", text: " old chat", latency: 0.01
        ), workID: rig.coordinator.currentWorkID)
        XCTAssertFalse(rig.coordinator.overlayState.isVisible)
        XCTAssertNil(rig.interactionState.activeSession)
    }

    func test_speculativeTextMatchCannotOverrideConversationMismatch() async {
        // The speculation was built while the title was readable; a different known title is
        // another conversation (a nil one would only be a timed-out read of the same field).
        let rig = retained(makeCoordinatorRig(snapshot: CotabbyTestFixtures.focusedInputSnapshot(windowTitle: "This conversation")))
        let source = rig.interactionState.materializeContext(from: rig.focusProvider.snapshot.context!)
        rig.coordinator.pendingSpeculativeContext = source
        rig.setFocusedInput(CotabbyTestFixtures.focusedInputSnapshot(windowTitle: "Different conversation"))
        await rig.coordinator.apply(result: SuggestionResult(
            generation: source.generation, rawText: " old chat", text: " old chat", latency: 0.01
        ), workID: rig.coordinator.currentWorkID)
        XCTAssertFalse(rig.coordinator.overlayState.isVisible)
        XCTAssertNil(rig.interactionState.activeSession)
    }

    func test_streamedResultWithIdenticalDraftIsDroppedAfterNavigation() async {
        let rig = retained(makeCoordinatorRig())
        let source = rig.interactionState.materializeContext(from: rig.focusProvider.snapshot.context!)
        rig.setFocusedInput(CotabbyTestFixtures.focusedInputSnapshot(focusChangeSequence: 2))
        rig.coordinator.queueStreamedPartial(SuggestionResult(
            generation: source.generation, rawText: " world", text: " world", latency: 0.01
        ), workID: rig.coordinator.currentWorkID)
        // The partial was accepted into the coalescing queue; wait for its real main-queue drain.
        XCTAssertTrue(rig.coordinator.suggestionStreamingState.isDrainScheduled)
        await waitUntil { !rig.coordinator.suggestionStreamingState.isDrainScheduled }
        XCTAssertFalse(rig.coordinator.overlayState.isVisible)
        XCTAssertNil(rig.interactionState.activeSession)
    }

    func test_cacheCannotRestorePriorConversationWithoutFocusCallback() async {
        let rig = retained(makeCoordinatorRig())
        let source = rig.interactionState.materializeContext(from: rig.focusProvider.snapshot.context!)
        rig.coordinator.suggestionAnchorCache.record(
            identityKey: source.suggestionSessionIdentityKey, precedingText: source.precedingText, fullText: " old chat"
        )
        rig.setFocusedInput(CotabbyTestFixtures.focusedInputSnapshot(focusChangeSequence: 2))
        rig.coordinator.schedulePrediction()
        await waitUntil { rig.coordinator.overlayState.isVisible }
        XCTAssertEqual(rig.engine.requests.count, 1)
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, " world")
    }

    func test_expiringScreenContextRetiresConditionedPrediction() async {
        let rig = retained(makeCoordinatorRig())
        rig.visualContext.onStateChange?(.ready, "Previous conversation")
        rig.coordinator.schedulePrediction()
        await waitUntil { rig.coordinator.overlayState.isVisible }
        let workID = rig.coordinator.currentWorkID
        rig.visualContext.onStateChange?(.unavailable("Expired"), nil)
        XCTAssertFalse(rig.coordinator.overlayState.isVisible)
        XCTAssertNil(rig.interactionState.activeSession)
        XCTAssertNotEqual(rig.coordinator.currentWorkID, workID)
    }

    func test_changedScreenTextReplacesVisiblePredictionEvenWhenHostIdentityIsUnchanged() async {
        let rig = retained(makeCoordinatorRig())
        rig.coordinator.schedulePrediction()
        await waitUntil { rig.coordinator.overlayState.isVisible }
        rig.visualContext.onInjectedContextReady?(rig.focusProvider.snapshot.context!.identity)
        XCTAssertFalse(rig.coordinator.overlayState.isVisible)
        XCTAssertNil(rig.interactionState.activeSession)
        await waitUntil { rig.engine.requests.count == 2 && rig.coordinator.overlayState.isVisible }
    }

    func test_changedScreenTextKeepsTheVisiblePredictionInATerminalScreenField() async {
        // HerdrM's status line redraws every few seconds; each pane is its own field, so changed
        // screen text there is not a navigation signal and must not retire the visible suggestion.
        let rig = retained(makeCoordinatorRig(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(bundleIdentifier: "dev.bybee.herdrm", precedingText: "Hello")
        ))
        rig.coordinator.schedulePrediction()
        await waitUntil { rig.coordinator.overlayState.isVisible }
        rig.visualContext.onInjectedContextReady?(rig.focusProvider.snapshot.context!.identity)
        XCTAssertTrue(rig.coordinator.overlayState.isVisible)
        XCTAssertNotNil(rig.interactionState.activeSession)
        XCTAssertEqual(rig.engine.requests.count, 1)
    }
}
