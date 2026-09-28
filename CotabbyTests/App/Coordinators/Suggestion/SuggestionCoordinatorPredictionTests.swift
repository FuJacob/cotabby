import Foundation
import XCTest
@testable import Cotabby

/// Exercises the async half of the coordinator's state machine: debounce scheduling, request
/// build, engine dispatch, and every freshness gate in `apply`. These are the paths that decide
/// whether a model reply ever reaches the screen, so each gate gets a test that proves both the
/// drop and the user-visible cleanup (state + overlay) it must leave behind.
final class SuggestionCoordinatorPredictionTests: SuggestionCoordinatorRigTestCase {
    // MARK: - Happy path

    func test_schedulePrediction_generatesAndPresentsTheSuggestion() async {
        // A word boundary, so the field already supplies the space before the next word.
        let rig = retained(makeCoordinatorRig(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello ")
        ))

        rig.coordinator.schedulePrediction()
        XCTAssertEqual(rig.coordinator.state, .debouncing)

        await waitUntil("Suggestion never became ready") {
            rig.coordinator.state == .ready(text: "world", latency: 0.01)
        }

        guard case let .ready(text, _) = rig.coordinator.state else {
            return XCTFail("Expected ready state")
        }
        // The field already ends with a space, so the ghost carries none: `GhostSpaceBoundary`
        // settles that against the live text, and the stub engine's canned " world" (which never
        // went through the normalizer) is corrected here exactly as a real completion would be.
        XCTAssertEqual(text, "world")
        XCTAssertEqual(rig.overlayController.shownTexts, ["world"])
        XCTAssertTrue(rig.coordinator.overlayState.isVisible)
        XCTAssertEqual(rig.engine.requests.map(\.prefixText), ["Hello "])
        XCTAssertEqual(rig.coordinator.latestRequestID, rig.engine.requests.first?.requestID)
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, "world")
        XCTAssertEqual(rig.coordinator.qualityMetricsStore.counters.shown, 1)
        // The completed round trip feeds the adaptive debounce for this engine only.
        XCTAssertEqual(rig.coordinator.lastLatencyByEngine, [.llamaOpenSource: 10])
    }

    // MARK: - Gates before generation

    func test_schedulePrediction_disabledAppGoesStraightToDisabledState() async {
        let rig = retained(makeCoordinatorRig(
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(
                disabledAppBundleIdentifiers: ["com.example.TestApp"],
                debounceMilliseconds: 1
            )
        ))

        rig.coordinator.schedulePrediction()

        XCTAssertEqual(rig.coordinator.state, .disabled("Cotabby is disabled in TestApp."))
        XCTAssertTrue(rig.engine.requests.isEmpty)
        // The hard-disable path tears down the field-scoped OCR session too.
        XCTAssertEqual(rig.visualContext.cancelCalls, [true])
    }

    func test_generate_emptyFieldEndsIdleWithoutCallingTheEngine() async {
        let rig = retained(makeCoordinatorRig(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "")
        ))

        rig.coordinator.schedulePrediction()
        await waitUntil("Pipeline never settled to idle") { rig.coordinator.state == .idle }

        XCTAssertTrue(rig.engine.requests.isEmpty)
        XCTAssertEqual(rig.overlayController.hideReasons.last, "Overlay hidden because the field has no typed text yet.")
    }

    func test_generate_holdsWithoutCallingTheEngineWhileTheHostShowsItsOwnInlineText() async {
        let rig = retained(makeCoordinatorRig(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(
                precedingText: "The quick brown fox ju",
                hostMarkedTextRange: NSRange(location: 22, length: 3)
            )
        ))

        rig.coordinator.schedulePrediction()
        await waitUntil("Pipeline never settled") { rig.coordinator.isHoldingForHostMarkedText }

        XCTAssertTrue(rig.engine.requests.isEmpty, "No generation while the host owns the spot after the caret")
        XCTAssertEqual(rig.coordinator.state, .idle)
    }

    // MARK: - Freshness gates in apply

    func test_apply_emptyNormalizedResultEndsIdle() async {
        let rig = retained(makeCoordinatorRig())
        rig.engine.resultProvider = { request in
            SuggestionResult(generation: request.generation, rawText: "  ", text: "", latency: 0.01)
        }

        rig.coordinator.schedulePrediction()
        await waitUntil("Pipeline never settled to idle") { rig.coordinator.state == .idle }

        XCTAssertNil(rig.interactionState.activeSession)
        XCTAssertEqual(
            rig.overlayController.hideReasons.last,
            "Overlay hidden because the model returned an empty continuation."
        )
        XCTAssertEqual(rig.coordinator.qualityMetricsStore.counters.suppressedByReason, ["emptyUnattributed": 1])
    }

    func test_apply_emptyResultAlreadyAttributedByTheEngineIsNotCountedTwice() async {
        let rig = retained(makeCoordinatorRig())
        rig.engine.resultProvider = { request in
            SuggestionResult(
                generation: request.generation, rawText: "...", text: "", latency: 0.01,
                suppressionReason: "lowConfidence"
            )
        }

        rig.coordinator.schedulePrediction()
        await waitUntil("Pipeline never settled to idle") {
            rig.overlayController.hideReasons.last == "Overlay hidden because the model returned an empty continuation."
        }

        XCTAssertEqual(
            rig.coordinator.qualityMetricsStore.counters.suppressedByReason,
            [:],
            "The router already counted engine-attributed suppressions"
        )
    }

    func test_apply_staleGenerationIsDroppedWithoutASession() async {
        let rig = retained(makeCoordinatorRig())
        rig.engine.resultProvider = { _ in
            SuggestionResult(generation: 9_999, rawText: " world", text: " world", latency: 0.01)
        }

        rig.coordinator.schedulePrediction()
        await waitUntil("Stale result was never processed") {
            rig.overlayController.hideReasons.contains { $0.contains("stale result") }
        }

        XCTAssertNil(rig.interactionState.activeSession)
        XCTAssertFalse(rig.coordinator.overlayState.isVisible)
        XCTAssertEqual(rig.coordinator.qualityMetricsStore.counters.suppressedByReason, ["discardedStaleContext": 1])
    }

    func test_apply_resultForARetiredWorkIDTouchesNothing() async {
        let rig = retained(makeCoordinatorRig())
        startVisibleSession(in: rig)
        let retiredWorkID = rig.coordinator.currentWorkID
        rig.coordinator.workController.cancelAll()

        await rig.coordinator.apply(
            result: SuggestionResult(generation: 1, rawText: " late", text: " late", latency: 0.5),
            workID: retiredWorkID
        )
        await rig.coordinator.applyFailure("late failure", workID: retiredWorkID)

        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, " world")
        XCTAssertTrue(rig.coordinator.overlayState.isVisible)
        XCTAssertEqual(rig.coordinator.state, .idle)
        XCTAssertTrue(rig.coordinator.lastLatencyByEngine.isEmpty, "A superseded result must not tune the debounce")
    }

    func test_apply_selectedTextDropsTheSuggestion() async {
        let rig = retained(makeCoordinatorRig(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(
                precedingText: "Hello",
                selection: NSRange(location: 2, length: 3)
            )
        ))

        rig.coordinator.schedulePrediction()
        await waitUntil("Pipeline never settled to idle") { rig.coordinator.state == .idle }

        XCTAssertNil(rig.interactionState.activeSession)
        XCTAssertEqual(rig.overlayController.hideReasons.last, "Overlay hidden because text is selected.")
        XCTAssertEqual(rig.coordinator.qualityMetricsStore.counters.suppressedByReason, ["discardedSelection": 1])
    }

    func test_apply_staleAcceptanceEchoIsDroppedBeforeHostPublishesTheInsert() async {
        let rig = retained(makeCoordinatorRig())
        // The regeneration after a final-chunk accept re-proposes the accepted tail while the
        // field still shows the pre-acceptance text: the signature of an unpublished insert.
        rig.coordinator.lastAcceptedTail = AcceptedSuggestionTail(text: " world", precedingText: "Hello")

        rig.coordinator.schedulePrediction()
        await waitUntil("Echo was never dropped") {
            rig.overlayController.hideReasons.contains { $0.contains("echoed the just-accepted") }
        }

        XCTAssertEqual(rig.coordinator.state, .idle)
        XCTAssertNil(rig.interactionState.activeSession)
        XCTAssertNil(rig.coordinator.lastAcceptedTail, "The recorded tail gets exactly one shot")
        XCTAssertEqual(rig.coordinator.qualityMetricsStore.counters.suppressedByReason, ["discardedAcceptEcho": 1])
    }

    // MARK: - Engine failure modes

    func test_engineFailure_surfacesAsFailedState() async {
        struct EngineExploded: Error {}
        let rig = retained(makeCoordinatorRig())
        rig.engine.resultProvider = { _ in throw EngineExploded() }

        rig.coordinator.schedulePrediction()
        await waitUntil("Failure never surfaced") {
            rig.coordinator.state == .failed(EngineExploded().localizedDescription)
        }

        XCTAssertEqual(rig.overlayController.hideReasons.last, "Overlay hidden because generation failed.")
        XCTAssertNil(rig.interactionState.activeSession)
    }

    func test_engineCancellation_isSilentlySwallowed() async {
        let rig = retained(makeCoordinatorRig())
        rig.engine.resultProvider = { _ in throw SuggestionClientError.cancelled }

        rig.coordinator.schedulePrediction()
        await waitUntil("Engine was never called") { rig.engine.requests.count == 1 }
        // Give the post-throw path a beat to (incorrectly) mutate state if it were going to.
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(rig.coordinator.state, .generating, "Cancellation must not surface as failure")
        XCTAssertTrue(rig.overlayController.hideReasons.isEmpty)
    }

    // MARK: - Typo gate

    func test_typoGate_suppressesGenerationForAMisspelledCurrentWord() async {
        let rig = retained(makeCoordinatorRig(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "I typed qzxkvjw "),
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(
                debounceMilliseconds: 1,
                suppressCompletionsOnTypo: true
            )
        ))

        rig.coordinator.schedulePrediction()
        await waitUntil("Typo gate never settled") { rig.coordinator.state == .idle }

        XCTAssertTrue(rig.engine.requests.isEmpty, "A misspelled current word must skip generation")
        XCTAssertEqual(
            rig.overlayController.hideReasons.last,
            "Overlay hidden because the current word looks misspelled."
        )
    }

    func test_typoGate_offersACorrectionSessionInsteadOfGenerating() async {
        let rig = retained(makeCoordinatorRig(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "I typed recieve "),
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(
                debounceMilliseconds: 1,
                suppressCompletionsOnTypo: true,
                offerTypoCorrections: true
            )
        ))

        rig.coordinator.schedulePrediction()
        await waitUntil("Correction was never offered") {
            rig.interactionState.activeSession?.kind.isCorrection == true
        }

        XCTAssertTrue(rig.engine.requests.allSatisfy { $0.prefixText == "I typed receive " },
            "The native correction stays visible while its next words are prepared from corrected text.")
        guard case .ready = rig.coordinator.state else {
            return XCTFail("A correction offer should present as ready, got \(rig.coordinator.state)")
        }
        XCTAssertTrue(rig.coordinator.overlayState.isVisible)
    }

    func test_typoGate_automaticallyFixesACompletedWordAfterSpace() async {
        let rig = retained(makeCoordinatorRig(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "I typed recieve "),
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(
                debounceMilliseconds: 1,
                suppressCompletionsOnTypo: true,
                offerTypoCorrections: true,
                automaticallyFixTypos: true
            )
        ))

        rig.coordinator.schedulePrediction()
        await waitUntil("Automatic correction never ran") { !rig.inserter.replacements.isEmpty }

        XCTAssertEqual(rig.inserter.replacements.count, 1)
        XCTAssertEqual(rig.coordinator.state, .idle)
        XCTAssertTrue(rig.engine.requests.allSatisfy { $0.prefixText == "I typed receive " })
    }

    // MARK: - Environment reconciliation

    func test_reconcileWithCurrentEnvironment_reenablesOnceTheBlockerClears() {
        let rig = retained(makeCoordinatorRig())
        rig.coordinator.disablePredictions(reason: "Test disable")

        rig.coordinator.reconcileWithCurrentEnvironment()
        XCTAssertEqual(rig.coordinator.state, .idle)

        // With a real blocker present the same call must keep predictions disabled.
        rig.coordinator.settingsSnapshot = CotabbyTestFixtures.settingsSnapshot(isGloballyEnabled: false)
        rig.coordinator.reconcileWithCurrentEnvironment()
        XCTAssertEqual(rig.coordinator.state, .disabled("Cotabby is turned off."))
    }

    func test_disablePredictionsPreservingVisualContext_keepsTheOCRSessionAlive() {
        let rig = retained(makeCoordinatorRig())

        rig.coordinator.disablePredictionsPreservingVisualContext(reason: "Text is currently selected.")

        XCTAssertEqual(rig.coordinator.state, .disabled("Text is currently selected."))
        XCTAssertTrue(
            rig.visualContext.cancelCalls.isEmpty,
            "Transient disables must not destroy the field-scoped visual-context session"
        )
    }

    // MARK: - Session reconciliation

    func test_reconcileActiveSession_hidesAStaleOverlayWhenNoSessionExists() {
        let rig = retained(makeCoordinatorRig())
        rig.overlayController.showSuggestion(
            " stale",
            geometry: CotabbyTestFixtures.overlayGeometry()
        )

        rig.coordinator.reconcileActiveSession(with: rig.focusProvider.snapshot)

        XCTAssertFalse(rig.coordinator.overlayState.isVisible)
        XCTAssertEqual(rig.overlayController.hideReasons.last, "Overlay hidden because no ready suggestion remains.")
    }

    func test_reconcileActiveSession_advancesWhenTheUserTypesThroughTheTail() {
        let rig = retained(makeCoordinatorRig())
        let context = FocusedInputContext(snapshot: rig.focusProvider.snapshot.context!, generation: 1)
        _ = rig.interactionState.startSession(fullText: " world", liveContext: context, latency: 0.05)

        // The user typed the next three expected characters; the session must advance, not die.
        setFocusedInput(CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello wo"), in: rig)
        rig.coordinator.reconcileActiveSession(with: rig.focusProvider.snapshot)

        XCTAssertEqual(rig.coordinator.state, .ready(text: "rld", latency: 0.05))
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, "rld")
    }

    func test_reconcileActiveSession_correctionSurvivesUnchangedFieldAndDropsOnEdit() {
        let rig = retained(makeCoordinatorRig(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "I typed recieve ")
        ))
        let context = FocusedInputContext(snapshot: rig.focusProvider.snapshot.context!, generation: 1)
        _ = rig.interactionState.startSession(
            fullText: "receive",
            liveContext: context,
            latency: 0,
            kind: .correction(typoWord: "recieve")
        )
        rig.overlayController.showSuggestion("receive", geometry: CotabbyTestFixtures.overlayGeometry())

        // Unchanged field: the offer stays.
        rig.coordinator.reconcileActiveSession(with: rig.focusProvider.snapshot)
        XCTAssertEqual(rig.interactionState.activeSession?.kind, .correction(typoWord: "recieve"))

        // Any edit to the trailing word drops the offer; the next prediction re-runs the gate.
        setFocusedInput(CotabbyTestFixtures.focusedInputSnapshot(precedingText: "I typed recievex"), in: rig)
        rig.coordinator.reconcileActiveSession(with: rig.focusProvider.snapshot)
        XCTAssertNil(rig.interactionState.activeSession)
        XCTAssertFalse(rig.coordinator.overlayState.isVisible)
    }

    // MARK: - Post-insertion stillness

    func test_accept_layoutEstimatedOverlaySkipsTheSlideAndReAnchorsViaTheEstimator() {
        // TextKit-mirror hosts: the overlay anchor came from the hidden layout estimate, so a
        // width-based slide leaves it a ghost-vs-host font error away from the next estimate and
        // the settle reads as a post-accept jerk. The accept must skip the slide and go through
        // the presenting path, where the layout repair (fed the pending insertion) re-anchors at
        // exactly the position the post-publish estimate will reproduce.
        let rig = retained(makeCoordinatorRig())
        startVisibleSession(in: rig, fullText: " world again", caretQuality: .layoutEstimated)

        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())

        XCTAssertTrue(
            rig.overlayController.advanceInlineCalls.isEmpty,
            "A layout-estimated overlay must never width-slide on accept"
        )
        XCTAssertEqual(rig.overlayController.shownTexts.last, " again", "The estimator path re-presented the tail")
    }

    func test_accept_trustedGeometryStillAttemptsTheSlideFirst() {
        let rig = retained(makeCoordinatorRig())
        startVisibleSession(in: rig, fullText: " world again")

        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())

        XCTAssertEqual(rig.overlayController.advanceInlineCalls.count, 1)
        XCTAssertEqual(rig.overlayController.advanceInlineCalls.first?.remaining, " again")
        XCTAssertEqual(rig.overlayController.advanceInlineCalls.first?.inserted, " world")
    }

    func test_accept_stampsTheAcceptanceAndInvalidatesTransientCaretCaches() {
        // Child-run hosts cache their static-run walk; after our own insert those cached runs
        // predate the inserted chunk and would map the published caret a word left. The accept
        // must invalidate that cache and stamp the acceptance time so the stability gate can
        // scope its backward-drift hold.
        let rig = retained(makeCoordinatorRig())
        startVisibleSession(in: rig, fullText: " world again")

        XCTAssertNil(rig.coordinator.lastAcceptanceAt)
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())

        XCTAssertNotNil(rig.coordinator.lastAcceptanceAt)
        XCTAssertEqual(rig.focusProvider.transientCaretCacheInvalidations, 1)
    }

    func test_reconcileDuringPostInsertionSyncWindow_neverReAnchorsTheOverlay() {
        // The TextEdit accept jitter: Tab inserts " world" and the overlay advances immediately,
        // but the +30ms refresh can read AX BEFORE the host publishes the insert. That snapshot's
        // caret is the pre-insertion one, a full word left of the overlay; re-presenting there
        // jumped the ghost left, and the post-publish poll snapped it back right. While the
        // session is awaiting the publish, reconciles must hold the overlay exactly where it is.
        let rig = retained(makeCoordinatorRig())
        startVisibleSession(in: rig, fullText: " world again")

        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
        XCTAssertEqual(rig.inserter.insertedChunks, [" world"])
        XCTAssertTrue(
            rig.interactionState.isAwaitingPostInsertionSync,
            "An accept must arm the publish sentinel before any reconcile can fire"
        )
        let presentsAfterAccept = rig.overlayController.shownTexts

        // The +30ms refresh racing the publish: the field still shows the PRE-insertion text and
        // caret. The reconciler tolerates the lag; presentation must not re-anchor.
        rig.coordinator.reconcileActiveSession(with: rig.focusProvider.snapshot)

        XCTAssertEqual(
            rig.overlayController.shownTexts,
            presentsAfterAccept,
            "A pre-publish reconcile re-presented the overlay at the stale caret"
        )
        XCTAssertTrue(rig.interactionState.isAwaitingPostInsertionSync, "The sentinel survives the tolerated tick")
        XCTAssertNotNil(rig.interactionState.activeSession)

        // The host publishes: the same reconcile path clears the sentinel and may settle normally.
        setFocusedInput(CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello world"), in: rig)
        rig.coordinator.reconcileActiveSession(with: rig.focusProvider.snapshot)

        XCTAssertFalse(
            rig.interactionState.isAwaitingPostInsertionSync,
            "The publish must lift the hold so genuine caret moves re-anchor again"
        )
        XCTAssertNotNil(rig.interactionState.activeSession, "The session survives the publish settle")
    }

    // MARK: - Cache reset barrier

    func test_resetCachedGenerationContext_barrierRunsTheEngineResetExactlyOnce() async {
        let rig = retained(makeCoordinatorRig())

        rig.coordinator.resetCachedGenerationContext()
        await rig.coordinator.awaitCachedGenerationContextResetIfNeeded()

        XCTAssertEqual(rig.engine.resetCount, 1)
        // A second await without a new reset must not re-run the engine reset.
        await rig.coordinator.awaitCachedGenerationContextResetIfNeeded()
        XCTAssertEqual(rig.engine.resetCount, 1)
    }

    // MARK: - Visual-context-triggered rescheduling

    func test_visualContextReady_reschedulesOnlyForTheSameField() {
        let rig = retained(makeCoordinatorRig())
        let identity = rig.focusProvider.snapshot.context!.identity

        rig.coordinator.schedulePredictionForCurrentFocusIfPossible(matching: identity)
        XCTAssertEqual(rig.coordinator.state, .debouncing, "Same field: OCR readiness reschedules")

        rig.coordinator.cancelPredictionWork()
        rig.coordinator.state = .idle
        let otherIdentity = FocusedInputIdentity(
            elementIdentifier: identity.elementIdentifier,
            focusChangeSequence: identity.focusChangeSequence &+ 1
        )
        rig.coordinator.schedulePredictionForCurrentFocusIfPossible(matching: otherIdentity)
        XCTAssertEqual(rig.coordinator.state, .idle, "A different field must not reschedule")
    }

    // MARK: - Unsupported snapshots during reconciliation

    func test_reconcileActiveSession_unsupportedSnapshotInvalidatesTheTail() {
        let rig = retained(makeCoordinatorRig())
        startVisibleSession(in: rig)

        rig.coordinator.reconcileActiveSession(with: FocusSnapshot(
            applicationName: "TestApp",
            bundleIdentifier: "com.example.TestApp",
            capability: .blocked("Text is currently selected."),
            context: nil
        ))

        XCTAssertNil(rig.interactionState.activeSession)
        XCTAssertFalse(rig.coordinator.overlayState.isVisible)
        XCTAssertEqual(rig.overlayController.hideReasons.last, "Text is currently selected.")
    }

    func test_reconcileActiveSession_toleratesOneUnsupportedPollRightAfterAnAccept() {
        // Browser editors can report "no usable field" for a single poll right after a synthetic
        // insert. While the insert is unpublished the tail must survive that blip.
        let rig = retained(makeCoordinatorRig())
        startVisibleSession(in: rig, fullText: " world again")
        XCTAssertTrue(rig.coordinator.acceptCurrentSuggestion())
        XCTAssertTrue(rig.interactionState.isAwaitingPostInsertionSync)

        rig.coordinator.reconcileActiveSession(with: FocusSnapshot(
            applicationName: "TestApp",
            bundleIdentifier: "com.example.TestApp",
            capability: .unsupported("No focused text input"),
            context: nil
        ))

        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, " again")
        XCTAssertTrue(rig.coordinator.overlayState.isVisible)
    }

    // MARK: - Teardown helpers

    func test_disablePredictions_repeatedReasonSkipsTheRedundantTeardown() async {
        let rig = retained(makeCoordinatorRig())

        rig.coordinator.disablePredictions(reason: "Cotabby is disabled in TestApp.")
        rig.coordinator.disablePredictions(reason: "Cotabby is disabled in TestApp.")
        XCTAssertEqual(
            rig.visualContext.cancelCalls,
            [true],
            "Every keystroke in a blocked field routes here; the second call must be a no-op"
        )

        rig.coordinator.disablePredictions(reason: "Cotabby is turned off.")
        XCTAssertEqual(rig.visualContext.cancelCalls, [true, true], "A new reason is a real transition")
        XCTAssertEqual(rig.coordinator.state, .disabled("Cotabby is turned off."))
        await rig.coordinator.awaitCachedGenerationContextResetIfNeeded()
        XCTAssertEqual(rig.engine.resetCount, 1, "Superseded resets are cancelled; only the newest barrier runs")
    }

    func test_disablePredictions_sameReasonStillTearsDownAVisibleSession() {
        let rig = retained(makeCoordinatorRig())
        rig.coordinator.disablePredictions(reason: "Cotabby is disabled in TestApp.")
        startVisibleSession(in: rig)

        rig.coordinator.disablePredictions(reason: "Cotabby is disabled in TestApp.")

        XCTAssertNil(rig.interactionState.activeSession)
        XCTAssertFalse(rig.coordinator.overlayState.isVisible)
        XCTAssertEqual(rig.visualContext.cancelCalls, [true, true])
    }

    func test_clearSuggestion_dropsDiagnosticsOnlyWhenAsked() {
        let rig = retained(makeCoordinatorRig())
        startVisibleSession(in: rig)
        rig.coordinator.latestGenerationNumber = 3
        rig.coordinator.latestRequestID = "req_kept"
        rig.coordinator.lastAcceptedTail = AcceptedSuggestionTail(text: " world", precedingText: "Hello")

        rig.coordinator.clearSuggestion()

        XCTAssertNil(rig.interactionState.activeSession)
        XCTAssertNil(rig.coordinator.lastAcceptedTail, "Any teardown retires the accepted-tail echo guard")
        XCTAssertEqual(rig.coordinator.latestGenerationNumber, 3)
        XCTAssertEqual(rig.coordinator.latestRequestID, "req_kept")

        rig.coordinator.clearSuggestion(clearDiagnostics: true)

        XCTAssertNil(rig.coordinator.latestGenerationNumber)
        XCTAssertNil(rig.coordinator.latestRequestID, "The next session must not inherit this request_id")
    }

    func test_cancelPredictionWork_retiresWorkAndTheSpeculativeExemption() {
        let rig = retained(makeCoordinatorRig())
        rig.coordinator.schedulePrediction()
        let workID = rig.coordinator.currentWorkID
        rig.coordinator.pendingSpeculativeContext = FocusedInputContext(
            snapshot: rig.focusProvider.snapshot.context!, generation: 1
        )

        rig.coordinator.cancelPredictionWork()

        XCTAssertNotEqual(rig.coordinator.currentWorkID, workID)
        XCTAssertNil(rig.coordinator.pendingSpeculativeContext)
    }

    func test_hasSuggestionArtifactsToClear_ignoresIdleAndDisabledStates() {
        let rig = retained(makeCoordinatorRig())
        let cases: [(state: SuggestionDebugState, expected: Bool)] = [
            (.idle, false),
            (.disabled("off"), false),
            (.debouncing, true),
            (.generating, true),
            (.failed("boom"), true)
        ]
        for (state, expected) in cases {
            rig.coordinator.state = state
            XCTAssertEqual(rig.coordinator.hasSuggestionArtifactsToClear, expected, "state \(state)")
        }

        rig.coordinator.state = .idle
        rig.overlayController.showSuggestion(" stale", geometry: CotabbyTestFixtures.overlayGeometry())
        XCTAssertTrue(rig.coordinator.hasSuggestionArtifactsToClear, "A visible overlay always needs clearing")
    }

    // MARK: - Clipboard preface pinning

    func test_pinnedClipboardContext_isNilWhenTheFeatureIsDisabled() {
        let rig = retained(makeCoordinatorRig(
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(isClipboardContextEnabled: false, debounceMilliseconds: 1)
        ))
        rig.clipboardFilter.filtered = "copied text"

        XCTAssertNil(rig.coordinator.pinnedClipboardContext(rawContext: rig.focusProvider.snapshot.context!))
        XCTAssertNil(rig.coordinator.clipboardPrefaceMemo, "A disabled feature must not memoize anything")
    }

    func test_pinnedClipboardContext_keepsAnAcceptedVerdictForTheFieldSession() {
        let rig = retained(makeCoordinatorRig())
        let raw = rig.focusProvider.snapshot.context!
        rig.clipboardFilter.filtered = "first verdict"
        XCTAssertEqual(rig.coordinator.pinnedClipboardContext(rawContext: raw), "first verdict")

        // Re-filtering would flip the prompt head and collapse the engine's reusable KV prefix.
        rig.clipboardFilter.filtered = "second verdict"
        XCTAssertEqual(rig.coordinator.pinnedClipboardContext(rawContext: raw), "first verdict")
    }

    func test_pinnedClipboardContext_reevaluatesOnANewCopyOrAFieldSwitch() {
        let rig = retained(makeCoordinatorRig())
        let raw = rig.focusProvider.snapshot.context!
        rig.clipboardFilter.filtered = "first verdict"
        _ = rig.coordinator.pinnedClipboardContext(rawContext: raw)

        rig.clipboardFilter.filtered = "after copy"
        rig.clipboardProvider.currentChangeCount += 1
        XCTAssertEqual(rig.coordinator.pinnedClipboardContext(rawContext: raw), "after copy")

        rig.clipboardFilter.filtered = "after field switch"
        let otherField = CotabbyTestFixtures.focusedInputSnapshot(focusChangeSequence: raw.focusChangeSequence + 1)
        XCTAssertEqual(rig.coordinator.pinnedClipboardContext(rawContext: otherField), "after field switch")
    }

    func test_pinnedClipboardContext_keepsReevaluatingANilVerdict() {
        let rig = retained(makeCoordinatorRig())
        let raw = rig.focusProvider.snapshot.context!
        rig.clipboardFilter.filtered = nil
        XCTAssertNil(rig.coordinator.pinnedClipboardContext(rawContext: raw))

        // Adding nothing cannot destabilize the prompt head, and more typing may make it relevant.
        rig.clipboardFilter.filtered = "now relevant"
        XCTAssertEqual(rig.coordinator.pinnedClipboardContext(rawContext: raw), "now relevant")
    }

    func test_fieldSwitchDropsThePinnedClipboardVerdict() {
        let rig = retained(makeCoordinatorRig())
        _ = rig.interactionState.materializeContext(from: rig.focusProvider.snapshot.context!)
        rig.clipboardFilter.filtered = "pinned"
        _ = rig.coordinator.pinnedClipboardContext(rawContext: rig.focusProvider.snapshot.context!)
        XCTAssertNotNil(rig.coordinator.clipboardPrefaceMemo)

        let otherApp = CotabbyTestFixtures.focusedInputSnapshot(processIdentifier: 456)
        setFocusedInput(otherApp, in: rig)
        rig.coordinator.handleSupportedSnapshot(rig.focusProvider.snapshot)

        XCTAssertNil(rig.coordinator.clipboardPrefaceMemo)
    }
}
