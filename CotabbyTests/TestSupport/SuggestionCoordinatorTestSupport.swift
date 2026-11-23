import Combine
import Foundation
import XCTest
@testable import Cotabby

/// Shared, recording test doubles for `SuggestionCoordinator` suites.
///
/// Every coordinator suite builds on these so the protocol surface is mocked once. Each double
/// records what the coordinator asked of it, because most of the pipeline's contracts are about
/// *which* boundary was poked, not return values.
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
final class RigLowPowerModeProvider: SuggestionLowPowerModeProviding {
    private(set) var isLowPowerModeEnabled: Bool

    private let subject = PassthroughSubject<Bool, Never>()

    init(isLowPowerModeEnabled: Bool = false) {
        self.isLowPowerModeEnabled = isLowPowerModeEnabled
    }

    var lowPowerModeChanges: AnyPublisher<Bool, Never> {
        subject.eraseToAnyPublisher()
    }

    /// Updates current state before publishing its matching transition.
    func setLowPowerModeEnabled(_ enabled: Bool) {
        guard isLowPowerModeEnabled != enabled else {
            return
        }

        isLowPowerModeEnabled = enabled
        subject.send(enabled)
    }
}

@MainActor
final class RigFocusProvider: SuggestionFocusProviding {
    /// Tests can simulate a recent poll followed by a focus change discovered only on refresh.
    var millisecondsSinceLastCapture: Int?
    var onRefresh: (() -> Void)?
    var snapshot: FocusSnapshot
    private(set) var refreshCount = 0
    private(set) var transientCaretCacheInvalidations = 0

    let snapshotSubject = PassthroughSubject<FocusSnapshot, Never>()

    var snapshotPublisher: AnyPublisher<FocusSnapshot, Never> {
        snapshotSubject.eraseToAnyPublisher()
    }

    init(snapshot: FocusSnapshot) {
        self.snapshot = snapshot
    }

    func refreshNow() {
        refreshCount += 1
        onRefresh?()
    }

    func invalidateTransientCaretCaches() {
        transientCaretCacheInvalidations += 1
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
    /// Records slide attempts (and declines them, like the protocol default) so tests can assert
    /// which accept paths even try to slide versus re-anchor through a present.
    private(set) var advanceInlineCalls: [(remaining: String, inserted: String)] = []
    /// When true, `showSuggestion` behaves like the real controller waiting on a pixel caret read
    /// or a lagging host caret: it records the text as held and leaves `state` on the previous
    /// presentation. `landHeldPresentation()` then applies it, as the capture callback would.
    var defersPresentations = false
    /// One value, so a held text can never be reported without the geometry it would land with.
    private var heldPresentation: (text: String, geometry: SuggestionOverlayGeometry)?

    var heldPresentationText: String? { heldPresentation?.text }

    /// Set by a test to simulate a one-row host that painted only this head of the visible text.
    /// Every applied present and every hide clears it, as the real controller recomputes it from
    /// each new layout; a held present leaves it describing the previous one, as the real one does.
    var truncatedDisplayText: String?

    init(state: OverlayState = .hidden(reason: "initial")) {
        self.state = state
    }

    func advanceInline(to remainingText: String, insertedText: String) -> Bool {
        advanceInlineCalls.append((remainingText, insertedText))
        return false
    }

    func showSuggestion(_ text: String, geometry: SuggestionOverlayGeometry) {
        shownTexts.append(text)
        if defersPresentations {
            heldPresentation = (text, geometry)
            return
        }
        heldPresentation = nil
        truncatedDisplayText = nil
        state = .visible(text: text, geometry: geometry, mode: .inline)
        onStateChange?(state)
    }

    /// Applies the held presentation, the way the real controller's capture callback re-runs it.
    func landHeldPresentation() {
        guard let held = heldPresentation else { return }
        heldPresentation = nil
        truncatedDisplayText = nil
        state = .visible(text: held.text, geometry: held.geometry, mode: .inline)
        onStateChange?(state)
    }

    func hide(reason: String) {
        hideReasons.append(reason)
        heldPresentation = nil
        truncatedDisplayText = nil
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
    /// Cumulative synthetic engine snapshots exercise real coordinator streaming and acceptance.
    var partialTexts: [String] = []
    private(set) var requests: [SuggestionRequest] = []
    private(set) var resetCount = 0
    private(set) var prewarmedRequests: [SuggestionRequest] = []

    func generateSuggestion(for request: SuggestionRequest) async throws -> SuggestionResult {
        requests.append(request)
        return try await resultProvider(request)
    }

    func generateSuggestion(for request: SuggestionRequest, onPartial: (@MainActor (SuggestionResult) -> Void)?) async throws -> SuggestionResult {
        for text in partialTexts {
            onPartial?(SuggestionResult(generation: request.generation, rawText: text, text: text, latency: 0.01))
            await Task.yield()
        }
        return try await generateSuggestion(for: request)
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
    var refreshContextProvider: (() -> FocusedInputSnapshot?)?
    private(set) var startedSessions: [FocusedInputSnapshot] = []
    private(set) var cancelCount = 0
    var excerptValue: String?

    func startSessionIfNeeded(for snapshotContext: FocusedInputSnapshot, configuration: VisualContextConfiguration) {
        startedSessions.append(snapshotContext)
    }

    func cancel() {
        cancelCount += 1
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
    let lowPowerModeProvider: RigLowPowerModeProvider
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

    /// Replaces the focused field without publishing a focus event, mimicking a host that has
    /// updated AX before Cotabby's poll or publisher notices.
    func setFocusedInput(_ raw: FocusedInputSnapshot, capability: FocusCapability = .supported) {
        focusProvider.snapshot = CotabbyTestFixtures.focusSnapshot(for: raw, capability: capability)
    }

    /// Replaces the focused field and emits it on the focus publisher, the path a real focus
    /// change or polled text change takes into the coordinator.
    func publishFocusedInput(_ raw: FocusedInputSnapshot, capability: FocusCapability = .supported) {
        setFocusedInput(raw, capability: capability)
        focusProvider.snapshotSubject.send(focusProvider.snapshot)
    }
}

@MainActor
func makeCoordinatorRig(
    snapshot: FocusedInputSnapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello"),
    capability: FocusCapability = .supported,
    overlayState: OverlayState = .hidden(reason: "initial"),
    lowPowerModeEnabled: Bool = false,
    settingsSnapshot: SuggestionSettingsSnapshot = CotabbyTestFixtures.settingsSnapshot(debounceMilliseconds: 1),
    generationEngine: (any SuggestionGenerating)? = nil,
    configuration: SuggestionConfiguration = .standard
) -> CoordinatorRig {
    let focusSnapshot = CotabbyTestFixtures.focusSnapshot(for: snapshot, capability: capability)
    let permissionProvider = RigPermissionProvider()
    let lowPowerModeProvider = RigLowPowerModeProvider(isLowPowerModeEnabled: lowPowerModeEnabled)
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
        lowPowerModeProvider: lowPowerModeProvider,
        focusModel: focusProvider,
        inputMonitor: inputMonitor,
        overlayController: overlayController,
        suggestionInserter: inserter,
        suggestionEngine: generationEngine ?? engine,
        suggestionSettings: settingsProvider,
        clipboardContextProvider: clipboardProvider,
        clipboardRelevanceFilter: clipboardFilter,
        visualContextCoordinator: visualContext,
        interactionState: interactionState,
        workController: SuggestionWorkController(),
        configuration: configuration,
        // Pinned to English: the replays assert English corrections, which must not follow the
        // locale of the machine running the tests.
        spellChecker: CurrentWordSpellChecker(language: "en"),
        symSpellCorrector: SymSpellCorrector(preloadLanguage: nil),
        qualityMetricsStore: SuggestionQualityMetricsStore(userDefaults: IsolatedUserDefaults.make()),
        userDefaults: IsolatedUserDefaults.make()
    )
    let rig = CoordinatorRig(
        coordinator: coordinator,
        permissionProvider: permissionProvider,
        lowPowerModeProvider: lowPowerModeProvider,
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
    // Each test must still stop its coordinator (see `SuggestionCoordinatorRigTestCase`): a retained
    // rig's tasks and subscriptions would otherwise outlive the test.
    return TestLifetime.retain(rig)
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
