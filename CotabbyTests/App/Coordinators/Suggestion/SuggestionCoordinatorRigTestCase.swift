import Foundation
import XCTest
@testable import Cotabby

/// Shared lifetime handling for coordinator suites that build on `makeCoordinatorRig`.
///
/// The rig factory keeps every fixture graph alive for the process (the macOS 15 isolated-deinit
/// workaround), so nothing ends a coordinator's debounce tasks, host-publish polls, or Combine
/// subscriptions at deinit. Without an explicit teardown, a late task from one test could mutate
/// shared doubles while the next test runs. Suites register each rig through `retained(_:)` and
/// this base class stops it and cancels its lifetime subscriptions after the test body finishes.
@MainActor
class SuggestionCoordinatorRigTestCase: XCTestCase {
    private var trackedRigs: [CoordinatorRig] = []

    override func tearDown() async throws {
        await MainActor.run {
            for rig in trackedRigs {
                rig.coordinator.stop()
                // These subscriptions normally end at deinit; retained fixtures need explicit cancellation.
                rig.coordinator.cancellables.removeAll()
            }
            trackedRigs.removeAll()
        }
        try await super.tearDown()
    }

    /// Registers a rig for teardown and returns it, so call sites stay one expression.
    func retained(_ rig: CoordinatorRig) -> CoordinatorRig {
        trackedRigs.append(rig)
        return rig
    }

    /// Replaces the rig's focused field without publishing a focus event, mimicking a host that
    /// has updated AX before Cotabby's poll or publisher notices.
    func setFocusedInput(_ raw: FocusedInputSnapshot, capability: FocusCapability = .supported, in rig: CoordinatorRig) {
        rig.focusProvider.snapshot = FocusSnapshot(
            applicationName: raw.applicationName,
            bundleIdentifier: raw.bundleIdentifier,
            capability: capability,
            context: raw
        )
    }

    /// Starts a live session on the rig's current field and shows its tail, the precondition for
    /// every acceptance and with-session input path.
    @discardableResult
    func startVisibleSession(
        in rig: CoordinatorRig,
        fullText: String = " world",
        caretQuality: CaretGeometryQuality = .exact
    ) -> ActiveSuggestionSession {
        let context = FocusedInputContext(snapshot: rig.focusProvider.snapshot.context!, generation: 1)
        let session = rig.interactionState.startSession(fullText: fullText, liveContext: context, latency: 0.05)
        rig.overlayController.showSuggestion(
            session.remainingText,
            geometry: CotabbyTestFixtures.overlayGeometry(caretQuality: caretQuality)
        )
        return session
    }
}
