import XCTest
@testable import Cotabby

/// Replays two chats with the same composer, draft and caret through the real coordinator.
@MainActor
final class SuggestionConversationIsolationTests: XCTestCase {
    func test_navigationImmediatelyRetiresVisibleSuggestionAndCachedTail() async {
        let rig = makeCoordinatorRig()
        defer { rig.coordinator.stop() }
        rig.coordinator.schedulePrediction()
        await waitUntil { rig.coordinator.overlayState.isVisible }
        let oldContext = rig.interactionState.currentContext!

        publish(CotabbyTestFixtures.focusedInputSnapshot(focusChangeSequence: 2), in: rig)
        XCTAssertNil(rig.interactionState.activeSession)
        XCTAssertFalse(rig.coordinator.overlayState.isVisible)
        XCTAssertFalse(rig.coordinator.acceptCurrentSuggestion())
        XCTAssertTrue(rig.inserter.insertedChunks.isEmpty)
        XCTAssertNil(rig.coordinator.suggestionAnchorCache.remainder(
            identityKey: oldContext.suggestionSessionIdentityKey, precedingText: oldContext.precedingText
        ))
    }

    func test_lateResultWithIdenticalDraftIsDroppedAfterNavigation() async {
        let rig = makeCoordinatorRig()
        defer { rig.coordinator.stop() }
        let source = rig.interactionState.materializeContext(from: rig.focusProvider.snapshot.context!)
        // Deliberately skip the publisher: apply must defend itself on its fresh snapshot alone.
        setSnapshot(CotabbyTestFixtures.focusedInputSnapshot(focusChangeSequence: 2), in: rig)
        await rig.coordinator.apply(result: SuggestionResult(
            generation: source.generation, rawText: " old chat", text: " old chat", latency: 0.01
        ), workID: rig.coordinator.currentWorkID)
        XCTAssertFalse(rig.coordinator.overlayState.isVisible)
        XCTAssertNil(rig.interactionState.activeSession)
    }

    func test_speculativeTextMatchCannotOverrideConversationMismatch() async {
        let rig = makeCoordinatorRig()
        defer { rig.coordinator.stop() }
        let source = rig.interactionState.materializeContext(from: rig.focusProvider.snapshot.context!)
        rig.coordinator.pendingSpeculativeContext = source
        setSnapshot(CotabbyTestFixtures.focusedInputSnapshot(windowTitle: "Different conversation"), in: rig)
        await rig.coordinator.apply(result: SuggestionResult(
            generation: source.generation, rawText: " old chat", text: " old chat", latency: 0.01
        ), workID: rig.coordinator.currentWorkID)
        XCTAssertFalse(rig.coordinator.overlayState.isVisible)
        XCTAssertNil(rig.interactionState.activeSession)
    }

    func test_streamedResultWithIdenticalDraftIsDroppedAfterNavigation() async {
        let rig = makeCoordinatorRig()
        defer { rig.coordinator.stop() }
        let source = rig.interactionState.materializeContext(from: rig.focusProvider.snapshot.context!)
        setSnapshot(CotabbyTestFixtures.focusedInputSnapshot(focusChangeSequence: 2), in: rig)
        rig.coordinator.queueStreamedPartial(SuggestionResult(
            generation: source.generation, rawText: " world", text: " world", latency: 0.01
        ), workID: rig.coordinator.currentWorkID)
        // Drain is posted to the main queue; a short suspension lets that actual callback run.
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertFalse(rig.coordinator.overlayState.isVisible)
        XCTAssertNil(rig.interactionState.activeSession)
    }

    func test_cacheCannotRestorePriorConversationWithoutFocusCallback() async {
        let rig = makeCoordinatorRig()
        defer { rig.coordinator.stop() }
        let source = rig.interactionState.materializeContext(from: rig.focusProvider.snapshot.context!)
        rig.coordinator.suggestionAnchorCache.record(
            identityKey: source.suggestionSessionIdentityKey, precedingText: source.precedingText, fullText: " old chat"
        )
        setSnapshot(CotabbyTestFixtures.focusedInputSnapshot(focusChangeSequence: 2), in: rig)
        rig.coordinator.schedulePrediction()
        await waitUntil { rig.coordinator.overlayState.isVisible }
        XCTAssertEqual(rig.engine.requests.count, 1)
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, " world")
    }

    func test_expiringScreenContextRetiresConditionedPrediction() async {
        let rig = makeCoordinatorRig()
        defer { rig.coordinator.stop() }
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
        let rig = makeCoordinatorRig()
        defer { rig.coordinator.stop() }
        rig.coordinator.schedulePrediction()
        await waitUntil { rig.coordinator.overlayState.isVisible }
        rig.visualContext.onInjectedContextReady?(rig.focusProvider.snapshot.context!.identity)
        XCTAssertFalse(rig.coordinator.overlayState.isVisible)
        XCTAssertNil(rig.interactionState.activeSession)
        await waitUntil { rig.engine.requests.count == 2 && rig.coordinator.overlayState.isVisible }
    }

    private func publish(_ snapshot: FocusedInputSnapshot, in rig: CoordinatorRig) {
        setSnapshot(snapshot, in: rig)
        rig.focusProvider.snapshotSubject.send(rig.focusProvider.snapshot)
    }

    private func setSnapshot(_ snapshot: FocusedInputSnapshot, in rig: CoordinatorRig) {
        rig.focusProvider.snapshot = FocusSnapshot(
            applicationName: snapshot.applicationName, bundleIdentifier: snapshot.bundleIdentifier,
            capability: .supported, context: snapshot
        )
    }
}
