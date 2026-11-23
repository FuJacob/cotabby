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

    func test_acceptCurrentSuggestionAllowsVisibleSessionWhilePipelineIsDebouncing() {
        let rig = retained(makeCoordinatorRig())
        startVisibleSession(in: rig, fullText: " world again")
        rig.coordinator.state = .debouncing

        XCTAssertTrue(
            rig.inputMonitor.shouldConsumeAcceptKeyProvider(),
            "Preflight should depend on visible overlay, not `.ready`."
        )
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())

        XCTAssertEqual(rig.inserter.insertedChunks, [" world"])
        XCTAssertEqual(rig.coordinator.state, .ready)
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, " again")
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
        XCTAssertEqual(rig.coordinator.state, .ready)
        XCTAssertEqual(
            rig.interactionState.activeSession?.remainingText,
            "how",
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
        XCTAssertEqual(rig.coordinator.state, .ready)
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, " how")
    }

    // MARK: - Rapid successive accepts

    func test_rapidTabsAcceptEachWordWhileTheOverlayIsStillHoldingThePreviousPresent() {
        // Regression: the overlay controller can hold a presentation (pixel caret read, lagging
        // host caret) and leave `overlayState` on the pre-accept tail. A second Tab arriving in that
        // window, before the host has even published the first insertion to AX, used to fail the
        // "visible text equals tail" check, tear the session down, and pass Tab to the browser,
        // which moved focus to the page's other controls.
        let rig = retained(makeCoordinatorRig())
        startVisibleSession(in: rig, fullText: " hello world again")
        rig.overlayController.defersPresentations = true

        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
        XCTAssertEqual(rig.overlayController.heldPresentationText, " world again")
        XCTAssertEqual(
            visibleText(of: rig.coordinator.overlayState),
            " hello world again",
            "The held present leaves the published state on the previous tail"
        )
        XCTAssertTrue(
            rig.inputMonitor.shouldConsumeAcceptKeyProvider(),
            "The accept tap must keep owning Tab while the next present is held"
        )

        // The focus snapshot is untouched: AX has not published " hello" yet.
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion(), "The second rapid Tab must be consumed")
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion(), "So must the third")

        XCTAssertEqual(rig.inserter.insertedChunks, [" hello", " world", " again"])
        XCTAssertFalse(
            rig.overlayController.hideReasons.contains { $0.hasPrefix("Key passed through") },
            "No Tab may be handed back to the host during the rapid sequence"
        )
    }

    /// A browser field whose title and URL were readable when the suggestion was offered.
    private var browserComposerSnapshot: FocusedInputSnapshot {
        CotabbyTestFixtures.focusedInputSnapshot(
            precedingText: "Hello", isWebContentField: true,
            focusedURLString: "https://chat.example/one", windowTitle: "Chat one"
        )
    }

    func test_rapidTabIsStillConsumedWhenThePreAcceptRefreshCannotReadTheTitleOrURL() {
        // Regression: the accept path refreshes the focus snapshot synchronously, inside the event
        // tap, while the host is still busy with the previous synthetic insertion. The window title
        // and page URL are re-read on that refresh under a 50 ms AX timeout, and a busy Chromium
        // answers one of them with nothing. That nil used to fail the session-identity equality as
        // a "focused field" change: the session was torn down and Tab reached the page, moving
        // focus to its buttons. Slow Tabs never hit it because the host was idle by the next read.
        let rig = retained(makeCoordinatorRig(snapshot: browserComposerSnapshot))
        startVisibleSession(in: rig, fullText: " hello world again")

        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())

        // The second Tab's refresh reads the same field, but its title and URL time out. AX has not
        // published " hello" yet either.
        rig.setFocusedInput(CotabbyTestFixtures.focusedInputSnapshot(
            precedingText: "Hello", isWebContentField: true, focusedURLString: nil, windowTitle: nil
        ))
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion(), "An unreadable title is not another field")

        // The third Tab's refresh reads both facts again.
        rig.setFocusedInput(browserComposerSnapshot)
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())

        XCTAssertEqual(rig.inserter.insertedChunks, [" hello", " world", " again"])
        XCTAssertFalse(
            rig.overlayController.hideReasons.contains { $0.contains("focused field changed") },
            "A timed-out surface read must not be mistaken for navigation"
        )
    }

    func test_tabStillPassesThroughWhenTheRefreshReadsAnotherConversation() {
        // The tolerance is for facts that could not be read, never for facts that read differently:
        // identical draft text in another conversation must still hand Tab back.
        let rig = retained(makeCoordinatorRig(snapshot: browserComposerSnapshot))
        startVisibleSession(in: rig, fullText: " hello world")
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())

        rig.setFocusedInput(CotabbyTestFixtures.focusedInputSnapshot(
            precedingText: "Hello", isWebContentField: true,
            focusedURLString: "https://chat.example/two", windowTitle: "Chat two"
        ))

        XCTAssertFalse(rig.coordinator.acceptCurrentSuggestion())
        XCTAssertEqual(rig.inserter.insertedChunks, [" hello"])
        XCTAssertNil(rig.interactionState.activeSession)
    }

    func test_heldPresentLandingKeepsTheRemainingTailAcceptable() {
        let rig = retained(makeCoordinatorRig())
        startVisibleSession(in: rig, fullText: " hello world again")
        rig.overlayController.defersPresentations = true
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())

        rig.overlayController.defersPresentations = false
        rig.overlayController.landHeldPresentation()

        XCTAssertNil(rig.overlayController.heldPresentationText)
        XCTAssertEqual(visibleText(of: rig.coordinator.overlayState), " world again")
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
        XCTAssertEqual(rig.inserter.insertedChunks, [" hello", " world"])
    }

    func test_staleVisibleGhostWithoutAHeldPresentStillPassesTabThrough() {
        // The held text widens acceptance only for Cotabby's own in-flight present. A ghost that
        // shows something other than the tail, with nothing held, is stale UI and must not accept.
        let rig = retained(makeCoordinatorRig())
        startVisibleSession(in: rig, fullText: " hello world")
        rig.overlayController.showSuggestion(
            " something else",
            geometry: CotabbyTestFixtures.overlayGeometry()
        )

        XCTAssertFalse(rig.coordinator.acceptCurrentSuggestion())
        XCTAssertTrue(rig.inserter.insertedChunks.isEmpty)
        XCTAssertNil(rig.interactionState.activeSession)
    }

    // MARK: - Post-accept hold against screen-context refresh

    func test_screenContextChangeRightAfterAnAcceptKeepsTheTailBeingAccepted() {
        // Regression from a Gmail repro: the ~3s OCR refresh landed mid Tab burst, read the user's
        // own accepted words as navigation, and replaced the suggestion; the next Tab, finding no
        // ghost, went to Gmail and moved focus out of the compose body.
        let rig = retained(makeCoordinatorRig())
        startVisibleSession(in: rig, fullText: " hello world again")
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())

        rig.visualContext.onInjectedContextReady?(rig.focusProvider.snapshot.context!.identity)

        XCTAssertTrue(rig.coordinator.overlayState.isVisible)
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, " world again")
        XCTAssertNotNil(rig.coordinator.deferredScreenContextRetirement, "The change is deferred, not dropped")
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion(), "The next Tab must continue the same suggestion")
        XCTAssertEqual(rig.inserter.insertedChunks, [" hello", " world"])
    }

    func test_deferredScreenContextChangeRetiresTheTailOnceAcceptingStops() async {
        // The excerpt is stored when it arrives and an identical later refresh does not fire again,
        // so a held change must still be acted on: otherwise a real navigation is lost for good.
        let rig = retained(makeCoordinatorRig())
        rig.coordinator.postAcceptHoldMilliseconds = 50
        startVisibleSession(in: rig, fullText: " hello world again")
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())

        rig.visualContext.onInjectedContextReady?(rig.focusProvider.snapshot.context!.identity)
        XCTAssertNotNil(rig.interactionState.activeSession)

        // Wait for the retirement itself, not for an empty session: retiring schedules a fresh
        // prediction, and the stub engine can answer it before a poll ever sees the gap.
        let requestsBefore = rig.engine.requests.count
        await waitUntil { rig.overlayController.hideReasons.contains("Overlay hidden because screen context changed.") }
        await waitUntil { rig.engine.requests.count > requestsBefore }
    }

    func test_caretMoveDuringTheHoldSettlesTheDeferredChangeWithoutPredicting() async {
        // The arrow key retires the tail and leaves Cotabby idle. The deferred change must not wake
        // after it and start a prediction the user never typed for.
        let rig = retained(makeCoordinatorRig())
        rig.coordinator.postAcceptHoldMilliseconds = 50
        startVisibleSession(in: rig, fullText: " hello world again")
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
        rig.visualContext.onInjectedContextReady?(rig.focusProvider.snapshot.context!.identity)

        _ = rig.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .navigation))
        XCTAssertNil(rig.coordinator.deferredScreenContextRetirement)

        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(rig.coordinator.state, .idle)
        XCTAssertNil(rig.interactionState.activeSession)
        XCTAssertTrue(rig.engine.requests.isEmpty)
    }

    func test_inputThatEndsTheTailDuringTheHoldSettlesTheDeferredChange() {
        // A mismatched keystroke retires the tail and schedules its own prediction; the emoji picker
        // takes over input. Either way a deferral waking later would cancel newer work or predict
        // under the picker, so it must be settled on the spot.
        let cases: [(name: String, prepare: (CoordinatorRig) -> Void, event: CapturedInputEvent)] = [
            ("mismatched typing", { _ in }, CotabbyTestFixtures.inputEvent(kind: .textMutation, characters: "x")),
            ("emoji picker", { $0.coordinator.inlineCommandObserver = { _ in true } },
             CotabbyTestFixtures.inputEvent(kind: .textMutation, characters: ":"))
        ]
        for testCase in cases {
            let rig = retained(makeCoordinatorRig())
            testCase.prepare(rig)
            startVisibleSession(in: rig, fullText: " hello world again")
            XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion(), testCase.name)
            rig.visualContext.onInjectedContextReady?(rig.focusProvider.snapshot.context!.identity)
            XCTAssertNotNil(rig.coordinator.deferredScreenContextRetirement, testCase.name)

            _ = rig.coordinator.handleInputEvent(testCase.event)

            XCTAssertNil(rig.interactionState.activeSession, testCase.name)
            XCTAssertNil(rig.coordinator.deferredScreenContextRetirement, testCase.name)
        }
    }

    func test_matchingTypingDuringTheHoldStillRetiresTheTailOnceItLapses() async {
        // A keystroke that matches the tail keeps it alive, so it must not settle the deferred
        // change: on a navigation with identical field identity, that change is the only thing that
        // retires the old conversation's tail.
        let rig = retained(makeCoordinatorRig())
        rig.coordinator.postAcceptHoldMilliseconds = 50
        startVisibleSession(in: rig, fullText: " hello world again")
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
        rig.visualContext.onInjectedContextReady?(rig.focusProvider.snapshot.context!.identity)

        _ = rig.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .textMutation, characters: " "))
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, "world again", "The keystroke matched")
        XCTAssertNotNil(rig.coordinator.deferredScreenContextRetirement)

        await waitUntil { rig.overlayController.hideReasons.last == "Overlay hidden because screen context changed." }
    }

    func test_settingsChangeDuringTheHoldSettlesTheDeferredChange() {
        // The settings reset restarts visual context and schedules its own prediction; a deferred
        // change left pending would wake and retire that replacement.
        let rig = retained(makeCoordinatorRig())
        startVisibleSession(in: rig, fullText: " hello world again")
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
        rig.visualContext.onInjectedContextReady?(rig.focusProvider.snapshot.context!.identity)
        XCTAssertNotNil(rig.coordinator.deferredScreenContextRetirement)

        rig.coordinator.handleSuggestionSettingsChange(CotabbyTestFixtures.settingsSnapshot(debounceMilliseconds: 2))

        XCTAssertNil(rig.coordinator.deferredScreenContextRetirement)
    }

    func test_screenContextChangeAfterTheFinalChunkKeepsOwningTab() {
        // After the last word there is no session, only the post-exhaustion window that keeps a fast
        // follow-up Tab from reaching the host. An undeferred retirement hides the (already hidden)
        // overlay, which ends that window and hands Tab back mid burst.
        let rig = retained(makeCoordinatorRig(snapshot: finalChunkSnapshot))
        startVisibleSession(in: rig, fullText: " today")
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
        XCTAssertTrue(rig.coordinator.postExhaustionAcceptanceState.isArmed)

        rig.visualContext.onInjectedContextReady?(rig.focusProvider.snapshot.context!.identity)

        XCTAssertTrue(rig.coordinator.postExhaustionAcceptanceState.isArmed)
        XCTAssertTrue(rig.inputMonitor.shouldConsumeAcceptKeyProvider(), "A follow-up Tab must still be owned")
    }

    func test_screenContextChangeAfterTheHoldLapsesRetiresTheTailImmediately() {
        let rig = retained(makeCoordinatorRig())
        startVisibleSession(in: rig, fullText: " hello world again")
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
        rig.coordinator.lastAcceptanceAt = ProcessInfo.processInfo.systemUptime - 1

        rig.visualContext.onInjectedContextReady?(rig.focusProvider.snapshot.context!.identity)

        XCTAssertFalse(rig.coordinator.overlayState.isVisible)
        XCTAssertNil(rig.interactionState.activeSession)
        XCTAssertNil(rig.coordinator.deferredScreenContextRetirement)
    }

    private func visibleText(of state: OverlayState) -> String? {
        guard case let .visible(text, _, _) = state else { return nil }
        return text
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

    /// The inserter re-checks focus against the app the coordinator validated, so the coordinator must
    /// hand over that snapshot's app, not something read later.
    func test_acceptHandsTheValidatedFieldsAppToTheInserter() {
        let rig = retained(makeCoordinatorRig(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(
                bundleIdentifier: "com.example.Validated", processIdentifier: 4242, precedingText: "Hello"
            )
        ))
        startVisibleSession(in: rig, fullText: " world again")

        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())

        XCTAssertEqual(
            rig.inserter.targets,
            [InsertionTarget(processIdentifier: 4242, bundleIdentifier: "com.example.Validated")]
        )
    }

    // MARK: - Correction acceptance

    func test_correctionPassesThroughWhenTheLiveWordNoLongerMatchesTheOffer() {
        let rig = retained(makeCoordinatorRig(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Please recieve ")
        ))
        startCorrectionSession(in: rig)
        // A keystroke slipped in between the offer and this Tab. Deleting the offered word's length
        // now would eat the wrong characters, so the key must pass through untouched.
        rig.setFocusedInput(CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Please recieve i"))

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
        XCTAssertEqual(rig.coordinator.speculativeBet.expected?.precedingText, "what's on your mind today")
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
        XCTAssertNil(rig.coordinator.speculativeBet.expected, "The kill switch must skip the speculative request")
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
        rig.setFocusedInput(CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello world"))
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

        XCTAssertEqual(rig.coordinator.state, .ready)
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, "rld again")
        XCTAssertEqual(rig.interactionState.activeSession?.fullText, "rld again")
        XCTAssertTrue(rig.engine.requests.isEmpty)
    }

    func test_anchorReuseKillSwitchForcesAFreshGeneration() async {
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello wo")
        let rig = retained(makeCoordinatorRig(snapshot: snapshot))
        rig.coordinator.userDefaults.set(true, forKey: SuggestionCoordinator.anchorReuseDisabledDefaultsKey)
        recordCachedSuggestion(" world again", after: "Hello", for: snapshot, in: rig)

        await rig.coordinator.generateFromCurrentFocus(workID: rig.coordinator.currentWorkID)

        XCTAssertNotEqual(rig.coordinator.state, .ready)
        await waitUntil { rig.engine.requests.count == 1 }
        XCTAssertEqual(rig.engine.requests.first?.prefixText, "Hello wo")
    }

    /// A speculative post-acceptance result carries a generation older than the live one by
    /// construction; it must still apply when the live content matches the signature it was
    /// built against, and must consume the exemption.
    func test_applyAcceptsSpeculativeResultWhenContentSignatureMatches() async {
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello world ")
        let rig = retained(makeCoordinatorRig(snapshot: snapshot))
        rig.coordinator.speculativeBet.place(expecting: FocusedInputContext(snapshot: snapshot, generation: 1))

        await rig.coordinator.apply(result: speculativeResult, workID: rig.coordinator.currentWorkID)

        XCTAssertEqual(rig.coordinator.state, .ready)
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, "from here on")
        XCTAssertNil(rig.coordinator.speculativeBet.expected, "the exemption is single-use")
    }

    /// A speculative result can finish before the host publishes the keystroke it was built for.
    /// It must be held, not dropped: once the publish matches, the poll does not request again, so
    /// a dropped result would leave that keystroke without a suggestion.
    func test_speculativeResultFinishingBeforeThePublishIsParkedThenShown() async {
        let unpublished = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello worl")
        let published = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello world ")
        let rig = retained(makeCoordinatorRig(snapshot: unpublished))
        rig.coordinator.speculativeBet.place(expecting: FocusedInputContext(snapshot: published, generation: 999))

        await rig.coordinator.apply(result: speculativeResult, workID: rig.coordinator.currentWorkID)
        guard case .parked = rig.coordinator.speculativeBet else {
            return XCTFail("an early speculative result is held")
        }
        XCTAssertNotEqual(rig.overlayController.hideReasons.last, "Overlay hidden because a stale result was dropped.")

        // The host publishes the speculated text; replaying the parked result shows it.
        rig.setFocusedInput(published)
        let parked = try? XCTUnwrap(rig.coordinator.speculativeBet.takeParked())
        await rig.coordinator.apply(result: parked!.result, workID: parked!.workID)
        XCTAssertEqual(rig.coordinator.state, .ready)
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, "from here on")
        XCTAssertEqual(rig.coordinator.speculativeBet, .idle)
    }

    /// A reschedule that abandons the bet discards its parked result for good.
    func test_parkedSpeculativeResultIsDiscardedWithItsBet() async {
        let rig = retained(makeCoordinatorRig(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello worl")
        ))
        rig.coordinator.speculativeBet.place(expecting: FocusedInputContext(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello world "), generation: 999
        ))
        await rig.coordinator.apply(result: speculativeResult, workID: rig.coordinator.currentWorkID)
        guard case .parked = rig.coordinator.speculativeBet else {
            return XCTFail("the early result should be parked")
        }

        rig.coordinator.schedulePrediction()
        XCTAssertEqual(rig.coordinator.speculativeBet, .idle)
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
