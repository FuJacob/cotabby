import XCTest
@testable import Cotabby

/// Tests for `LivePreviewModel`, the Advanced pane's live preview sandbox state machine.
///
/// These lock down the user-visible behavior independent of any real engine: a completed generation
/// surfaces as ghost text plus a latency, Tab commits the ghost into the user's text, Esc drops it,
/// and an engine error surfaces without leaving a stale ghost. The model is driven with a zero
/// debounce so the debounced generation runs on the next tick instead of after the production delay.
@MainActor
final class LivePreviewModelTests: XCTestCase {

    func test_generation_populatesGhostAndLatency() async throws {
        let model = makeModel(engine: StubEngine(behavior: .success("world")))

        model.userDidEdit("Hello ")
        try await waitUntil { model.hasGhost }

        XCTAssertEqual(model.ghost, "world")
        XCTAssertFalse(model.isGenerating)
        XCTAssertEqual(model.lastLatencyMilliseconds, 50)
        XCTAssertNil(model.lastError)
    }

    func test_acceptGhost_commitsGhostIntoUserText() async throws {
        let model = makeModel(engine: StubEngine(behavior: .success("world")))

        model.userDidEdit("Hello ")
        try await waitUntil { model.hasGhost }

        model.acceptGhost()

        XCTAssertEqual(model.userText, "Hello world")
        XCTAssertTrue(model.ghost.isEmpty)
    }

    func test_dismissGhost_clearsGhost() async throws {
        let model = makeModel(engine: StubEngine(behavior: .success("world")))

        model.userDidEdit("Hello ")
        try await waitUntil { model.hasGhost }

        model.dismissGhost()

        XCTAssertTrue(model.ghost.isEmpty)
        XCTAssertFalse(model.isGenerating)
    }

    func test_engineError_surfacesAndLeavesNoGhost() async throws {
        let model = makeModel(engine: StubEngine(behavior: .failure(StubEngineError.boom)))

        model.userDidEdit("Hello ")
        try await waitUntil { model.lastError != nil }

        XCTAssertTrue(model.ghost.isEmpty)
        XCTAssertFalse(model.isGenerating)
    }

    // MARK: - Helpers

    private func makeModel(engine: any SuggestionGenerating) -> LivePreviewModel {
        let suiteName = "cotabby.test.livePreview.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let settings = SuggestionSettingsModel(configuration: .standard, userDefaults: defaults)
        return LivePreviewModel(
            suggestionSettings: settings,
            suggestionEngine: engine,
            configuration: .standard,
            debounceMilliseconds: 0
        )
    }

    /// Polls a main-actor condition until true or a timeout, sleeping between checks so the model's
    /// debounced generation task gets to run on the main actor.
    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("Condition not met within \(timeout)s")
                return
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

private enum StubEngineError: Error {
    case boom
}

/// Minimal `SuggestionGenerating` stub: returns a canned result or throws. Local to this file so it
/// does not collide with the differently-shaped stubs in the coordinator/router tests.
@MainActor
private final class StubEngine: SuggestionGenerating {
    enum Behavior {
        case success(String)
        case failure(Error)
    }

    let behavior: Behavior

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func generateSuggestion(for request: SuggestionRequest) async throws -> SuggestionResult {
        switch behavior {
        case .success(let text):
            return SuggestionResult(generation: request.generation, rawText: text, text: text, latency: 0.05)
        case .failure(let error):
            throw error
        }
    }

    func resetCachedGenerationContext() async {}
}
