import AppKit
import Combine

/// File overview:
/// Starts the long-lived services that power permissions, focus tracking, suggestion generation,
/// overlay rendering, acceptance, and app updates. Dependency construction now lives in
/// `TabbyAppEnvironment`, while `AppDelegate` focuses on lifecycle wiring and cross-subsystem
/// subscriptions.
///
/// In React terms, this is the top-level container that owns the long-lived stores/services.
/// SwiftUI renders views from these objects, but the view layer does not create or own them.
///
/// App lifecycle callbacks happen on the main thread; marking this type clarifies actor expectations.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
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
    let suggestionCoordinator: SuggestionCoordinator
    let welcomeCoordinator: WelcomeCoordinator
    let settingsCoordinator: SettingsCoordinator

    private let activationIndicatorController: ActivationIndicatorController
    private let focusDebugOverlayController: FocusDebugOverlayController?
    private var cancellables = Set<AnyCancellable>()

    override init() {
        // Build the dependency graph once up front so every scene/view observes the same
        // long-lived objects for the entire app session. `TabbyAppEnvironment` is a composition
        // helper here; the app delegate retains the root objects it needs directly.
        let environment = TabbyAppEnvironment()
        permissionManager = environment.permissionManager
        runtimeModel = environment.runtimeModel
        modelDownloadManager = environment.modelDownloadManager
        focusModel = environment.focusModel
        inputMonitor = environment.inputMonitor
        appUpdateManager = environment.appUpdateManager
        launchAtLoginService = environment.launchAtLoginService
        permissionGuidanceController = environment.permissionGuidanceController
        suggestionSettings = environment.suggestionSettings
        foundationModelAvailabilityService = environment.foundationModelAvailabilityService
        suggestionCoordinator = environment.suggestionCoordinator
        welcomeCoordinator = environment.welcomeCoordinator
        settingsCoordinator = environment.settingsCoordinator
        activationIndicatorController = environment.activationIndicatorController
        focusDebugOverlayController = environment.focusDebugOverlayController
        super.init()

        // These closures bridge events across subsystems without forcing those subsystems
        // to know about each other directly.
        runtimeModel.onWillReloadModel = { [weak suggestionCoordinator] in
            suggestionCoordinator?.prepareForRuntimeModelSwitch()
        }

        modelDownloadManager.onModelDirectoryChanged = { [weak self] in
            self?.handleModelDirectoryChange()
        }

        // Combine subscriptions keep the app's long-lived services in sync as permission and
        // focus state changes over time.
        permissionManager.$inputMonitoringGranted
            .sink { [weak self] _ in
                self?.inputMonitor.refresh()
            }
            .store(in: &cancellables)

        suggestionSettings.$selectedEngine
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                self?.startRuntimeIfPreferredEngineRequiresIt()
            }
            .store(in: &cancellables)

        focusModel.$snapshot
            .sink { [weak self] snapshot in
                self?.updateActivationIndicator(for: snapshot)
                self?.focusDebugOverlayController?.update(for: snapshot)
            }
            .store(in: &cancellables)

        if let focusDebugOverlayController {
            focusModel.$latestPollEvent
                .compactMap { $0 }
                .sink { [weak focusDebugOverlayController] pollEvent in
                    focusDebugOverlayController?.updateFocusPolling(event: pollEvent)
                }
                .store(in: &cancellables)
        }

        suggestionCoordinator.$visualContextStatus
            .combineLatest(suggestionCoordinator.$latestVisualContextText)
            .sink { [weak self] status, excerpt in
                self?.focusDebugOverlayController?.updateVisualContext(
                    status: status,
                    excerpt: excerpt
                )
            }
            .store(in: &cancellables)

    }

    /// Starts runtime and polling services once AppKit reports that app launch finished.
    func applicationDidFinishLaunching(_ notification: Notification) {
        startRuntimeIfPreferredEngineRequiresIt()
        focusModel.start()
        inputMonitor.start()
        appUpdateManager.start()
        suggestionCoordinator.start()
        welcomeCoordinator.presentIfNeeded()
    }

    /// Stops long-lived services before process exit so timers and runtime resources detach cleanly.
    func applicationWillTerminate(_ notification: Notification) {
        activationIndicatorController.hide(reason: "Activation indicator hidden because Tabby is terminating.")
        focusDebugOverlayController?.hide()
        suggestionCoordinator.stop()
        inputMonitor.stop()
        focusModel.stop()
        runtimeModel.stop()
    }

    /// Mirrors supported-focus state into the selected activation indicator mode.
    /// Different modes intentionally use different geometry contracts: caret-anchor mode hugs the
    /// insertion point, while the icon mode sits outside the field edge.
    private func updateActivationIndicator(for snapshot: FocusSnapshot) {
        guard case .supported = snapshot.capability,
              let context = snapshot.context
        else {
            activationIndicatorController.hide(reason: "Activation indicator hidden.")
            return
        }

        activationIndicatorController.show(
            mode: suggestionSettings.selectedIndicatorMode,
            caretRect: context.caretRect,
            inputFrameRect: context.inputFrameRect
        )
    }

    /// Warm the local runtime only when the user is actually on the open-source engine path.
    /// This avoids noisy startup failures and wasted work for Apple Intelligence users.
    private func startRuntimeIfPreferredEngineRequiresIt() {
        guard suggestionSettings.selectedEngine == .llamaOpenSource else {
            return
        }

        runtimeModel.startIfNeeded()
    }

    /// Model availability can change after downloads or manual file drops. Re-scan first, then
    /// warm the runtime only if the current engine choice needs it.
    private func handleModelDirectoryChange() {
        runtimeModel.refreshAvailableModels()
        startRuntimeIfPreferredEngineRequiresIt()
    }
}
