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
    let suggestionSettings: SuggestionSettingsModel
    let debugMode: DebugModeModel
    let diagnosticsStore: DiagnosticsStore
    let diagnosticsLogger: DiagnosticsLogger
    let foundationModelAvailabilityService: FoundationModelAvailabilityService
    let suggestionCoordinator: SuggestionCoordinator
    let welcomeCoordinator: WelcomeCoordinator
    let settingsCoordinator: SettingsCoordinator
    let activationIndicatorController: ActivationIndicatorController
    let devDiagnosticsPanelController: DevDiagnosticsPanelController

    init() {
        let configuration = SuggestionConfiguration.standard
        let debugMode = DebugModeModel()
        let diagnosticsStore = DiagnosticsStore()
        let diagnosticsLogger = DiagnosticsLogger(
            debugMode: debugMode,
            store: diagnosticsStore
        )
        let permissionManager = PermissionManager()
        let permissionGuidanceController = PermissionGuidanceController(
            permissionManager: permissionManager
        )
        let runtimeManager = LlamaRuntimeManager()
        let runtimeModel = RuntimeBootstrapModel(
            runtimeManager: runtimeManager,
            diagnosticsLogger: diagnosticsLogger
        )
        let modelDownloadManager = ModelDownloadManager(
            diagnosticsLogger: diagnosticsLogger
        )
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
            diagnosticsLogger: diagnosticsLogger
        )
        let appUpdateManager = AppUpdateManager(diagnosticsLogger: diagnosticsLogger)
        let launchAtLoginService = LaunchAtLoginService()
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
        let summarizer = LlamaVisualContextSummarizer(
            runtimeManager: runtimeManager,
            diagnosticsLogger: diagnosticsLogger
        )
        let screenshotContextGenerator = ScreenshotContextGenerator(
            summarizer: summarizer,
            diagnosticsLogger: diagnosticsLogger
        )
        let visualContextCoordinator = VisualContextCoordinator(
            screenshotContextGenerator: screenshotContextGenerator,
            screenRecordingPermissionProvider: { permissionManager.screenRecordingGranted },
            diagnosticsLogger: diagnosticsLogger
        )
        let suggestionEngine: any SuggestionGenerating = SuggestionEngineRouter(
            suggestionSettings: suggestionSettings,
            foundationModelEngine: FoundationModelSuggestionEngine(
                availabilityService: foundationModelAvailabilityService
            ),
            llamaEngine: LlamaSuggestionEngine(
                runtimeManager: runtimeManager,
                diagnosticsLogger: diagnosticsLogger
            )
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
            visualContextCoordinator: visualContextCoordinator,
            interactionState: interactionState,
            workController: workController,
            configuration: configuration,
            diagnosticsLogger: diagnosticsLogger
        )

        self.permissionManager = permissionManager
        self.runtimeModel = runtimeModel
        self.modelDownloadManager = modelDownloadManager
        self.focusModel = focusModel
        self.inputMonitor = inputMonitor
        self.appUpdateManager = appUpdateManager
        self.launchAtLoginService = launchAtLoginService
        self.suggestionSettings = suggestionSettings
        self.debugMode = debugMode
        self.diagnosticsStore = diagnosticsStore
        self.diagnosticsLogger = diagnosticsLogger
        self.foundationModelAvailabilityService = foundationModelAvailabilityService
        self.suggestionCoordinator = suggestionCoordinator
        self.welcomeCoordinator = welcomeCoordinator
        self.settingsCoordinator = settingsCoordinator
        self.activationIndicatorController = activationIndicatorController
        self.devDiagnosticsPanelController = DevDiagnosticsPanelController(
            debugMode: debugMode,
            diagnosticsStore: diagnosticsStore,
            permissionManager: permissionManager,
            runtimeModel: runtimeModel,
            focusModel: focusModel,
            suggestionSettings: suggestionSettings,
            suggestionCoordinator: suggestionCoordinator
        )
    }
}
