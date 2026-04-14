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
    let suggestionCoordinator: SuggestionCoordinator
    let welcomeCoordinator: WelcomeCoordinator
    let settingsCoordinator: SettingsCoordinator
    let activationIndicatorController: ActivationIndicatorController

    init() {
        let permissionManager = PermissionManager()
        let runtimeManager = LlamaRuntimeManager()
        let runtimeModel = RuntimeBootstrapModel(runtimeManager: runtimeManager)
        let modelDownloadManager = ModelDownloadManager()
        let suppressionController = InputSuppressionController()
        let inputMonitor = InputMonitor(
            permissionProvider: { permissionManager.inputMonitoringGranted },
            suppressionController: suppressionController
        )
        let focusModel = FocusTrackingModel(
            pollInterval: 0.25,
            permissionProvider: { permissionManager.accessibilityGranted },
            ignoredBundleIdentifier: Bundle.main.bundleIdentifier
        )
        let appUpdateManager = AppUpdateManager()
        let welcomeCoordinator = WelcomeCoordinator(
            permissionManager: permissionManager,
            runtimeModel: runtimeModel,
            modelDownloadManager: modelDownloadManager
        )
        let settingsCoordinator = SettingsCoordinator(
            appUpdateManager: appUpdateManager,
            runtimeModel: runtimeModel,
            modelDownloadManager: modelDownloadManager
        )
        let suggestionInserter = SuggestionInserter(suppressionController: suppressionController)
        let overlayController = OverlayController()
        let activationIndicatorController = ActivationIndicatorController()
        let screenshotContextGenerator = ScreenshotContextGenerator()
        let visualContextCoordinator = VisualContextCoordinator(
            screenshotContextGenerator: screenshotContextGenerator,
            screenRecordingPermissionProvider: { permissionManager.screenRecordingGranted }
        )
        // This is intentionally a hard switch for early backend validation.
        // Backend choice belongs in the composition root so the coordinator and UI continue to
        // depend on the `SuggestionGenerating` capability instead of a specific runtime.
        let foundationModelAvailabilityService = FoundationModelAvailabilityService()
        let suggestionEngine: any SuggestionGenerating = FoundationModelSuggestionEngine(
            availabilityService: foundationModelAvailabilityService
        )
        // Swap to the llama backend by replacing the line above with:
        // let suggestionEngine: any SuggestionGenerating = LlamaSuggestionEngine(runtimeManager: runtimeManager)

        let interactionState = SuggestionInteractionState()
        let workController = SuggestionWorkController()
        let suggestionCoordinator = SuggestionCoordinator(
            permissionManager: permissionManager,
            focusModel: focusModel,
            inputMonitor: inputMonitor,
            overlayController: overlayController,
            suggestionInserter: suggestionInserter,
            suggestionEngine: suggestionEngine,
            visualContextCoordinator: visualContextCoordinator,
            interactionState: interactionState,
            workController: workController,
            configuration: .standard
        )

        self.permissionManager = permissionManager
        self.runtimeModel = runtimeModel
        self.modelDownloadManager = modelDownloadManager
        self.focusModel = focusModel
        self.inputMonitor = inputMonitor
        self.appUpdateManager = appUpdateManager
        self.suggestionCoordinator = suggestionCoordinator
        self.welcomeCoordinator = welcomeCoordinator
        self.settingsCoordinator = settingsCoordinator
        self.activationIndicatorController = activationIndicatorController
    }
}
