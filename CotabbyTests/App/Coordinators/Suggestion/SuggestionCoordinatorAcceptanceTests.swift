import Foundation
import XCTest
@testable import Cotabby

/// Tests the coordinator-level acceptance contract.
///
/// `InputMonitor` owns the physical key event, but `SuggestionCoordinator` remains the final
/// validator for whether visible ghost text can be committed. These tests keep that boundary
/// explicit so future state-machine edits do not accidentally reintroduce `.ready` as a hard gate,
/// and they pin every pass-through and failure path: a `false` return hands Tab back to the host,
/// so each one must also leave no stale ghost text or session behind.
final class SuggestionCoordinatorAcceptanceTests: SuggestionCoordinatorRigTestCase {
    /// A field whose single-word suggestion is exhausted by one Tab.
    private var finalChunkSnapshot: FocusedInputSnapshot {
        CotabbyTestFixtures.focusedInputSnapshot(precedingText: "what's on your mind")
    }

    // MARK: - Gating

    func test_acceptCurrentSuggestionAllowsVisibleSessionWhileDebugStateIsDebouncing() {
        let rig = retained(makeCoordinatorRig())
        startVisibleSession(in: rig, fullText: " world again")
        rig.coordinator.state = .debouncing

        XCTAssertTrue(
            rig.inputMonitor.shouldConsumeAcceptKeyProvider(),
            "Preflight should depend on visible overlay, not `.ready`."
        )
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())

        XCTAssertEqual(rig.inserter.insertedChunks, [" world"])
        XCTAssertEqual(rig.coordinator.state, .ready(text: " again", latency: 0.05))
    }

    func test_acceptCurrentSuggestionPassesThroughWhileTemporarilyPaused() {
        let rig = retained(makeCoordinatorRig(
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(isTemporarilyPaused: true)
        ))
        startVisibleSession(in: rig)

        XCTAssertFalse(rig.coordinator.acceptCurrentSuggestion())
        XCTAssertTrue(rig.inserter.insertedChunks.isEmpty)
        XCTAssertNil(rig.interactionState.activeSession)
        XCTAssertEqual(rig.overlayController.hideReasons.last, "Cotabby is temporarily paused.")
    }

    func test_acceptPassesThroughAndClearsTheSessionWhenInputMonitoringIsRevoked() {
        let rig = retained(makeCoordinatorRig())
        startVisibleSession(in: rig)
        rig.permissionProvider.inputMonitoringGranted = false

        XCTAssertFalse(rig.coordinator.acceptCurrentSuggestion())

        XCTAssertTrue(rig.inserter.insertedChunks.isEmpty)
        XCTAssertNil(rig.interactionState.activeSession)
        XCTAssertFalse(rig.coordinator.overlayState.isVisible)
        XCTAssertEqual(rig.coordinator.state, .idle)
        XCTAssertEqual(
            rig.overlayController.hideReasons.last,
            "Input Monitoring permission is required before Cotabby can react to typing."
        )
    }

    func test_acceptCurrentSuggestionCleansVisibleOverlayWhenSessionDisappears() {
        let rig = retained(makeCoordinatorRig(
            overlayState: .visible(text: " stale", geometry: CotabbyTestFixtures.overlayGeometry(), mode: .inline)
        ))
        rig.coordinator.state = .debouncing

        XCTAssertTrue(
            rig.inputMonitor.shouldConsumeAcceptKeyProvider(),
            "A visible stale overlay should still route the accept key into the coordinator for cleanup."
        )
        XCTAssertFalse(rig.coordinator.acceptCurrentSuggestion())

        XCTAssertTrue(rig.inserter.insertedChunks.isEmpty)
        XCTAssertFalse(rig.coordinator.overlayState.isVisible)
        XCTAssertEqual(rig.coordinator.state, .idle)
        XCTAssertEqual(
            rig.overlayController.hideReasons.last,
            "Key passed through because no valid suggestion was ready."
        )
    }

    func test_acceptPreflightDeclinesTheKeyWhenNothingIsVisibleOrArmed() {
        let rig = retained(makeCoordinatorRig())

        XCTAssertFalse(
            rig.inputMonitor.shouldConsumeAcceptKeyProvider(),
            "With no ghost text and no post-exhaustion window, Tab belongs to the host app"
        )
    }

    // MARK: - Word acceptance and auto-space

    func test_acceptCurrentSuggestion_withAddSpaceAfterAccept_insertsTrailingSpaceOnNonFinalWord() {
        // With the setting ON and a multi-word suggestion, accepting the first word inserts the word
        // plus the suggestion's own following space (so the toggle fires per word, not only when the
        // suggestion is exhausted), while the tail keeps the rest.
        let rig = retained(makeCoordinatorRig(
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(debounceMilliseconds: 1, addSpaceAfterAccept: true)
        ))
        startVisibleSession(in: rig, fullText: " world how")

        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())

        XCTAssertEqual(rig.inserter.insertedChunks, [" world "])
        XCTAssertEqual(
            rig.coordinator.state,
            .ready(text: "how", latency: 0.05),
            "The consumed following space should not lead the tail."
        )
    }

    func test_acceptCurrentSuggestion_withoutAddSpaceAfterAccept_insertsWordWithoutTrailingSpace() {
        let rig = retained(makeCoordinatorRig(
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(debounceMilliseconds: 1, addSpaceAfterAccept: false)
        ))
        startVisibleSession(in: rig, fullText: " world how")

        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())

        XCTAssertEqual(rig.inserter.insertedChunks, [" world"])
        XCTAssertEqual(rig.coordinator.state, .ready(text: " how", latency: 0.05))
    }

    // MARK: - Insertion failures

    func test_failedInsertionReturnsTheKeyAndTearsTheSessionDown() {
        let rig = retained(makeCoordinatorRig())
        startVisibleSession(in: rig, fullText: " world again")
        rig.inserter.shouldInsert = false

        XCTAssertFalse(rig.coordinator.acceptCurrentSuggestion(), "A failed insert must not swallow Tab")

        XCTAssertEqual(rig.inserter.insertedChunks, [" world"], "The insert was attempted exactly once")
        XCTAssertNil(rig.interactionState.activeSession)
        XCTAssertFalse(rig.coordinator.overlayState.isVisible)
        XCTAssertEqual(rig.coordinator.state, .idle)
        XCTAssertEqual(rig.overlayController.hideReasons.last, "Overlay hidden because suggestion insertion failed.")
        XCTAssertNil(rig.coordinator.lastAcceptanceAt, "A failed insert is not an acceptance")
    }

    // MARK: - Correction acceptance

    func test_correctionPassesThroughWhenTheLiveWordNoLongerMatchesTheOffer() {
        let rig = retained(makeCoordinatorRig(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Please recieve ")
        ))
        startCorrectionSession(in: rig)
        // A keystroke slipped in between the offer and this Tab. Deleting the offered word's length
        // now would eat the wrong characters, so the key must pass through untouched.
        setFocusedInput(CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Please recieve i"), in: rig)

        XCTAssertFalse(rig.coordinator.acceptCurrentSuggestion())

        XCTAssertTrue(rig.inserter.replacements.isEmpty)
        XCTAssertNil(rig.interactionState.activeSession)
        XCTAssertEqual(
            rig.overlayController.hideReasons.last,
            "Key passed through because the word to correct changed."
        )
    }

    func test_failedCorrectionReplacementReturnsTheKeyAndClearsTheOffer() {
        let rig = retained(makeCoordinatorRig(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Please recieve ")
        ))
        startCorrectionSession(in: rig)
        rig.inserter.shouldInsert = false

        XCTAssertFalse(rig.coordinator.acceptCurrentSuggestion())

        XCTAssertEqual(rig.inserter.replacements.count, 1, "The replacement was attempted exactly once")
        XCTAssertNil(rig.interactionState.activeSession)
        XCTAssertEqual(rig.coordinator.state, .idle)
        XCTAssertFalse(rig.coordinator.postExhaustionAcceptanceState.isArmed, "A failed fix must not hold Tab")
        XCTAssertEqual(rig.overlayController.hideReasons.last, "Overlay hidden because correction insertion failed.")
    }

    // MARK: - Final chunk and the post-exhaustion window

    func test_acceptingFinalChunkDefersRegenerationAndRecordsAcceptedTail() {
        let rig = retained(makeCoordinatorRig(snapshot: finalChunkSnapshot))
        startVisibleSession(in: rig, fullText: " today")

        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())

        XCTAssertEqual(rig.inserter.insertedChunks, [" today"])
        // The final-chunk accept starts the continuation immediately against the text the host is
        // about to publish (speculative prefetch) instead of idling through the publish poll; the
        // overlay still hides until that result lands and validates.
        XCTAssertEqual(rig.coordinator.state, .generating)
        XCTAssertEqual(rig.coordinator.pendingSpeculativeContext?.precedingText, "what's on your mind today")
        XCTAssertFalse(rig.coordinator.overlayState.isVisible)
        // It records what it committed so `apply` can drop a stale echo of the same tail.
        XCTAssertEqual(
            rig.coordinator.lastAcceptedTail,
            AcceptedSuggestionTail(text: " today", precedingText: "what's on your mind")
        )
    }

    func test_speculativePrefetchKillSwitchLeavesFinalAcceptIdle() {
        let rig = retained(makeCoordinatorRig(snapshot: finalChunkSnapshot))
        rig.coordinator.userDefaults.set(true, forKey: SuggestionCoordinator.speculativePrefetchDisabledDefaultsKey)
        startVisibleSession(in: rig, fullText: " today")

        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())

        XCTAssertEqual(rig.inserter.insertedChunks, [" today"])
        XCTAssertNil(rig.coordinator.pendingSpeculativeContext, "The kill switch must skip the speculative request")
        XCTAssertEqual(rig.coordinator.state, .idle, "Only the host-publish poll may regenerate now")
        XCTAssertTrue(rig.coordinator.postExhaustionAcceptanceState.isArmed, "Tab ownership does not depend on speculation")
    }

    func test_rapidSecondAcceptDuringRegenerationIsConsumedNotPassedThrough() {
        let rig = retained(makeCoordinatorRig(snapshot: finalChunkSnapshot))
        startVisibleSession(in: rig, fullText: " today")

        // First Tab accepts the only remaining chunk, exhausts the session, and arms the window.
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
        XCTAssertTrue(rig.coordinator.postExhaustionAcceptanceState.isArmed)
        XCTAssertFalse(rig.coordinator.overlayState.isVisible)
        // Ownership of Tab was re-asserted even though the overlay is now hidden.
        XCTAssertEqual(rig.inputMonitor.acceptInterceptionRequests.last, true)
        XCTAssertTrue(
            rig.inputMonitor.shouldConsumeAcceptKeyProvider(),
            "The accept tap must keep owning Tab while the continuation regenerates."
        )

        // The rapid second Tab lands before the continuation regenerates. It must be swallowed and
        // queued, never forwarded to the host as a real Tab that moves focus.
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
        XCTAssertEqual(rig.inserter.insertedChunks, [" today"], "The second Tab is queued, not inserted.")
        XCTAssertTrue(rig.coordinator.postExhaustionAcceptanceState.hasQueuedAccept)
    }

    func test_postExhaustionWindowReleasesAcceptKeyWhenOverlayHides() {
        let rig = retained(makeCoordinatorRig(snapshot: finalChunkSnapshot))
        startVisibleSession(in: rig, fullText: " today")
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
        XCTAssertTrue(rig.coordinator.postExhaustionAcceptanceState.isArmed)

        // Any teardown that hides the overlay (focus change, typing, dismissal, an empty
        // regeneration) must end the window so the user can Tab out of the field normally again.
        rig.coordinator.invalidateActiveSuggestion(reason: "Focus moved to another field.")

        XCTAssertFalse(rig.coordinator.postExhaustionAcceptanceState.isArmed)
        XCTAssertFalse(rig.coordinator.postExhaustionAcceptanceState.hasQueuedAccept)
        XCTAssertFalse(rig.inputMonitor.shouldConsumeAcceptKeyProvider())
        XCTAssertFalse(
            rig.coordinator.acceptCurrentSuggestion(),
            "With the window released and no suggestion, Tab must pass through to the host."
        )
    }

    func test_postExhaustionBackstopReleasesTabWhenNoContinuationArrives() async {
        let rig = retained(makeCoordinatorRig())

        rig.coordinator.armPostExhaustionAcceptance()
        XCTAssertEqual(rig.inputMonitor.acceptInterceptionRequests, [true])
        XCTAssertTrue(rig.inputMonitor.shouldConsumeAcceptKeyProvider())

        // A stalled regeneration must never trap Tab in the field: the token-keyed timer ends the
        // window on its own after `postExhaustionAcceptanceWindowSeconds`.
        await waitUntil(timeout: SuggestionCoordinator.postExhaustionAcceptanceWindowSeconds + 2) {
            !rig.coordinator.postExhaustionAcceptanceState.isArmed
        }
        XCTAssertEqual(rig.inputMonitor.acceptInterceptionRequests, [true, false])
        XCTAssertFalse(rig.inputMonitor.shouldConsumeAcceptKeyProvider())
    }

    func test_releasingTheWindowKeepsInterceptionWhileASuggestionIsVisible() {
        let rig = retained(makeCoordinatorRig())
        startVisibleSession(in: rig)
        rig.coordinator.armPostExhaustionAcceptance()
        XCTAssertEqual(rig.inputMonitor.acceptInterceptionRequests, [true, true])

        rig.coordinator.releasePostExhaustionAcceptanceWindow()

        XCTAssertFalse(rig.coordinator.postExhaustionAcceptanceState.isArmed)
        XCTAssertEqual(
            rig.inputMonitor.acceptInterceptionRequests,
            [true, true],
            "A visible suggestion still owns Tab through the normal overlay path"
        )
    }

    func test_queuedPostExhaustionAcceptInsertsNextWordWhenContinuationArrives() {
        let rig = retained(makeCoordinatorRig())
        startVisibleSession(in: rig, fullText: " world again")
        // Simulate a Tab that was swallowed and queued while this continuation was still loading;
        // `apply` calls `flushQueuedPostExhaustionAcceptIfNeeded` once the suggestion is on screen.
        rig.coordinator.postExhaustionAcceptanceState.arm()
        rig.coordinator.postExhaustionAcceptanceState.queueAcceptIfArmed()

        rig.coordinator.flushQueuedPostExhaustionAcceptIfNeeded()

        XCTAssertEqual(rig.inserter.insertedChunks, [" world"], "The queued Tab should accept the first word.")
        XCTAssertFalse(rig.coordinator.postExhaustionAcceptanceState.isArmed)
        XCTAssertFalse(rig.coordinator.postExhaustionAcceptanceState.hasQueuedAccept)
    }

    func test_flushWithoutAQueuedPressInsertsNothing() {
        let rig = retained(makeCoordinatorRig())
        startVisibleSession(in: rig, fullText: " world again")
        rig.coordinator.postExhaustionAcceptanceState.arm()

        rig.coordinator.flushQueuedPostExhaustionAcceptIfNeeded()

        XCTAssertTrue(rig.inserter.insertedChunks.isEmpty)
        XCTAssertFalse(rig.coordinator.postExhaustionAcceptanceState.isArmed, "A fresh suggestion ends the window")
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, " world again")
    }

    // MARK: - Bookkeeping

    func test_acceptedWordsAreCountedAndPersistedAfterTheTapCallback() async {
        let rig = retained(makeCoordinatorRig())
        startVisibleSession(in: rig, fullText: " world again")

        XCTAssertTrue(rig.coordinator.acceptEntireSuggestion())
        XCTAssertEqual(
            rig.coordinator.totalTabAcceptedWordCount,
            0,
            "Counter writes are deferred out of the synchronous accept-tap callback"
        )

        await waitUntil { rig.coordinator.totalTabAcceptedWordCount == 2 }
        XCTAssertEqual(
            rig.coordinator.userDefaults.integer(forKey: SuggestionCoordinator.totalTabAcceptedWordCountDefaultsKey),
            2
        )
        XCTAssertEqual(rig.coordinator.qualityMetricsStore.counters.acceptedSuggestions, 1)
    }

    func test_walkingOneSuggestionWordByWordCountsASingleAcceptedSuggestion() async {
        let rig = retained(makeCoordinatorRig())
        startVisibleSession(in: rig, fullText: " world again")

        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
        setFocusedInput(CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello world"), in: rig)
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
        XCTAssertEqual(rig.inserter.insertedChunks, [" world", " again"])

        await waitUntil { rig.coordinator.totalTabAcceptedWordCount == 2 }
        XCTAssertEqual(
            rig.coordinator.qualityMetricsStore.counters.acceptedSuggestions,
            1,
            "Only the first chunk of a suggestion counts toward the acceptance rate"
        )
    }

    // MARK: - Anchor cache and speculative results

    /// A cached suggestion consistent with the live text must re-show without any engine call.
    func test_anchorCacheRestoresSuggestionWithoutGenerating() async {
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello wo")
        let rig = retained(makeCoordinatorRig(snapshot: snapshot))
        // The suggestion was generated when the field held "Hello"; the user has since typed " wo",
        // which is exactly the suggestion's first three characters.
        recordCachedSuggestion(" world again", after: "Hello", for: snapshot, in: rig)

        await rig.coordinator.generateFromCurrentFocus(workID: rig.coordinator.currentWorkID)

        XCTAssertEqual(rig.coordinator.state, .ready(text: "rld again", latency: 0))
        XCTAssertEqual(rig.interactionState.activeSession?.fullText, "rld again")
        XCTAssertTrue(rig.engine.requests.isEmpty)
    }

    func test_anchorReuseKillSwitchForcesAFreshGeneration() async {
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello wo")
        let rig = retained(makeCoordinatorRig(snapshot: snapshot))
        rig.coordinator.userDefaults.set(true, forKey: SuggestionCoordinator.anchorReuseDisabledDefaultsKey)
        recordCachedSuggestion(" world again", after: "Hello", for: snapshot, in: rig)

        await rig.coordinator.generateFromCurrentFocus(workID: rig.coordinator.currentWorkID)

        XCTAssertNotEqual(rig.coordinator.state, .ready(text: "rld again", latency: 0))
        await waitUntil { rig.engine.requests.count == 1 }
        XCTAssertEqual(rig.engine.requests.first?.prefixText, "Hello wo")
    }

    /// A speculative post-acceptance result carries a generation older than the live one by
    /// construction; it must still apply when the live content matches the signature it was
    /// built against, and must consume the exemption.
    func test_applyAcceptsSpeculativeResultWhenContentSignatureMatches() async {
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello world ")
        let rig = retained(makeCoordinatorRig(snapshot: snapshot))
        rig.coordinator.pendingSpeculativeContext = FocusedInputContext(snapshot: snapshot, generation: 1)

        await rig.coordinator.apply(result: speculativeResult, workID: rig.coordinator.currentWorkID)

        XCTAssertEqual(rig.coordinator.state, .ready(text: "from here on", latency: 0.1))
        XCTAssertNil(rig.coordinator.pendingSpeculativeContext, "the exemption is single-use")
    }

    /// Without the signature exemption, a stale-generation result must keep being dropped.
    func test_applyStillDropsStaleResultsWithoutSpeculativeSignature() async {
        let rig = retained(makeCoordinatorRig(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello world ")
        ))

        await rig.coordinator.apply(result: speculativeResult, workID: rig.coordinator.currentWorkID)

        XCTAssertEqual(rig.coordinator.state, .idle)
        XCTAssertNil(rig.interactionState.activeSession)
        XCTAssertEqual(rig.overlayController.hideReasons.last, "Overlay hidden because a stale result was dropped.")
    }

    // MARK: - Helpers

    private var speculativeResult: SuggestionResult {
        SuggestionResult(generation: 999, rawText: "from here on", text: "from here on", latency: 0.1)
    }

    private func startCorrectionSession(in rig: CoordinatorRig) {
        let context = rig.interactionState.materializeContext(from: rig.focusProvider.snapshot.context!)
        _ = rig.interactionState.startSession(
            fullText: "receive", liveContext: context, latency: 0, kind: .correction(typoWord: "recieve")
        )
        rig.overlayController.showSuggestion("receive", geometry: CotabbyTestFixtures.overlayGeometry())
    }

    private func recordCachedSuggestion(
        _ fullText: String,
        after precedingText: String,
        for snapshot: FocusedInputSnapshot,
        in rig: CoordinatorRig
    ) {
        let identityKey = FocusedInputContext(snapshot: snapshot, generation: 1).suggestionSessionIdentityKey
        rig.coordinator.suggestionAnchorCache.record(
            identityKey: identityKey, precedingText: precedingText, fullText: fullText
        )
    }
}
