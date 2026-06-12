import Foundation
import XCTest
@testable import Cotabby

/// Exercises the async half of the coordinator's state machine: debounce scheduling, request
/// build, engine dispatch, and every freshness gate in `apply`. These are the paths that decide
/// whether a model reply ever reaches the screen, so each gate gets a test that proves both the
/// drop and the user-visible cleanup (state + overlay) it must leave behind.
@MainActor
final class SuggestionCoordinatorPredictionTests: XCTestCase {
    private var rigs: [CoordinatorRig] = []

    override func tearDown() {
        rigs.removeAll()
        super.tearDown()
    }

    private func retained(_ rig: CoordinatorRig) -> CoordinatorRig {
        rigs.append(rig)
        return rig
    }

    // MARK: - Happy path

    func test_schedulePrediction_generatesAndPresentsTheSuggestion() async {
        let rig = retained(makeCoordinatorRig())

        rig.coordinator.schedulePrediction()
        XCTAssertEqual(rig.coordinator.state, .debouncing)

        await waitUntil("Suggestion never became ready") {
            if case .ready = rig.coordinator.state { return true }
            return false
        }

        guard case let .ready(text, _) = rig.coordinator.state else {
            return XCTFail("Expected ready state")
        }
        XCTAssertEqual(text, " world")
        XCTAssertEqual(rig.overlayController.shownTexts, [" world"])
        XCTAssertTrue(rig.coordinator.overlayState.isVisible)
        XCTAssertEqual(rig.engine.requests.count, 1)
        XCTAssertEqual(rig.engine.requests.first?.prefixText.isEmpty, false)
        XCTAssertNotNil(rig.coordinator.latestRequestID)
        XCTAssertNotNil(rig.interactionState.activeSession)
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

        guard case .disabled = rig.coordinator.state else {
            return XCTFail("Expected disabled state, got \(rig.coordinator.state)")
        }
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
        XCTAssertTrue(rig.overlayController.hideReasons.contains {
            $0.contains("no typed text yet")
        })
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
        XCTAssertTrue(rig.overlayController.hideReasons.contains {
            $0.contains("empty continuation")
        })
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
        XCTAssertTrue(rig.overlayController.hideReasons.contains {
            $0.contains("text is selected")
        })
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
    }

    // MARK: - Engine failure modes

    func test_engineFailure_surfacesAsFailedState() async {
        struct EngineExploded: Error {}
        let rig = retained(makeCoordinatorRig())
        rig.engine.resultProvider = { _ in throw EngineExploded() }

        rig.coordinator.schedulePrediction()
        await waitUntil("Failure never surfaced") {
            if case .failed = rig.coordinator.state { return true }
            return false
        }

        XCTAssertTrue(rig.overlayController.hideReasons.contains {
            $0.contains("generation failed")
        })
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
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "I typed qzxkvjw"),
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(
                debounceMilliseconds: 1,
                suppressCompletionsOnTypo: true
            )
        ))

        rig.coordinator.schedulePrediction()
        await waitUntil("Typo gate never settled") { rig.coordinator.state == .idle }

        XCTAssertTrue(rig.engine.requests.isEmpty, "A misspelled current word must skip generation")
        XCTAssertTrue(rig.overlayController.hideReasons.contains {
            $0.contains("looks misspelled")
        })
    }

    func test_typoGate_offersACorrectionSessionInsteadOfGenerating() async {
        let rig = retained(makeCoordinatorRig(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "I typed recieve"),
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

        XCTAssertTrue(rig.engine.requests.isEmpty, "Corrections are native; no model generation runs")
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
        XCTAssertEqual(rig.coordinator.latestAcceptanceAction?.hasPrefix("Automatically corrected") ?? false, true)
        XCTAssertTrue(rig.engine.requests.isEmpty)
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
        guard case .disabled = rig.coordinator.state else {
            return XCTFail("Expected disabled, got \(rig.coordinator.state)")
        }
    }

    func test_disablePredictionsPreservingVisualContext_keepsTheOCRSessionAlive() {
        let rig = retained(makeCoordinatorRig())

        rig.coordinator.disablePredictionsPreservingVisualContext(reason: "Text is currently selected.")

        guard case .disabled = rig.coordinator.state else {
            return XCTFail("Expected disabled, got \(rig.coordinator.state)")
        }
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
    }

    func test_reconcileActiveSession_advancesWhenTheUserTypesThroughTheTail() {
        let rig = retained(makeCoordinatorRig())
        let context = FocusedInputContext(snapshot: rig.focusProvider.snapshot.context!, generation: 1)
        _ = rig.interactionState.startSession(fullText: " world", liveContext: context, latency: 0.05)

        // The user typed the next three expected characters; the session must advance, not die.
        let typedSnapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello wo")
        rig.focusProvider.snapshot = FocusSnapshot(
            applicationName: typedSnapshot.applicationName,
            bundleIdentifier: typedSnapshot.bundleIdentifier,
            capability: .supported,
            context: typedSnapshot,
            inspection: nil
        )
        rig.coordinator.reconcileActiveSession(with: rig.focusProvider.snapshot)

        guard case let .ready(text, _) = rig.coordinator.state else {
            return XCTFail("Expected ready state, got \(rig.coordinator.state)")
        }
        XCTAssertEqual(text, "rld")
        XCTAssertNotNil(rig.interactionState.activeSession)
    }

    func test_reconcileActiveSession_correctionSurvivesUnchangedFieldAndDropsOnEdit() {
        let rig = retained(makeCoordinatorRig(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "I typed recieve")
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
        XCTAssertNotNil(rig.interactionState.activeSession)

        // Any edit to the trailing word drops the offer; the next prediction re-runs the gate.
        let editedSnapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "I typed recievex")
        let editedFocus = FocusSnapshot(
            applicationName: editedSnapshot.applicationName,
            bundleIdentifier: editedSnapshot.bundleIdentifier,
            capability: .supported,
            context: editedSnapshot,
            inspection: nil
        )
        rig.coordinator.reconcileActiveSession(with: editedFocus)
        XCTAssertNil(rig.interactionState.activeSession)
        XCTAssertFalse(rig.coordinator.overlayState.isVisible)
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
}
