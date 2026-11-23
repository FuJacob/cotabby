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

    /// Builds a rig whose engine answers every request with `completion`, runs one prediction, and
    /// waits for its session. Suites that drive real key events start here, because the keys only
    /// mean anything once a suggestion produced by the pipeline is on screen. `configure` runs
    /// before the prediction is scheduled, for doubles that must be in place first.
    func makeRigWithPredictedSession(
        snapshot: FocusedInputSnapshot,
        settingsSnapshot: SuggestionSettingsSnapshot,
        completion: String = "world again tomorrow",
        configure: (CoordinatorRig) -> Void = { _ in }
    ) async -> CoordinatorRig {
        let rig = retained(makeCoordinatorRig(snapshot: snapshot, settingsSnapshot: settingsSnapshot))
        configure(rig)
        rig.engine.resultProvider = { request in
            SuggestionResult(generation: request.generation, rawText: completion, text: completion, latency: 0.01)
        }
        rig.coordinator.schedulePrediction()
        await waitUntil { rig.interactionState.activeSession != nil }
        return rig
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
