import Foundation
import XCTest
@testable import Cotabby

/// Locks the coordinator's keyboard and environment entry points: which keystrokes route into
/// acceptance, which tear the session down, which reschedule generation, and how focus and
/// permission changes start or stop the pipeline. These paths decide whether typing feels
/// instant or haunted, so every branch asserts the user-visible cleanup it leaves behind.
@MainActor
final class SuggestionCoordinatorInputTests: XCTestCase {
    private var rigs: [CoordinatorRig] = []

    override func tearDown() {
        rigs.removeAll()
        super.tearDown()
    }

    private func retained(_ rig: CoordinatorRig) -> CoordinatorRig {
        rigs.append(rig)
        return rig
    }

    /// Starts a live session with visible ghost text, the precondition for the with-session paths.
    private func startSession(in rig: CoordinatorRig, fullText: String = " world") {
        let context = FocusedInputContext(snapshot: rig.focusProvider.snapshot.context!, generation: 1)
        let session = rig.interactionState.startSession(fullText: fullText, liveContext: context, latency: 0.05)
        rig.overlayController.showSuggestion(
            session.remainingText,
            geometry: CotabbyTestFixtures.overlayGeometry()
        )
    }

    // MARK: - Key routing

    func test_acceptanceEventRoutesIntoAcceptance() {
        let rig = retained(makeCoordinatorRig())
        startSession(in: rig)

        let consumed = rig.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .acceptance))

        XCTAssertTrue(consumed, "Tab with a live session must be consumed")
        XCTAssertEqual(rig.inserter.insertedChunks, [" world"])
    }

    func test_fullAcceptanceEventCommitsTheWholeSuggestion() {
        let rig = retained(makeCoordinatorRig())
        startSession(in: rig, fullText: " world again")

        let consumed = rig.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .fullAcceptance))

        XCTAssertTrue(consumed)
        XCTAssertEqual(rig.inserter.insertedChunks, [" world again"])
    }

    func test_disabledEnvironmentSwallowsNothingAndDisablesPipeline() {
        let rig = retained(makeCoordinatorRig(
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(isGloballyEnabled: false)
        ))

        let consumed = rig.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .textMutation, characters: "a"))

        XCTAssertFalse(consumed)
        guard case .disabled = rig.coordinator.state else {
            return XCTFail("Expected disabled, got \(rig.coordinator.state)")
        }
    }

    // MARK: - Emoji picker priority

    func test_emojiCaptureStandsTheSuggestionPipelineDown() {
        let rig = retained(makeCoordinatorRig())
        startSession(in: rig)
        rig.coordinator.emojiInputObserver = { _ in true }

        let consumed = rig.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .textMutation, characters: ":"))

        XCTAssertFalse(consumed, "Consumption is the tap's job; the coordinator only stands down")
        XCTAssertNil(rig.interactionState.activeSession)
        XCTAssertFalse(rig.coordinator.overlayState.isVisible)
        XCTAssertTrue(rig.overlayController.hideReasons.contains { $0.contains("emoji picker") })
    }

    // MARK: - Typing against a live session

    func test_typingTheExpectedCharactersAdvancesTheSession() {
        let rig = retained(makeCoordinatorRig())
        startSession(in: rig, fullText: " world")

        let consumed = rig.coordinator.handleInputEvent(
            CotabbyTestFixtures.inputEvent(kind: .textMutation, characters: " "),
            with: rig.interactionState.activeSession!
        )

        XCTAssertFalse(consumed)
        XCTAssertNotNil(rig.interactionState.activeSession, "A matching keystroke advances, never kills")
        guard case let .ready(text, _) = rig.coordinator.state else {
            return XCTFail("Expected ready, got \(rig.coordinator.state)")
        }
        XCTAssertEqual(text, "world")
    }

    func test_divergentTypingInvalidatesAndReschedules() async {
        let rig = retained(makeCoordinatorRig())
        startSession(in: rig, fullText: " world")

        let consumed = rig.coordinator.handleInputEvent(
            CotabbyTestFixtures.inputEvent(kind: .textMutation, characters: "x"),
            with: rig.interactionState.activeSession!
        )

        XCTAssertFalse(consumed)
        XCTAssertNil(rig.interactionState.activeSession)
        XCTAssertFalse(rig.coordinator.overlayState.isVisible)

        // The reschedule waits for the host to publish the keystroke; simulate the publish by
        // changing the live preceding text so the poll's change gate fires.
        let typedSnapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hellox")
        rig.focusProvider.snapshot = FocusSnapshot(
            applicationName: typedSnapshot.applicationName,
            bundleIdentifier: typedSnapshot.bundleIdentifier,
            capability: .supported,
            context: typedSnapshot,
            inspection: nil
        )
        await waitUntil("Divergent typing never rescheduled generation") {
            rig.coordinator.state == .debouncing || rig.engine.requests.count == 1
        }
    }

    func test_navigationDismissesTheSessionWithoutRescheduling() {
        let rig = retained(makeCoordinatorRig())
        startSession(in: rig)

        _ = rig.coordinator.handleInputEvent(
            CotabbyTestFixtures.inputEvent(kind: .navigation),
            with: rig.interactionState.activeSession!
        )

        XCTAssertNil(rig.interactionState.activeSession)
        XCTAssertEqual(rig.coordinator.state, .idle)
        XCTAssertFalse(rig.coordinator.overlayState.isVisible)
    }

    func test_shortcutMutationInvalidatesTheSession() {
        let rig = retained(makeCoordinatorRig())
        startSession(in: rig)

        _ = rig.coordinator.handleInputEvent(
            CotabbyTestFixtures.inputEvent(kind: .shortcutMutation, characters: "z"),
            with: rig.interactionState.activeSession!
        )

        XCTAssertNil(rig.interactionState.activeSession)
        XCTAssertFalse(rig.coordinator.overlayState.isVisible)
    }

    func test_otherEventsLeaveTheSessionAlone() {
        let rig = retained(makeCoordinatorRig())
        startSession(in: rig)

        _ = rig.coordinator.handleInputEvent(
            CotabbyTestFixtures.inputEvent(kind: .other),
            with: rig.interactionState.activeSession!
        )

        XCTAssertNotNil(rig.interactionState.activeSession)
        XCTAssertTrue(rig.coordinator.overlayState.isVisible)
    }

    // MARK: - Typing with no session

    func test_typingWithoutASessionClearsStaleUIAndReschedules() async {
        let rig = retained(makeCoordinatorRig())
        rig.overlayController.showSuggestion(" stale", geometry: CotabbyTestFixtures.overlayGeometry())

        let consumed = rig.coordinator.handleInputEvent(
            CotabbyTestFixtures.inputEvent(kind: .textMutation, characters: "a")
        )

        XCTAssertFalse(consumed)
        XCTAssertFalse(rig.coordinator.overlayState.isVisible)

        let typedSnapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Helloa")
        rig.focusProvider.snapshot = FocusSnapshot(
            applicationName: typedSnapshot.applicationName,
            bundleIdentifier: typedSnapshot.bundleIdentifier,
            capability: .supported,
            context: typedSnapshot,
            inspection: nil
        )
        await waitUntil("Keystroke never rescheduled generation") {
            rig.coordinator.state == .debouncing || !rig.engine.requests.isEmpty
        }
    }

    func test_dismissalWithoutASessionEndsIdleWithoutRescheduling() async {
        let rig = retained(makeCoordinatorRig())
        rig.overlayController.showSuggestion(" stale", geometry: CotabbyTestFixtures.overlayGeometry())

        _ = rig.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .dismissal))

        XCTAssertEqual(rig.coordinator.state, .idle)
        XCTAssertFalse(rig.coordinator.overlayState.isVisible)
        // Escape must not trigger a fresh generation.
        try? await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertTrue(rig.engine.requests.isEmpty)
    }

    // MARK: - Focus snapshot changes

    func test_focusChangeToSupportedFieldStartsVisualContextCapture() {
        let rig = retained(makeCoordinatorRig())

        rig.coordinator.handleFocusSnapshotChange(rig.focusProvider.snapshot)

        XCTAssertEqual(rig.visualContext.startedSessions.count, 2, "Both gate sites start the OCR session")
    }

    func test_focusChangeInFastModeSkipsVisualContextCapture() {
        let rig = retained(makeCoordinatorRig(
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(debounceMilliseconds: 1, isFastModeEnabled: true)
        ))

        rig.coordinator.handleFocusSnapshotChange(rig.focusProvider.snapshot)

        XCTAssertTrue(rig.visualContext.startedSessions.isEmpty, "Fast mode skips screenshot/OCR work entirely")
    }

    func test_focusChangeToDisabledAppPreservesVisualContextSession() {
        let rig = retained(makeCoordinatorRig(
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(
                disabledAppBundleIdentifiers: ["com.example.TestApp"],
                debounceMilliseconds: 1
            )
        ))

        rig.coordinator.handleFocusSnapshotChange(rig.focusProvider.snapshot)

        guard case .disabled = rig.coordinator.state else {
            return XCTFail("Expected disabled, got \(rig.coordinator.state)")
        }
        XCTAssertTrue(rig.visualContext.cancelCalls.isEmpty, "Focus-level disables are transient; keep the OCR session")
    }

    func test_handleSupportedSnapshot_recoversFromDisabledAndClearsOnFieldChange() async {
        let rig = retained(makeCoordinatorRig())
        // Anchor the interaction state to the current app so a different pid below reads as a
        // genuine field switch (a fresh state treats the first observation as unchanged).
        _ = rig.interactionState.materializeContext(from: rig.focusProvider.snapshot.context!)
        rig.coordinator.state = .disabled("old reason")

        let otherApp = CotabbyTestFixtures.focusedInputSnapshot(
            processIdentifier: 456,
            precedingText: "Hi"
        )
        let otherFocus = FocusSnapshot(
            applicationName: otherApp.applicationName,
            bundleIdentifier: otherApp.bundleIdentifier,
            capability: .supported,
            context: otherApp,
            inspection: nil
        )
        rig.coordinator.handleSupportedSnapshot(otherFocus)

        XCTAssertEqual(rig.coordinator.state, .idle)
        XCTAssertTrue(rig.overlayController.hideReasons.contains { $0.contains("focused field changed") })

        // The field switch also prewarms the routed engine for the new surface, with the sentinel
        // generation that can never trip the stale-result drop logic.
        await waitUntil("Engine was never prewarmed for the new field") {
            !rig.engine.prewarmedRequests.isEmpty
        }
        XCTAssertEqual(rig.engine.prewarmedRequests.first?.generation, 0)
    }

    func test_handleSupportedSnapshot_withoutContextDisablesOutright() {
        let rig = retained(makeCoordinatorRig())
        let bareSnapshot = FocusSnapshot(
            applicationName: "TestApp",
            bundleIdentifier: "com.example.TestApp",
            capability: .unsupported("No focused text input"),
            context: nil,
            inspection: nil
        )

        rig.coordinator.handleSupportedSnapshot(bareSnapshot)

        guard case .disabled = rig.coordinator.state else {
            return XCTFail("Expected disabled, got \(rig.coordinator.state)")
        }
        XCTAssertEqual(rig.visualContext.cancelCalls, [true])
    }

    func test_handleSupportedSnapshot_withActiveSessionReconcilesInsteadOfClearing() {
        let rig = retained(makeCoordinatorRig())
        startSession(in: rig)

        rig.coordinator.handleSupportedSnapshot(rig.focusProvider.snapshot)

        XCTAssertNotNil(rig.interactionState.activeSession, "An unchanged field must keep the live session")
    }

    // MARK: - Permission changes

    func test_permissionChange_revokedScreenRecordingCancelsVisualContext() {
        let rig = retained(makeCoordinatorRig())
        rig.permissionProvider.screenRecordingGranted = false

        rig.coordinator.handlePermissionChange()

        XCTAssertEqual(rig.visualContext.cancelCalls, [true])
    }

    func test_suppressedSyntheticInput_logsWithoutMutatingState() {
        let rig = retained(makeCoordinatorRig())
        let stateBefore = rig.coordinator.state

        rig.coordinator.handleSuppressedSyntheticInput()

        XCTAssertEqual(rig.coordinator.state, stateBefore)
    }
}
