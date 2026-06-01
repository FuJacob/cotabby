import Combine
import Foundation
import Logging

/// File overview:
/// Builds Cotabby's long-lived dependency graph in one place. This is the app's composition model:
/// services are constructed once here, then handed to `AppDelegate` and the UI as shared owners.
///
/// In frontend terms, this plays the role of a top-level dependency container or provider tree.
/// The important architectural idea is that creation happens in one place, while usage happens
/// elsewhere. That keeps lifecycle ownership easy to follow.
@MainActor
final class CotabbyAppEnvironment {
    let permissionManager: PermissionManager
    let runtimeModel: RuntimeBootstrapModel
    let modelDownloadManager: ModelDownloadManager
    let focusModel: FocusTrackingModel
    let inputMonitor: InputMonitor
    let appUpdateManager: AppUpdateManager
    let launchAtLoginService: LaunchAtLoginService
    let permissionGuidanceController: PermissionGuidanceController
    let suggestionSettings: SuggestionSettingsModel
    let foundationModelAvailabilityService: FoundationModelAvailabilityService
    let clipboardContextProvider: ClipboardContextProvider
    let suggestionCoordinator: SuggestionCoordinator
    /// Shared with the Advanced settings pane so the user can fire an ad-hoc generation against
    /// the currently-selected engine and verify that Extended Context (and other prompt inputs)
    /// are actually shaping the output. Reusing the live router means the playground produces the
    /// same answer the autocomplete pipeline would, not a stand-in.
    let suggestionEngine: any SuggestionGenerating
    let emojiPickerController: EmojiPickerController
    let emojiUsageStore: EmojiUsageStore
    let welcomeCoordinator: WelcomeCoordinator
    let huggingFaceSearchService: HuggingFaceSearchService
    let performanceMetricsStore: PerformanceMetricsStore
    let settingsCoordinator: SettingsCoordinator
    let activationIndicatorController: ActivationIndicatorController
    let focusDebugOverlayController: FocusDebugOverlayController?

    private var cancellables = Set<AnyCancellable>()

    init() {
        CotabbyLogger.app.info("Building dependency graph")
        let configuration = SuggestionConfiguration.standard
        let permissionManager = PermissionManager()
        let permissionGuidanceController = PermissionGuidanceController(
            permissionManager: permissionManager
        )
        let runtimeManager = LlamaRuntimeManager()
        let runtimeModel = RuntimeBootstrapModel(runtimeManager: runtimeManager)
        let modelDownloadManager = ModelDownloadManager()
        let suggestionSettings = SuggestionSettingsModel(configuration: configuration)
        let foundationModelAvailabilityService = FoundationModelAvailabilityService()
        let suppressionController = InputSuppressionController()
        let inputMonitor = InputMonitor(
            permissionProvider: { permissionManager.inputMonitoringGranted },
            suppressionController: suppressionController
        )
        inputMonitor.acceptanceKeyCodeProvider = { suggestionSettings.acceptanceKeyCode }
        inputMonitor.acceptanceKeyModifiersProvider = { suggestionSettings.acceptanceKeyModifiers }
        inputMonitor.fullAcceptanceKeyCodeProvider = { suggestionSettings.fullAcceptanceKeyCode }
        inputMonitor.fullAcceptanceKeyModifiersProvider = { suggestionSettings.fullAcceptanceKeyModifiers }
        inputMonitor.globalToggleKeyCodeProvider = { suggestionSettings.globalToggleKeyCode }
        inputMonitor.globalToggleKeyModifiersProvider = { suggestionSettings.globalToggleKeyModifiers }
        inputMonitor.onGlobalToggleHotkey = { [weak suggestionSettings] in
            suggestionSettings?.toggleGloballyEnabled()
        }
        // Stop the deep AX walk when Cotabby is disabled for the focused app. Without this the
        // focus poll keeps enumerating the frontmost app's AX attributes every 50-80ms even after
        // the user toggles Cotabby off, which can dismiss transient popovers in apps like Calendar
        // (#476). Gating here also makes the "I disabled it but the bug remained" symptom go away:
        // the disable toggles now actually stop touching the focused app.
        let focusModel = FocusTrackingModel(
            permissionProvider: { permissionManager.accessibilityGranted },
            ignoredBundleIdentifier: Bundle.main.bundleIdentifier,
            isCaptureSuppressedForBundle: { bundleIdentifier in
                guard suggestionSettings.isGloballyEnabled else { return true }
                if let bundleIdentifier,
                   suggestionSettings.isApplicationDisabled(bundleIdentifier: bundleIdentifier) {
                    return true
                }
                return false
            },
            publishesPollingEvents: FocusDebugOverlayController.isEnabled
        )
        // The snapshot is poll-based, so after a fast app switch the closure may briefly
        // evaluate against the previous app's identity until the next AX poll fires. This
        // is the same race the downstream evaluator already has — not a new regression.
        inputMonitor.shouldProcessEventsProvider = { [weak focusModel] in
            guard suggestionSettings.isGloballyEnabled else { return false }
            guard let snapshot = focusModel?.snapshot else { return true }
            if TerminalAppDetector.isTerminal(bundleIdentifier: snapshot.bundleIdentifier) { return false }
            if let bundleID = snapshot.bundleIdentifier,
               suggestionSettings.isApplicationDisabled(bundleIdentifier: bundleID) {
                return false
            }
            return true
        }
        let appUpdateManager = AppUpdateManager()
        let launchAtLoginService = LaunchAtLoginService()
        let welcomeCoordinator = WelcomeCoordinator(
            permissionManager: permissionManager,
            permissionGuidanceController: permissionGuidanceController,
            runtimeModel: runtimeModel,
            modelDownloadManager: modelDownloadManager,
            suggestionSettings: suggestionSettings,
            foundationModelAvailabilityService: foundationModelAvailabilityService
        )
        let huggingFaceSearchService = HuggingFaceSearchService()
        let performanceMetricsStore = PerformanceMetricsStore()
        // Settings coordinator construction is deferred below until after `suggestionEngine` is
        // built — the Advanced pane's "try it" playground needs the engine so it can fire ad-hoc
        // generations using the same router the autocomplete pipeline does.
        let suggestionInserter = SuggestionInserter(suppressionController: suppressionController)
        let overlayController = OverlayController(suggestionSettings: suggestionSettings)
        let activationIndicatorController = ActivationIndicatorController()
        let clipboardContextProvider = ClipboardContextProvider()
        let clipboardRelevanceFilter = ClipboardRelevanceFilter()
        let summarizer = LlamaVisualContextSummarizer(runtimeManager: runtimeManager)
        let screenshotContextGenerator = ScreenshotContextGenerator(summarizer: summarizer)
        let visualContextCoordinator = VisualContextCoordinator(
            screenshotContextGenerator: screenshotContextGenerator,
            screenRecordingPermissionProvider: { permissionManager.screenRecordingGranted }
        )
        let foundationModelEngine: any SuggestionGenerating
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            foundationModelEngine = FoundationModelSuggestionEngine(
                availabilityService: foundationModelAvailabilityService
            )
            CotabbyLogger.app.info("Foundation model engine available")
        } else {
            foundationModelEngine = UnavailableSuggestionEngine(
                message: foundationModelAvailabilityService.userVisibleMessage
            )
            CotabbyLogger.app.info("Foundation model engine unavailable (macOS version)")
        }
        #else
        foundationModelEngine = UnavailableSuggestionEngine(
            message: foundationModelAvailabilityService.userVisibleMessage
        )
        CotabbyLogger.app.info("Foundation model engine unavailable (SDK)")
        #endif

        let suggestionEngine: any SuggestionGenerating = SuggestionEngineRouter(
            suggestionSettings: suggestionSettings,
            foundationModelEngine: foundationModelEngine,
            llamaEngine: LlamaSuggestionEngine(runtimeManager: runtimeManager),
            performanceMetricsStore: performanceMetricsStore,
            llamaModelNameProvider: { [weak runtimeManager] in
                runtimeManager?.currentModelFilename
            }
        )

        // Per-user emoji recents/frequency. Built before the settings coordinator so the
        // "Clear History" control can reach it, and before the picker which reads and writes it.
        let emojiUsageStore = EmojiUsageStore()

        let settingsCoordinator = SettingsCoordinator(
            appUpdateManager: appUpdateManager,
            launchAtLoginService: launchAtLoginService,
            permissionManager: permissionManager,
            suggestionSettings: suggestionSettings,
            foundationModelAvailabilityService: foundationModelAvailabilityService,
            runtimeModel: runtimeModel,
            modelDownloadManager: modelDownloadManager,
            huggingFaceSearchService: huggingFaceSearchService,
            suggestionEngine: suggestionEngine,
            configuration: configuration,
            performanceMetricsStore: performanceMetricsStore,
            onShowWelcome: { [weak welcomeCoordinator] in
                welcomeCoordinator?.showWelcome()
            },
            clearEmojiHistory: { emojiUsageStore.clear() }
        )

        let interactionState = SuggestionInteractionState()
        let workController = SuggestionWorkController()
        let suggestionCoordinator = SuggestionCoordinator(
            permissionManager: permissionManager,
            focusModel: focusModel,
            inputMonitor: inputMonitor,
            overlayController: overlayController,
            suggestionInserter: suggestionInserter,
            suggestionEngine: suggestionEngine,
            suggestionSettings: suggestionSettings,
            clipboardContextProvider: clipboardContextProvider,
            clipboardRelevanceFilter: clipboardRelevanceFilter,
            visualContextCoordinator: visualContextCoordinator,
            interactionState: interactionState,
            workController: workController,
            configuration: configuration
        )

        // The emoji picker is a sibling to the suggestion coordinator. It reuses the input monitor,
        // focus model, and inserter, but owns its own trigger state machine and floating panel.
        let emojiPickerController = EmojiPickerController(
            matcher: EmojiMatcher(catalog: EmojiCatalog.bundled()),
            panel: EmojiPickerPanelController(),
            focusModel: focusModel,
            inputMonitor: inputMonitor,
            inserter: suggestionInserter,
            isEnabled: { suggestionSettings.isEmojiPickerEnabled },
            emojiPreferences: { suggestionSettings.emojiVariantPreferences },
            acceptKeyLabel: { suggestionSettings.emojiPickerAcceptKeyLabel },
            emojiUsage: { emojiUsageStore.snapshot() },
            recordEmojiUsage: { emojiUsageStore.record(alias: $0) }
        )
        // Give the picker first look at every keystroke the coordinator receives, so it can detect the
        // `:` trigger and drive its state machine without changing who owns `inputMonitor.onEvent`.
        suggestionCoordinator.emojiInputObserver = { [weak emojiPickerController] event in
            emojiPickerController?.observe(event) ?? false
        }

        self.permissionManager = permissionManager
        self.runtimeModel = runtimeModel
        self.modelDownloadManager = modelDownloadManager
        self.focusModel = focusModel
        self.inputMonitor = inputMonitor
        self.appUpdateManager = appUpdateManager
        self.launchAtLoginService = launchAtLoginService
        self.permissionGuidanceController = permissionGuidanceController
        self.suggestionSettings = suggestionSettings
        self.foundationModelAvailabilityService = foundationModelAvailabilityService
        self.clipboardContextProvider = clipboardContextProvider
        self.suggestionCoordinator = suggestionCoordinator
        self.suggestionEngine = suggestionEngine
        self.emojiPickerController = emojiPickerController
        self.emojiUsageStore = emojiUsageStore
        self.welcomeCoordinator = welcomeCoordinator
        self.huggingFaceSearchService = huggingFaceSearchService
        self.performanceMetricsStore = performanceMetricsStore
        self.settingsCoordinator = settingsCoordinator
        self.activationIndicatorController = activationIndicatorController
        self.focusDebugOverlayController = FocusDebugOverlayController.isEnabled
            ? FocusDebugOverlayController()
            : nil

        // Update the AX polling timer whenever the user changes the poll interval setting.
        suggestionSettings.$focusPollIntervalMilliseconds
            .removeDuplicates()
            .sink { [weak focusModel] milliseconds in
                focusModel?.updatePollInterval(milliseconds: milliseconds)
            }
            .store(in: &cancellables)

        // Key code changes reach InputMonitor through closures that read from the model
        // at event time (set above), so no Combine subscription is needed here.

        // The global-toggle hotkey is the exception: its tap is install-on-demand so a user who
        // never binds it pays zero per-keystroke cost. Install/uninstall whenever the binding
        // crosses the unbound/bound boundary or when the key code itself changes.
        suggestionSettings.$globalToggleKeyCode
            .removeDuplicates()
            .sink { [weak inputMonitor] _ in
                inputMonitor?.refreshToggleTap()
            }
            .store(in: &cancellables)
    }
}
