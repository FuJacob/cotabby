import Combine
import CoreGraphics
import Foundation
import XCTest
@testable import Cotabby

/// Tests `SuggestionCoordinator+Compose` end to end with fakes for every collaborator.
///
/// Most coordinator tests in the autocomplete path live inside `SuggestionInteractionState`
/// helpers; Compose's orchestration is new enough that those state helpers cannot prove the
/// behavior reviewers actually care about: first Tab generates, second Tab types, focus changes
/// cancel mid-flight. The fakes below are all kept in this file so the contract under test stays
/// readable as one unit.
@MainActor
final class SuggestionCoordinatorComposeTests: XCTestCase {
    private static var retainedCoordinators: [SuggestionCoordinator] = []

    override func tearDown() async throws {
        Self.retainedCoordinators.removeAll()
        try await super.tearDown()
    }

    // MARK: - First Tab: generation

    func test_firstTab_inComposeMode_callsGenerateComposeAndShowsPreview() async {
        let generateExpectation = expectation(description: "generateCompose called")
        let showPreviewExpectation = expectation(description: "showComposePreview called")
        let env = makeEnvironment(
            mode: .compose,
            engineBehavior: .success(composeResult(text: "Hello team.")),
            onGenerateCalled: { generateExpectation.fulfill() },
            onShowComposePreview: { showPreviewExpectation.fulfill() }
        )

        _ = env.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .acceptance))
        await fulfillment(of: [generateExpectation, showPreviewExpectation], timeout: 1.0)

        XCTAssertEqual(env.engine.composeCallCount, 1)
        XCTAssertEqual(env.overlayController.composePreviewText, "Hello team.")
        XCTAssertNotNil(env.coordinator.interactionState.activeComposeSession)
    }

    func test_firstTab_inComposeMode_returnsTrueToConsumeTab() {
        let env = makeEnvironment(
            mode: .compose,
            engineBehavior: .success(composeResult(text: "draft"))
        )

        let consumed = env.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .acceptance))

        XCTAssertTrue(consumed)
    }

    func test_firstTab_inAutocompleteMode_doesNotInvokeComposePath() async {
        let env = makeEnvironment(
            mode: .autocomplete,
            engineBehavior: .success(composeResult(text: "should not run"))
        )

        _ = env.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .acceptance))
        // Yield to let any spurious Task progress.
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(env.engine.composeCallCount, 0)
        XCTAssertNil(env.coordinator.interactionState.activeComposeSession)
    }

    // MARK: - Second Tab: acceptance

    func test_secondTab_withActiveDraft_callsTypeDraftAndClearsSession() async {
        let generateExpectation = expectation(description: "generateCompose called")
        let typeExpectation = expectation(description: "typeDraft called")
        let env = makeEnvironment(
            mode: .compose,
            engineBehavior: .success(composeResult(text: "Typed draft.")),
            onGenerateCalled: { generateExpectation.fulfill() },
            onTypeDraftCalled: { typeExpectation.fulfill() }
        )

        // First Tab — generate.
        _ = env.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .acceptance))
        await fulfillment(of: [generateExpectation], timeout: 1.0)

        // Second Tab — accept.
        _ = env.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .acceptance))
        await fulfillment(of: [typeExpectation], timeout: 1.0)

        XCTAssertEqual(env.inserter.typedDrafts, ["Typed draft."])
        XCTAssertNil(env.coordinator.interactionState.activeComposeSession)
    }

    // MARK: - Cancellation

    func test_escape_inComposeMode_clearsActiveSession() async {
        let env = await makeEnvironmentWithReadyDraft(draftText: "Hello.")

        _ = env.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .dismissal))

        XCTAssertNil(env.coordinator.interactionState.activeComposeSession)
        XCTAssertEqual(env.inserter.typedDrafts, [])
    }

    func test_textMutationDuringPreview_clearsActiveSession() async {
        let env = await makeEnvironmentWithReadyDraft(draftText: "Hello.")

        _ = env.coordinator.handleInputEvent(
            CotabbyTestFixtures.inputEvent(kind: .textMutation, characters: "x")
        )

        XCTAssertNil(env.coordinator.interactionState.activeComposeSession)
    }

    func test_navigationDuringPreview_clearsActiveSession() async {
        let env = await makeEnvironmentWithReadyDraft(draftText: "Hello.")

        _ = env.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .navigation))

        XCTAssertNil(env.coordinator.interactionState.activeComposeSession)
    }

    func test_focusChange_duringPreview_clearsActiveSession() async {
        let env = await makeEnvironmentWithReadyDraft(draftText: "Hello.")

        env.focusModel.publish(snapshot: focusSnapshot(processIdentifier: 999, elementIdentifier: "different"))
        await Task.yield()

        XCTAssertNil(env.coordinator.interactionState.activeComposeSession)
    }

    func test_modeChangeToAutocomplete_clearsActiveSession() async {
        let env = await makeEnvironmentWithReadyDraft(draftText: "Hello.")

        env.settings.publish(snapshot: snapshot(mode: .autocomplete))
        await Task.yield()

        XCTAssertNil(env.coordinator.interactionState.activeComposeSession)
    }

    // MARK: - Failure paths

    func test_emptyDraft_returnsToIdleAndHidesOverlay() async {
        let generateExpectation = expectation(description: "generateCompose called")
        let env = makeEnvironment(
            mode: .compose,
            engineBehavior: .success(composeResult(text: "   \n  ")),
            onGenerateCalled: { generateExpectation.fulfill() }
        )

        _ = env.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .acceptance))
        await fulfillment(of: [generateExpectation], timeout: 1.0)
        // Empty-draft handling is fully synchronous after `generateCompose` resolves; yield once
        // so the awaiting `await applyComposeResult` runs.
        await Task.yield()

        XCTAssertNil(env.coordinator.interactionState.activeComposeSession)
        if case .idle = env.coordinator.state {
            // expected
        } else {
            XCTFail("Expected idle state after empty compose result, got \(env.coordinator.state)")
        }
    }

    func test_engineFailure_surfacesFailedState() async {
        let generateExpectation = expectation(description: "generateCompose called")
        let env = makeEnvironment(
            mode: .compose,
            engineBehavior: .failure(SuggestionClientError.unavailable("Compose Mode requires tabby-depth-1.")),
            onGenerateCalled: { generateExpectation.fulfill() }
        )

        _ = env.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .acceptance))
        await fulfillment(of: [generateExpectation], timeout: 1.0)
        await Task.yield()

        if case .failed(let message) = env.coordinator.state {
            XCTAssertTrue(message.contains("tabby-depth-1"))
        } else {
            XCTFail("Expected failed state after engine failure, got \(env.coordinator.state)")
        }
    }

    // MARK: - Test environment

    private struct ComposeTestEnvironment {
        let coordinator: SuggestionCoordinator
        let permissions: FakeSuggestionPermissions
        let focusModel: FakeFocusModel
        let inputMonitor: FakeInputMonitor
        let overlayController: FakeOverlayController
        let inserter: FakeSuggestionInserter
        let engine: FakeSuggestionEngine
        let settings: FakeSuggestionSettings
        let clipboard: FakeClipboardContextProvider
        let visualContext: FakeVisualContextCoordinator
        let composeCollector: FakeComposeContextCollector
    }

    private func makeEnvironment(
        mode: SuggestionInteractionMode,
        engineBehavior: FakeSuggestionEngine.Behavior,
        onGenerateCalled: (() -> Void)? = nil,
        onShowComposePreview: (() -> Void)? = nil,
        onTypeDraftCalled: (() -> Void)? = nil
    ) -> ComposeTestEnvironment {
        let permissions = FakeSuggestionPermissions()
        let focusModel = FakeFocusModel(initialSnapshot: focusSnapshot())
        let inputMonitor = FakeInputMonitor()
        let overlayController = FakeOverlayController()
        overlayController.onShowComposePreview = onShowComposePreview
        let inserter = FakeSuggestionInserter()
        inserter.onTypeDraftCalled = onTypeDraftCalled
        let engine = FakeSuggestionEngine(behavior: engineBehavior)
        engine.onComposeCalled = onGenerateCalled
        let settings = FakeSuggestionSettings(initialSnapshot: snapshot(mode: mode))
        let clipboard = FakeClipboardContextProvider()
        let visualContext = FakeVisualContextCoordinator()
        let composeCollector = FakeComposeContextCollector()

        let interactionState = SuggestionInteractionState()
        let workController = SuggestionWorkController()
        let coordinator = SuggestionCoordinator(
            permissionManager: permissions,
            focusModel: focusModel,
            inputMonitor: inputMonitor,
            overlayController: overlayController,
            suggestionInserter: inserter,
            suggestionEngine: engine,
            suggestionSettings: settings,
            clipboardContextProvider: clipboard,
            clipboardRelevanceFilter: FakeClipboardRelevanceFilter(),
            visualContextCoordinator: visualContext,
            composeContextCollector: composeCollector,
            interactionState: interactionState,
            workController: workController,
            configuration: .standard,
            userDefaults: isolatedUserDefaults()
        )
        Self.retainedCoordinators.append(coordinator)
        return ComposeTestEnvironment(
            coordinator: coordinator,
            permissions: permissions,
            focusModel: focusModel,
            inputMonitor: inputMonitor,
            overlayController: overlayController,
            inserter: inserter,
            engine: engine,
            settings: settings,
            clipboard: clipboard,
            visualContext: visualContext,
            composeCollector: composeCollector
        )
    }

    /// Spins up an environment, drives a first Tab through it, and waits for the compose preview
    /// to be ready. Cancellation tests use this so they only have to assert post-conditions.
    private func makeEnvironmentWithReadyDraft(draftText: String) async -> ComposeTestEnvironment {
        let showPreviewExpectation = expectation(description: "showComposePreview called")
        let env = makeEnvironment(
            mode: .compose,
            engineBehavior: .success(composeResult(text: draftText)),
            onShowComposePreview: { showPreviewExpectation.fulfill() }
        )

        _ = env.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .acceptance))
        await fulfillment(of: [showPreviewExpectation], timeout: 1.0)
        return env
    }

    private func snapshot(mode: SuggestionInteractionMode) -> SuggestionSettingsSnapshot {
        SuggestionSettingsSnapshot(
            isGloballyEnabled: true,
            disabledAppBundleIdentifiers: [],
            selectedInteractionMode: mode,
            selectedEngine: .llamaOpenSource,
            selectedWordCountPreset: .sevenToTwelve,
            isClipboardContextEnabled: false,
            userName: "Tester",
            userTags: [],
            debounceMilliseconds: 50,
            focusPollIntervalMilliseconds: 50,
            isMultiLineEnabled: false
        )
    }

    private func focusSnapshot(
        processIdentifier: Int32 = 123,
        elementIdentifier: String = "field"
    ) -> FocusSnapshot {
        let inputSnapshot = CotabbyTestFixtures.focusedInputSnapshot(
            processIdentifier: processIdentifier,
            elementIdentifier: elementIdentifier
        )
        return FocusSnapshot(
            applicationName: inputSnapshot.applicationName,
            bundleIdentifier: inputSnapshot.bundleIdentifier,
            capability: .supported,
            context: inputSnapshot,
            inspection: nil
        )
    }

    private func composeResult(text: String) -> ComposeResult {
        ComposeResult(generation: 1, rawText: text, text: text, latency: 0.05)
    }

    private func isolatedUserDefaults() -> UserDefaults {
        let suiteName = "SuggestionCoordinatorComposeTests-\(UUID().uuidString)"
        guard let userDefaults = UserDefaults(suiteName: suiteName) else {
            return .standard
        }
        userDefaults.removePersistentDomain(forName: suiteName)
        return userDefaults
    }
}

// MARK: - Fakes

@MainActor
private final class FakeSuggestionPermissions: SuggestionPermissionProviding {
    var inputMonitoringGranted = true
    var screenRecordingGranted = true
    private let inputMonitoringSubject = PassthroughSubject<Bool, Never>()
    private let screenRecordingSubject = PassthroughSubject<Bool, Never>()

    var inputMonitoringGrantedPublisher: AnyPublisher<Bool, Never> {
        inputMonitoringSubject.eraseToAnyPublisher()
    }
    var screenRecordingGrantedPublisher: AnyPublisher<Bool, Never> {
        screenRecordingSubject.eraseToAnyPublisher()
    }
}

@MainActor
private final class FakeFocusModel: SuggestionFocusProviding {
    private(set) var snapshot: FocusSnapshot
    private let subject: CurrentValueSubject<FocusSnapshot, Never>

    init(initialSnapshot: FocusSnapshot) {
        snapshot = initialSnapshot
        subject = CurrentValueSubject(initialSnapshot)
    }

    var snapshotPublisher: AnyPublisher<FocusSnapshot, Never> {
        subject.eraseToAnyPublisher()
    }

    func refreshNow() {}

    func publish(snapshot: FocusSnapshot) {
        self.snapshot = snapshot
        subject.send(snapshot)
    }
}

@MainActor
private final class FakeInputMonitor: SuggestionInputMonitoring {
    var onEvent: ((CapturedInputEvent) -> Bool)?
    var onSuppressedSyntheticInput: (() -> Void)?
}

@MainActor
private final class FakeOverlayController: SuggestionOverlayControlling {
    var state: OverlayState = .hidden(reason: "test idle")
    var onStateChange: ((OverlayState) -> Void)?
    var onShowComposePreview: (() -> Void)?
    private(set) var composePreviewText: String?
    private(set) var hideReasons: [String] = []

    func showSuggestion(_ text: String, geometry: SuggestionOverlayGeometry) {
        state = .visible(text: text, geometry: geometry)
        onStateChange?(state)
    }

    func showComposePreview(_ text: String, geometry: SuggestionOverlayGeometry) {
        composePreviewText = text
        state = .composePreview(text: text, geometry: geometry)
        onStateChange?(state)
        onShowComposePreview?()
    }

    func hide(reason: String) {
        hideReasons.append(reason)
        state = .hidden(reason: reason)
        onStateChange?(state)
    }
}

@MainActor
private final class FakeSuggestionInserter: SuggestionInserting {
    var lastErrorMessage: String?
    var onTypeDraftCalled: (() -> Void)?
    private(set) var typedDrafts: [String] = []

    func insert(_ suggestion: String) -> Bool { true }

    func typeDraft(_ draft: String, shouldContinue: @escaping @MainActor () -> Bool) async -> Bool {
        typedDrafts.append(draft)
        onTypeDraftCalled?()
        return true
    }
}

@MainActor
private final class FakeSuggestionEngine: SuggestionGenerating {
    enum Behavior {
        case success(ComposeResult)
        case failure(Error)
    }

    private let behavior: Behavior
    var onComposeCalled: (() -> Void)?
    private(set) var composeCallCount = 0

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func generateSuggestion(for request: SuggestionRequest) async throws -> SuggestionResult {
        throw SuggestionClientError.unavailable("Autocomplete not exercised here.")
    }

    func generateCompose(for request: ComposeRequest) async throws -> ComposeResult {
        composeCallCount += 1
        onComposeCalled?()
        switch behavior {
        case .success(let result):
            return ComposeResult(
                generation: request.generation,
                rawText: result.rawText,
                text: result.text,
                latency: result.latency
            )
        case .failure(let error):
            throw error
        }
    }

    func resetCachedGenerationContext() async {}
}

@MainActor
private final class FakeSuggestionSettings: SuggestionSettingsProviding {
    private(set) var snapshot: SuggestionSettingsSnapshot
    private let subject: CurrentValueSubject<SuggestionSettingsSnapshot, Never>

    init(initialSnapshot: SuggestionSettingsSnapshot) {
        snapshot = initialSnapshot
        subject = CurrentValueSubject(initialSnapshot)
    }

    var snapshotPublisher: AnyPublisher<SuggestionSettingsSnapshot, Never> {
        subject.eraseToAnyPublisher()
    }

    func publish(snapshot: SuggestionSettingsSnapshot) {
        self.snapshot = snapshot
        subject.send(snapshot)
    }
}

@MainActor
private final class FakeClipboardContextProvider: ClipboardContextProviding {
    var contextToReturn: String?
    var currentChangeCount: Int = 0
    func currentContext() -> String? { contextToReturn }
}

@MainActor
private final class FakeClipboardRelevanceFilter: ClipboardRelevanceFiltering {
    func filter(clipboard: String?, pasteboardChangeCount: Int, precedingText: String) -> String? {
        clipboard
    }
}

@MainActor
private final class FakeVisualContextCoordinator: VisualContextCoordinating {
    var status: VisualContextStatus = .idle
    var latestExcerpt: String?
    var onStateChange: ((VisualContextStatus, String?) -> Void)?
    var onInjectedContextReady: ((FocusedInputIdentity) -> Void)?

    func startSessionIfNeeded(for snapshotContext: FocusedInputSnapshot) {}
    func cancel(resetState: Bool) {}
    func excerpt(for context: FocusedInputContext) -> String? { nil }
}

@MainActor
private final class FakeComposeContextCollector: ComposeContextCollecting {
    var textToReturn: String = "Surrounding context."
    private(set) var collectCallCount = 0

    func collect(for context: FocusedInputContext) async throws -> ComposeContextCollectionResult {
        collectCallCount += 1
        return ComposeContextCollectionResult(
            text: textToReturn,
            visitedNodeCount: 1,
            retainedTextCount: 1,
            droppedTextCount: 0
        )
    }
}
