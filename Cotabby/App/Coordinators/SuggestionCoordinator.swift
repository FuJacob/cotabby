import Combine
import Foundation

/// File overview:
/// Declares the shared state and dependency graph for Cotabby's inline-completion orchestrator.
/// The behavior now lives in `SuggestionCoordinator+*.swift` files so maintainers can read the
/// state machine by concern instead of scrolling through one monolithic source file.
///
/// Swift does not offer a "type-private across multiple files" access level. Because this
/// coordinator is split across extension files, coordinator-owned mutable state uses module
/// visibility and is protected by convention: other types should observe these properties, not
/// mutate them.
@MainActor
final class SuggestionCoordinator: ObservableObject {
    /// The first group is user-facing and debug-facing state surfaced in the menu UI.
    /// Keep treating these as coordinator-owned even though they are not `private(set)`.
    @Published var state: SuggestionDebugState = .idle
    @Published var overlayState: OverlayState = .hidden(reason: "Overlay idle.")
    @Published var latestSuggestionPreview: String?
    @Published var latestFullSuggestionPreview: String?
    @Published var latestRemainingSuggestionPreview: String?
    @Published var latestAcceptedCharacterCount: Int?
    @Published var latestRemainingCharacterCount: Int?
    @Published var latestAcceptanceAction: String?
    @Published var latestLatencyMilliseconds: Int?
    @Published var latestStageMessage = "Idle"
    @Published var latestOverlayMessage = "Overlay idle."
    @Published var latestPromptPreview: String?
    @Published var latestRawModelOutput: String?
    @Published var latestGenerationNumber: UInt64?
    @Published var visualContextStatus: VisualContextStatus = .idle
    @Published var latestVisualContextText: String?
    @Published var totalTabAcceptedWordCount: Int = 0

    // Core collaborators. The coordinator depends on capability-shaped protocols here so its
    // orchestration logic stays separated from concrete service implementations.
    let permissionManager: any SuggestionPermissionProviding
    let focusModel: any SuggestionFocusProviding
    let inputMonitor: any SuggestionInputMonitoring
    let overlayController: any SuggestionOverlayControlling
    let suggestionInserter: any SuggestionInserting
    let suggestionEngine: any SuggestionGenerating
    let suggestionSettings: any SuggestionSettingsProviding
    let clipboardContextProvider: any ClipboardContextProviding
    let clipboardRelevanceFilter: any ClipboardRelevanceFiltering
    let visualContextCoordinator: any VisualContextCoordinating
    let interactionState: SuggestionInteractionState
    let workController: SuggestionWorkController
    let configuration: SuggestionConfiguration
    let userDefaults: UserDefaults
    let overlayPresenter: SuggestionOverlayPresenter
    let logger: SuggestionDebugLogger

    static let totalTabAcceptedWordCountDefaultsKey = "totalTabAcceptedWordCount"

    // Combine subscriptions are the coordinator's remaining direct mutable bookkeeping.
    // Async work and active-session storage now live in dedicated collaborators below.
    var cancellables = Set<AnyCancellable>()
    var settingsSnapshot: SuggestionSettingsSnapshot
    // Synchronous input/focus callbacks cannot directly `await`, so resets are represented as a
    // barrier task that the next generation must cross before it can ask the runtime for output.
    var cacheResetSequence: UInt64 = 0
    var pendingCacheReset: (sequence: UInt64, task: Task<Void, Never>)?

    init(
        permissionManager: any SuggestionPermissionProviding,
        focusModel: any SuggestionFocusProviding,
        inputMonitor: any SuggestionInputMonitoring,
        overlayController: any SuggestionOverlayControlling,
        suggestionInserter: any SuggestionInserting,
        suggestionEngine: any SuggestionGenerating,
        suggestionSettings: any SuggestionSettingsProviding,
        clipboardContextProvider: any ClipboardContextProviding,
        clipboardRelevanceFilter: any ClipboardRelevanceFiltering,
        visualContextCoordinator: any VisualContextCoordinating,
        interactionState: SuggestionInteractionState,
        workController: SuggestionWorkController,
        configuration: SuggestionConfiguration,
        userDefaults: UserDefaults = .standard
    ) {
        let storedTotalTabAcceptedWordCount = userDefaults.integer(
            forKey: Self.totalTabAcceptedWordCountDefaultsKey)

        self.permissionManager = permissionManager
        self.focusModel = focusModel
        self.inputMonitor = inputMonitor
        self.overlayController = overlayController
        self.suggestionInserter = suggestionInserter
        self.suggestionEngine = suggestionEngine
        self.suggestionSettings = suggestionSettings
        self.clipboardContextProvider = clipboardContextProvider
        self.clipboardRelevanceFilter = clipboardRelevanceFilter
        self.visualContextCoordinator = visualContextCoordinator
        self.interactionState = interactionState
        self.workController = workController
        self.configuration = configuration
        self.userDefaults = userDefaults
        settingsSnapshot = suggestionSettings.snapshot
        // These collaborators isolate "how overlay/logging works" from "when the coordinator
        // wants to show state," which keeps the coordinator closer to orchestration code.
        overlayPresenter = SuggestionOverlayPresenter(overlayController: overlayController)
        logger = SuggestionDebugLogger()
        totalTabAcceptedWordCount = max(storedTotalTabAcceptedWordCount, 0)
        visualContextStatus = visualContextCoordinator.status
        latestVisualContextText = visualContextCoordinator.latestExcerpt

        overlayState = overlayController.state
        latestOverlayMessage = overlayController.state.detail

        focusModel.snapshotPublisher
            .sink { [weak self] snapshot in
                self?.handleFocusSnapshotChange(snapshot)
            }
            .store(in: &cancellables)

        permissionManager.inputMonitoringGrantedPublisher
            .sink { [weak self] _ in
                self?.handlePermissionChange()
            }
            .store(in: &cancellables)

        permissionManager.screenRecordingGrantedPublisher
            .sink { [weak self] _ in
                self?.handlePermissionChange()
            }
            .store(in: &cancellables)

        // The monitor and overlay controller are callback-driven. The coordinator translates those
        // callbacks back into its state-machine methods.
        inputMonitor.onEvent = { [weak self] event in
            self?.handleInputEvent(event) ?? false
        }

        inputMonitor.onSuppressedSyntheticInput = { [weak self] in
            self?.handleSuppressedSyntheticInput()
        }

        overlayController.onStateChange = { [weak self] state in
            self?.overlayState = state
        }

        visualContextCoordinator.onStateChange = { [weak self] status, excerpt in
            self?.visualContextStatus = status
            self?.latestVisualContextText = excerpt
        }

        visualContextCoordinator.onInjectedContextReady = { [weak self] identity in
            self?.schedulePredictionForCurrentFocusIfPossible(matching: identity)
        }

        suggestionSettings.snapshotPublisher
            .dropFirst()
            .sink { [weak self] snapshot in
                self?.handleSuggestionSettingsChange(snapshot)
            }
            .store(in: &cancellables)
    }

    /// Exposes the latest cancellation token for the split extension files.
    var currentWorkID: UInt64 {
        workController.currentWorkID
    }
}
