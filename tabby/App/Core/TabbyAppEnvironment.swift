import Combine
import Foundation

/// File overview:
/// Builds Tabby's long-lived dependency graph in one place. This is the app's composition model:
/// services are constructed once here, then handed to `AppDelegate` and the UI as shared owners.
///
/// In frontend terms, this plays the role of a top-level dependency container or provider tree.
/// The important architectural idea is that creation happens in one place, while usage happens
/// elsewhere. That keeps lifecycle ownership easy to follow.
@MainActor
final class TabbyAppEnvironment {
    let permissionManager: PermissionManager
    let runtimeModel: RuntimeBootstrapModel
    let modelDownloadManager: ModelDownloadManager
    let focusModel: FocusTrackingModel
    let inputMonitor: InputMonitor
    let appUpdateManager: AppUpdateManager
    let launchAtLoginService: LaunchAtLoginService
    let appUninstallService: AppUninstallService
    let permissionGuidanceController: PermissionGuidanceController
    let suggestionSettings: SuggestionSettingsModel
    let foundationModelAvailabilityService: FoundationModelAvailabilityService
    let clipboardContextProvider: ClipboardContextProvider
    let suggestionCoordinator: SuggestionCoordinator
    let welcomeCoordinator: WelcomeCoordinator
    let settingsCoordinator: SettingsCoordinator
    let activationIndicatorController: ActivationIndicatorController
    let focusDebugOverlayController: FocusDebugOverlayController?

    private var cancellables = Set<AnyCancellable>()

    init() {
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
        let focusModel = FocusTrackingModel(
            permissionProvider: { permissionManager.accessibilityGranted },
            ignoredBundleIdentifier: Bundle.main.bundleIdentifier,
            publishesPollingEvents: FocusDebugOverlayController.isEnabled
        )
        let appUpdateManager = AppUpdateManager()
        let launchAtLoginService = LaunchAtLoginService()
        let appUninstallService = AppUninstallService(
            launchAtLoginService: launchAtLoginService,
            runtimeModel: runtimeModel,
            modelDownloadManager: modelDownloadManager
        )
        let welcomeCoordinator = WelcomeCoordinator(
            permissionManager: permissionManager,
            permissionGuidanceController: permissionGuidanceController,
            runtimeModel: runtimeModel,
            modelDownloadManager: modelDownloadManager,
            suggestionSettings: suggestionSettings,
            foundationModelAvailabilityService: foundationModelAvailabilityService
        )
        let settingsCoordinator = SettingsCoordinator(
            appUpdateManager: appUpdateManager,
            launchAtLoginService: launchAtLoginService,
            appUninstallService: appUninstallService,
            permissionManager: permissionManager,
            suggestionSettings: suggestionSettings,
            foundationModelAvailabilityService: foundationModelAvailabilityService,
            runtimeModel: runtimeModel,
            modelDownloadManager: modelDownloadManager,
            onShowWelcome: { [weak welcomeCoordinator] in
                welcomeCoordinator?.showWelcome()
            }
        )
        let suggestionInserter = SuggestionInserter(suppressionController: suppressionController)
        let overlayController = OverlayController(suggestionSettings: suggestionSettings)
        let activationIndicatorController = ActivationIndicatorController()
        let clipboardContextProvider = ClipboardContextProvider()
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
        } else {
            foundationModelEngine = UnavailableSuggestionEngine(
                message: foundationModelAvailabilityService.userVisibleMessage
            )
        }
        #else
        foundationModelEngine = UnavailableSuggestionEngine(
            message: foundationModelAvailabilityService.userVisibleMessage
        )
        #endif

        let suggestionEngine: any SuggestionGenerating = SuggestionEngineRouter(
            suggestionSettings: suggestionSettings,
            foundationModelEngine: foundationModelEngine,
            llamaEngine: LlamaSuggestionEngine(runtimeManager: runtimeManager)
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
            visualContextCoordinator: visualContextCoordinator,
            interactionState: interactionState,
            workController: workController,
            configuration: configuration
        )

        self.permissionManager = permissionManager
        self.runtimeModel = runtimeModel
        self.modelDownloadManager = modelDownloadManager
        self.focusModel = focusModel
        self.inputMonitor = inputMonitor
        self.appUpdateManager = appUpdateManager
        self.launchAtLoginService = launchAtLoginService
        self.appUninstallService = appUninstallService
        self.permissionGuidanceController = permissionGuidanceController
        self.suggestionSettings = suggestionSettings
        self.foundationModelAvailabilityService = foundationModelAvailabilityService
        self.clipboardContextProvider = clipboardContextProvider
        self.suggestionCoordinator = suggestionCoordinator
        self.welcomeCoordinator = welcomeCoordinator
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
    }
}
