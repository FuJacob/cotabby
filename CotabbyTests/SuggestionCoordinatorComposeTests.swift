import Combine
import CoreGraphics
import Foundation
import XCTest
@testable import Cotabby

/// Tests `SuggestionCoordinator+Compose` end to end with fakes for every collaborator.
///
/// Compose Mode is single-Tab streaming: the first Tab opens a stream and each piece is typed
/// straight into the focused field via `SuggestionInserter.insert`. Esc/focus change/typing
/// cancels the stream; already-typed pieces stay. These tests lock in that contract.
@MainActor
final class SuggestionCoordinatorComposeTests: XCTestCase {
    private static var retainedCoordinators: [SuggestionCoordinator] = []

    override func tearDown() async throws {
        Self.retainedCoordinators.removeAll()
        try await super.tearDown()
    }

    // MARK: - First Tab: streaming starts

    func test_firstTab_inComposeMode_streamsPiecesIntoTheField() async {
        let pieces = ["Hello", " team,", "\n", "Thanks."]
        let finishedExpectation = expectation(description: "stream finished")
        let env = makeEnvironment(
            mode: .compose,
            engineBehavior: .success(pieces: pieces),
            onStreamFinished: { finishedExpectation.fulfill() }
        )

        _ = env.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .acceptance))
        await fulfillment(of: [finishedExpectation], timeout: 1.0)
        await Task.yield()

        XCTAssertEqual(env.engine.composeStreamCallCount, 1)
        XCTAssertEqual(env.inserter.insertedPieces, pieces)
        XCTAssertNil(env.coordinator.interactionState.activeComposeSession)
    }

    func test_firstTab_inComposeMode_returnsTrueToConsumeTab() {
        let env = makeEnvironment(
            mode: .compose,
            engineBehavior: .success(pieces: ["only"])
        )

        let consumed = env.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .acceptance))

        XCTAssertTrue(consumed)
    }

    func test_firstTab_inAutocompleteMode_doesNotInvokeComposeStream() async {
        let env = makeEnvironment(
            mode: .autocomplete,
            engineBehavior: .success(pieces: ["should not run"])
        )

        _ = env.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .acceptance))
        await Task.yield()
        await Task.yield()

        XCTAssertEqual(env.engine.composeStreamCallCount, 0)
        XCTAssertEqual(env.inserter.insertedPieces, [])
    }

    // MARK: - Subsequent Tabs while streaming

    func test_secondTab_whileStreaming_isAbsorbedWithoutRestartingTheStream() async {
        let env = makeEnvironment(
            mode: .compose,
            engineBehavior: .blocked(initialPieces: ["partial"])
        )

        _ = env.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .acceptance))
        for _ in 0..<10 { await Task.yield() }

        let consumedSecondTab = env.coordinator.handleInputEvent(
            CotabbyTestFixtures.inputEvent(kind: .acceptance)
        )

        XCTAssertTrue(consumedSecondTab, "second Tab during streaming should be absorbed, not passed through")
        XCTAssertEqual(env.engine.composeStreamCallCount, 1, "second Tab must not start a second stream")
    }

    // MARK: - Cancellation

    func test_escape_duringStreaming_cancelsAndKeepsTypedText() async {
        let env = makeEnvironment(
            mode: .compose,
            engineBehavior: .blocked(initialPieces: ["Hel", "lo"])
        )

        _ = env.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .acceptance))
        for _ in 0..<15 { await Task.yield() }

        _ = env.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .dismissal))
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(env.inserter.insertedPieces, ["Hel", "lo"], "already-typed pieces stay in the field")
        XCTAssertNil(env.coordinator.interactionState.activeComposeSession)
    }

    func test_textMutationDuringStreaming_cancelsTheStream() async {
        let env = makeEnvironment(
            mode: .compose,
            engineBehavior: .blocked(initialPieces: ["streamed"])
        )

        _ = env.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .acceptance))
        for _ in 0..<15 { await Task.yield() }

        _ = env.coordinator.handleInputEvent(
            CotabbyTestFixtures.inputEvent(kind: .textMutation, characters: "x")
        )
        for _ in 0..<10 { await Task.yield() }

        XCTAssertNil(env.coordinator.interactionState.activeComposeSession)
    }

    func test_navigationDuringStreaming_cancelsTheStream() async {
        let env = makeEnvironment(
            mode: .compose,
            engineBehavior: .blocked(initialPieces: ["typed"])
        )

        _ = env.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .acceptance))
        for _ in 0..<15 { await Task.yield() }

        _ = env.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .navigation))
        for _ in 0..<10 { await Task.yield() }

        XCTAssertNil(env.coordinator.interactionState.activeComposeSession)
    }

    func test_focusChangeDuringStreaming_cancelsTheStream() async {
        let env = makeEnvironment(
            mode: .compose,
            engineBehavior: .blocked(initialPieces: ["before"])
        )

        _ = env.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .acceptance))
        for _ in 0..<15 { await Task.yield() }

        env.focusModel.publish(snapshot: focusSnapshot(processIdentifier: 999, elementIdentifier: "different"))
        for _ in 0..<10 { await Task.yield() }

        XCTAssertNil(env.coordinator.interactionState.activeComposeSession)
    }

    func test_modeChangeToAutocomplete_duringStreaming_cancelsTheStream() async {
        let env = makeEnvironment(
            mode: .compose,
            engineBehavior: .blocked(initialPieces: ["before"])
        )

        _ = env.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .acceptance))
        for _ in 0..<15 { await Task.yield() }

        env.settings.publish(snapshot: snapshot(mode: .autocomplete))
        for _ in 0..<10 { await Task.yield() }

        XCTAssertNil(env.coordinator.interactionState.activeComposeSession)
    }

    // MARK: - Failure paths

    func test_engineFailure_surfacesFailedStateAndClearsSession() async {
        let finishedExpectation = expectation(description: "stream finished")
        let env = makeEnvironment(
            mode: .compose,
            engineBehavior: .failure(SuggestionClientError.unavailable("No local model loaded.")),
            onStreamFinished: { finishedExpectation.fulfill() }
        )

        _ = env.coordinator.handleInputEvent(CotabbyTestFixtures.inputEvent(kind: .acceptance))
        await fulfillment(of: [finishedExpectation], timeout: 1.0)
        await Task.yield()

        if case .failed(let message) = env.coordinator.state {
            XCTAssertTrue(message.contains("local model"))
        } else {
            XCTFail("Expected failed state after engine failure, got \(env.coordinator.state)")
        }
        XCTAssertNil(env.coordinator.interactionState.activeComposeSession)
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
        onStreamFinished: (() -> Void)? = nil
    ) -> ComposeTestEnvironment {
        let permissions = FakeSuggestionPermissions()
        let focusModel = FakeFocusModel(initialSnapshot: focusSnapshot())
        let inputMonitor = FakeInputMonitor()
        let overlayController = FakeOverlayController()
        let inserter = FakeSuggestionInserter()
        let engine = FakeSuggestionEngine(behavior: engineBehavior)
        engine.onStreamFinished = onStreamFinished
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
    private(set) var insertedPieces: [String] = []

    func insert(_ suggestion: String) -> Bool {
        insertedPieces.append(suggestion)
        return true
    }

    func typeDraft(_ draft: String, shouldContinue: @escaping @MainActor () -> Bool) async -> Bool {
        true
    }
}

@MainActor
private final class FakeSuggestionEngine: SuggestionGenerating {
    enum Behavior {
        /// Yields all pieces then finishes immediately.
        case success(pieces: [String])
        /// Yields `initialPieces`, then parks the stream until the underlying task is cancelled.
        /// Lets tests trigger cancellation events (Esc, focus change, etc.) and verify cleanup.
        case blocked(initialPieces: [String])
        /// Throws immediately. Tests use `onStreamFinished` to wait for the failure to propagate.
        case failure(Error)
    }

    private let behavior: Behavior
    var onStreamFinished: (() -> Void)?
    private(set) var composeStreamCallCount = 0

    init(behavior: Behavior) {
        self.behavior = behavior
    }

    func generateSuggestion(for request: SuggestionRequest) async throws -> SuggestionResult {
        throw SuggestionClientError.unavailable("Autocomplete not exercised here.")
    }

    func generateCompose(for request: ComposeRequest) async throws -> ComposeResult {
        throw SuggestionClientError.unavailable("Compose Mode streams here; one-shot path unused.")
    }

    func generateComposeStreaming(for request: ComposeRequest) async throws -> AsyncThrowingStream<String, Error> {
        composeStreamCallCount += 1
        let behavior = self.behavior
        let onStreamFinished = self.onStreamFinished

        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                switch behavior {
                case .success(let pieces):
                    for piece in pieces {
                        if Task.isCancelled { break }
                        continuation.yield(piece)
                    }
                    continuation.finish()
                    onStreamFinished?()

                case .blocked(let initialPieces):
                    for piece in initialPieces {
                        if Task.isCancelled { break }
                        continuation.yield(piece)
                    }
                    // Park until the underlying detached task is cancelled by the consumer's
                    // termination handler. Sleeping in small slices keeps `Task.isCancelled`
                    // responsive without burning CPU.
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 10_000_000)
                    }
                    continuation.finish()
                    onStreamFinished?()

                case .failure(let error):
                    continuation.finish(throwing: error)
                    onStreamFinished?()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
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
