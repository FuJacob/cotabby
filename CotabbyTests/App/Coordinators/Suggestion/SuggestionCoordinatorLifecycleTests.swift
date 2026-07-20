import Foundation
import XCTest
@testable import Cotabby

/// Locks the coordinator's lifecycle commands and the settings-change reaction: what gets torn
/// down on stop and model switches, and which settings edits restart the pipeline. A regression
/// here leaks callbacks across shutdown or leaves stale suggestions alive across a model swap.
@MainActor
final class SuggestionCoordinatorLifecycleTests: XCTestCase {
    private var rigs: [CoordinatorRig] = []

    override func tearDown() {
        rigs.removeAll()
        super.tearDown()
    }

    private func retained(_ rig: CoordinatorRig) -> CoordinatorRig {
        rigs.append(rig)
        return rig
    }

    func test_start_reconcilesOutOfAStaleDisabledState() {
        let rig = retained(makeCoordinatorRig())
        rig.coordinator.state = .disabled("stale launch state")

        rig.coordinator.start()

        XCTAssertEqual(rig.coordinator.state, .idle)
    }

    func test_stop_detachesEveryLongLivedCallbackAndHidesTheOverlay() {
        let rig = retained(makeCoordinatorRig())
        // The coordinator wires these at construction; overwriting them here would sever its own
        // overlay-state mirror and fake the assertion below, so verify the wiring instead.
        XCTAssertNotNil(rig.inputMonitor.onEvent, "Construction must install the event callback")
        XCTAssertNotNil(rig.overlayController.onStateChange)
        rig.overlayController.showSuggestion(" ghost", geometry: CotabbyTestFixtures.overlayGeometry())
        XCTAssertTrue(rig.coordinator.overlayState.isVisible)

        rig.coordinator.stop()

        XCTAssertFalse(rig.coordinator.overlayState.isVisible)
        XCTAssertEqual(rig.visualContext.cancelCalls, [true])
        XCTAssertNil(rig.inputMonitor.onEvent, "A leaked event callback outlives shutdown")
        XCTAssertNil(rig.inputMonitor.onSuppressedSyntheticInput)
        XCTAssertNil(rig.overlayController.onStateChange)
        XCTAssertNil(rig.visualContext.onStateChange)
        XCTAssertNil(rig.visualContext.onInjectedContextReady)
    }

    func test_prepareForRuntimeModelSwitch_clearsTheActiveSessionAndOverlay() {
        let rig = retained(makeCoordinatorRig())
        let context = FocusedInputContext(snapshot: rig.focusProvider.snapshot.context!, generation: 1)
        _ = rig.interactionState.startSession(fullText: " world", liveContext: context, latency: 0.05)
        rig.overlayController.showSuggestion(" world", geometry: CotabbyTestFixtures.overlayGeometry())

        rig.coordinator.prepareForRuntimeModelSwitch()

        XCTAssertNil(rig.interactionState.activeSession, "A stale session must not survive a model swap")
        XCTAssertFalse(rig.coordinator.overlayState.isVisible)
        XCTAssertEqual(rig.coordinator.state, .idle)
        XCTAssertEqual(rig.visualContext.cancelCalls, [true])
    }

    func test_settingsChange_identicalSnapshotIsANoOp() {
        let rig = retained(makeCoordinatorRig())
        rig.overlayController.showSuggestion(" keep me", geometry: CotabbyTestFixtures.overlayGeometry())

        rig.coordinator.handleSuggestionSettingsChange(rig.coordinator.settingsSnapshot)

        XCTAssertTrue(rig.coordinator.overlayState.isVisible, "An unchanged snapshot must not reset anything")
    }

    func test_settingsChange_engineSwitchResetsStateAndRestartsThePipeline() {
        let rig = retained(makeCoordinatorRig())
        rig.overlayController.showSuggestion(" stale", geometry: CotabbyTestFixtures.overlayGeometry())

        let switched = CotabbyTestFixtures.settingsSnapshot(
            selectedEngine: .appleIntelligence,
            debounceMilliseconds: 1
        )
        rig.coordinator.handleSuggestionSettingsChange(switched)

        XCTAssertFalse(rig.coordinator.overlayState.isVisible)
        XCTAssertEqual(rig.coordinator.settingsSnapshot, switched)
        // A supported focus environment restarts both visual context and prediction.
        XCTAssertFalse(rig.visualContext.startedSessions.isEmpty)
        XCTAssertEqual(rig.coordinator.state, .debouncing)
    }

    func test_settingsChange_disablingGloballyDoesNotRestartThePipeline() {
        let rig = retained(makeCoordinatorRig())

        let disabled = CotabbyTestFixtures.settingsSnapshot(
            isGloballyEnabled: false,
            debounceMilliseconds: 1
        )
        rig.coordinator.handleSuggestionSettingsChange(disabled)

        XCTAssertNotEqual(rig.coordinator.state, .debouncing, "A disabling change must not schedule generation")
        XCTAssertTrue(rig.visualContext.startedSessions.isEmpty, "No OCR session for a disabled subsystem")
        // The obsolete visual context is still torn down.
        XCTAssertEqual(rig.visualContext.cancelCalls, [true])
    }

    func test_settingsChange_pausingDoesNotRestartThePipeline() {
        let rig = retained(makeCoordinatorRig())

        rig.coordinator.handleSuggestionSettingsChange(
            CotabbyTestFixtures.settingsSnapshot(
                isTemporarilyPaused: true,
                debounceMilliseconds: 1
            )
        )

        XCTAssertNotEqual(rig.coordinator.state, .debouncing)
        XCTAssertTrue(rig.visualContext.startedSessions.isEmpty)
        XCTAssertEqual(rig.visualContext.cancelCalls, [true])
    }
}
