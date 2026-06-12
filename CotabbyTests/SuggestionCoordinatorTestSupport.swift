import Combine
import Foundation
import XCTest
@testable import Cotabby

/// Shared, recording test doubles for `SuggestionCoordinator` suites.
///
/// `SuggestionCoordinatorAcceptanceTests` predates this file and keeps its own private stubs;
/// new coordinator suites (prediction, input, lifecycle) build on these so the protocol surface
/// is mocked once. Every double records what the coordinator asked of it, because most of the
/// pipeline's contracts are about *which* boundary was poked, not return values.
@MainActor
final class RigPermissionProvider: SuggestionPermissionProviding {
    var inputMonitoringGranted = true
    var screenRecordingGranted = true

    let inputSubject = PassthroughSubject<Bool, Never>()
    let screenSubject = PassthroughSubject<Bool, Never>()

    var inputMonitoringGrantedPublisher: AnyPublisher<Bool, Never> {
        inputSubject.eraseToAnyPublisher()
    }

    var screenRecordingGrantedPublisher: AnyPublisher<Bool, Never> {
        screenSubject.eraseToAnyPublisher()
    }
}

@MainActor
final class RigFocusProvider: SuggestionFocusProviding {
    var snapshot: FocusSnapshot
    private(set) var refreshCount = 0

    let snapshotSubject = PassthroughSubject<FocusSnapshot, Never>()

    var snapshotPublisher: AnyPublisher<FocusSnapshot, Never> {
        snapshotSubject.eraseToAnyPublisher()
    }

    init(snapshot: FocusSnapshot) {
        self.snapshot = snapshot
    }

    func refreshNow() {
        refreshCount += 1
    }
}

@MainActor
final class RigInputMonitor: SuggestionInputMonitoring {
    var onEvent: ((CapturedInputEvent) -> Bool)?
    var onSuppressedSyntheticInput: (() -> Void)?
    var shouldConsumeAcceptKeyProvider: @MainActor @Sendable () -> Bool = { false }
    private(set) var acceptInterceptionRequests: [Bool] = []

    func setAcceptInterceptionActive(_ active: Bool) {
        acceptInterceptionRequests.append(active)
    }
}

@MainActor
final class RigOverlayController: SuggestionOverlayControlling {
    var state: OverlayState
    var onStateChange: ((OverlayState) -> Void)?
    private(set) var shownTexts: [String] = []
    private(set) var hideReasons: [String] = []

    init(state: OverlayState = .hidden(reason: "initial")) {
        self.state = state
    }

    func showSuggestion(_ text: String, geometry: SuggestionOverlayGeometry) {
        shownTexts.append(text)
        state = .visible(text: text, geometry: geometry, mode: .inline)
        onStateChange?(state)
    }

    func hide(reason: String) {
        hideReasons.append(reason)
        state = .hidden(reason: reason)
        onStateChange?(state)
    }
}

@MainActor
final class RigInserter: SuggestionInserting {
    var lastErrorMessage: String?
    var insertedChunks: [String] = []
    var replacements: [(deleteCount: Int, text: String)] = []
    var shouldInsert = true

    func insert(_ suggestion: String) -> Bool {
        insertedChunks.append(suggestion)
        return shouldInsert
    }

    func replace(deletingUTF16Count: Int, with text: String) -> Bool {
        replacements.append((deletingUTF16Count, text))
        return shouldInsert
    }
}

@MainActor
final class RigSuggestionEngine: SuggestionGenerating {
    /// Provides the result for each generation. The default echoes a fixed continuation with the
    /// request's own generation, which is what a fresh (non-stale) engine reply looks like.
    var resultProvider: (SuggestionRequest) async throws -> SuggestionResult = { request in
        SuggestionResult(generation: request.generation, rawText: " world", text: " world", latency: 0.01)
    }
    private(set) var requests: [SuggestionRequest] = []
    private(set) var resetCount = 0
    private(set) var prewarmedRequests: [SuggestionRequest] = []

    func generateSuggestion(for request: SuggestionRequest) async throws -> SuggestionResult {
        requests.append(request)
        return try await resultProvider(request)
    }

    func resetCachedGenerationContext() async {
        resetCount += 1
    }

    func prewarm(for request: SuggestionRequest) async {
        prewarmedRequests.append(request)
    }
}

@MainActor
final class RigSettingsProvider: SuggestionSettingsProviding {
    var snapshot: SuggestionSettingsSnapshot

    let snapshotSubject = PassthroughSubject<SuggestionSettingsSnapshot, Never>()

    var snapshotPublisher: AnyPublisher<SuggestionSettingsSnapshot, Never> {
        snapshotSubject.eraseToAnyPublisher()
    }

    init(snapshot: SuggestionSettingsSnapshot) {
        self.snapshot = snapshot
    }
}

@MainActor
final class RigClipboardProvider: ClipboardContextProviding {
    var currentChangeCount = 0
    var context: String?

    func currentContext() -> String? {
        context
    }
}

@MainActor
final class RigClipboardFilter: ClipboardRelevanceFiltering {
    var filtered: String?

    func filter(
        clipboard: String?,
        pasteboardChangeCount: Int,
        precedingText: String
    ) -> String? {
        filtered
    }
}

@MainActor
final class RigVisualContextCoordinator: VisualContextCoordinating {
    var status: VisualContextStatus = .idle
    var latestExcerpt: String?
    var onStateChange: ((VisualContextStatus, String?) -> Void)?
    var onInjectedContextReady: ((FocusedInputIdentity) -> Void)?
    private(set) var startedSessions: [FocusedInputSnapshot] = []
    private(set) var cancelCalls: [Bool] = []
    var excerptValue: String?

    func startSessionIfNeeded(for snapshotContext: FocusedInputSnapshot) {
        startedSessions.append(snapshotContext)
    }

    func cancel(resetState: Bool) {
        cancelCalls.append(resetState)
    }

    func excerpt(for context: FocusedInputContext) -> String? {
        excerptValue
    }
}

/// One fully-stubbed coordinator plus handles to every double, so a test can both drive the
/// pipeline and assert which boundaries it touched.
@MainActor
struct CoordinatorRig {
    let coordinator: SuggestionCoordinator
    let permissionProvider: RigPermissionProvider
    let focusProvider: RigFocusProvider
    let inputMonitor: RigInputMonitor
    let overlayController: RigOverlayController
    let inserter: RigInserter
    let engine: RigSuggestionEngine
    let settingsProvider: RigSettingsProvider
    let clipboardProvider: RigClipboardProvider
    let clipboardFilter: RigClipboardFilter
    let visualContext: RigVisualContextCoordinator
    let interactionState: SuggestionInteractionState
}

@MainActor
func makeCoordinatorRig(
    snapshot: FocusedInputSnapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello"),
    capability: FocusCapability = .supported,
    overlayState: OverlayState = .hidden(reason: "initial"),
    settingsSnapshot: SuggestionSettingsSnapshot = CotabbyTestFixtures.settingsSnapshot(debounceMilliseconds: 1)
) -> CoordinatorRig {
    let focusSnapshot = FocusSnapshot(
        applicationName: snapshot.applicationName,
        bundleIdentifier: snapshot.bundleIdentifier,
        capability: capability,
        context: snapshot,
        inspection: nil
    )
    let permissionProvider = RigPermissionProvider()
    let focusProvider = RigFocusProvider(snapshot: focusSnapshot)
    let inputMonitor = RigInputMonitor()
    let overlayController = RigOverlayController(state: overlayState)
    let inserter = RigInserter()
    let engine = RigSuggestionEngine()
    let settingsProvider = RigSettingsProvider(snapshot: settingsSnapshot)
    let clipboardProvider = RigClipboardProvider()
    let clipboardFilter = RigClipboardFilter()
    let visualContext = RigVisualContextCoordinator()
    let interactionState = SuggestionInteractionState()
    let coordinator = SuggestionCoordinator(
        permissionManager: permissionProvider,
        focusModel: focusProvider,
        inputMonitor: inputMonitor,
        overlayController: overlayController,
        suggestionInserter: inserter,
        suggestionEngine: engine,
        suggestionSettings: settingsProvider,
        clipboardContextProvider: clipboardProvider,
        clipboardRelevanceFilter: clipboardFilter,
        visualContextCoordinator: visualContext,
        interactionState: interactionState,
        workController: SuggestionWorkController(),
        configuration: .standard,
        spellChecker: CurrentWordSpellChecker(),
        symSpellCorrector: SymSpellCorrector(preloadLanguage: nil),
        userDefaults: UserDefaults(suiteName: "CotabbyTests.rig.\(UUID().uuidString)") ?? .standard
    )
    return CoordinatorRig(
        coordinator: coordinator,
        permissionProvider: permissionProvider,
        focusProvider: focusProvider,
        inputMonitor: inputMonitor,
        overlayController: overlayController,
        inserter: inserter,
        engine: engine,
        settingsProvider: settingsProvider,
        clipboardProvider: clipboardProvider,
        clipboardFilter: clipboardFilter,
        visualContext: visualContext,
        interactionState: interactionState
    )
}

/// Polls a main-actor condition until it holds or the timeout elapses, yielding to the run loop
/// between checks. The coordinator pipeline hops through Tasks and a debounce timer, so tests
/// await observable state instead of sleeping fixed amounts.
@MainActor
func waitUntil(
    timeout: TimeInterval = 5,
    _ message: @autoclosure () -> String = "Condition not met before timeout",
    file: StaticString = #filePath,
    line: UInt = #line,
    condition: @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else {
            XCTFail(message(), file: file, line: line)
            return
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}
