import AppKit
import Combine
import Logging

/// File overview:
/// Starts the long-lived services that power permissions, focus tracking, suggestion generation,
/// overlay rendering, acceptance, and app updates. Dependency construction now lives in
/// `CotabbyAppEnvironment`, while `AppDelegate` focuses on lifecycle wiring and cross-subsystem
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
    let emojiPickerController: EmojiPickerController
    let welcomeCoordinator: WelcomeCoordinator
    let settingsCoordinator: SettingsCoordinator

    private let activationIndicatorController: ActivationIndicatorController
    private let focusDebugOverlayController: FocusDebugOverlayController?
    /// Retained for the app's lifetime because the environment owns its own `cancellables` (the only
    /// subscriptions wiring the focus-poll-interval setting and the global-toggle hotkey rebind to the
    /// runtime). If the environment deallocated when `init` returned, those subscriptions would be
    /// cancelled and both settings would silently stop working until the next relaunch.
    private let environment: CotabbyAppEnvironment
    private var cancellables = Set<AnyCancellable>()
    private var didStartServices = false

    override init() {
        CotabbyLogger.bootstrap()

        // Build the dependency graph once up front so every scene/view observes the same
        // long-lived objects for the entire app session.
        let environment = CotabbyAppEnvironment()
        self.environment = environment
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
        emojiPickerController = environment.emojiPickerController
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
        guard !Self.isRunningUnderXCTest else {
            CotabbyLogger.app.info("Unit test host detected; skipping production service startup")
            return
        }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        CotabbyLogger.app.info("Cotabby \(version) (build \(build)) launching on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)")
        startRuntimeIfPreferredEngineRequiresIt()
        focusModel.start()
        inputMonitor.start()
        appUpdateManager.start()
        suggestionCoordinator.start()
        emojiPickerController.start()
        welcomeCoordinator.presentIfNeeded()
        welcomeCoordinator.presentPermissionReminderIfNeeded()
        didStartServices = true
        CotabbyLogger.app.info("All services started")
    }

    /// Synchronously releases native runtime resources before AppKit calls `exit()`.
    ///
    /// `exit()` runs C++ static destructors that tear down the Metal device. If llama contexts
    /// are still live at that point, `ggml_metal_rsets_free` aborts. We MUST release them first
    /// — but we cannot use `.terminateLater` to do it: a deferred reply leaves the app alive
    /// long enough that macOS's "Quit & Reopen" TCC handshake (after a permission grant) does
    /// not propagate the new grant to the relaunched process, leaving users stuck on the
    /// permission reminder forever.
    ///
    /// The compromise: stop new work synchronously, then call `shutdownSync` which blocks up to
    /// ~1.5s for in-flight `generate()` calls to drain before forcing `engine.unloadModel()`.
    /// In the common case (no autocomplete mid-flight) this returns in milliseconds. If a
    /// generation is genuinely stuck, we accept the small risk of the original ggml crash over
    /// the larger UX bug of a broken permission flow.
    func applicationWillTerminate(_ notification: Notification) {
        guard didStartServices else {
            return
        }

        CotabbyLogger.app.info("Cotabby terminating, releasing services")
        activationIndicatorController.hide(reason: "Activation indicator hidden because Cotabby is terminating.")
        focusDebugOverlayController?.hide()
        suggestionCoordinator.stop()
        emojiPickerController.stop()
        inputMonitor.stop()
        focusModel.stop()

        runtimeModel.shutdownSync(timeoutSeconds: 1.5)
    }

    /// Shows or hides the field-edge Cotabby icon based on focus state, global enable, per-app
    /// disable rules, and the user's indicator toggle.
    private func updateActivationIndicator(for snapshot: FocusSnapshot) {
        guard suggestionSettings.isGloballyEnabled,
              !suggestionSettings.isApplicationDisabled(bundleIdentifier: snapshot.bundleIdentifier),
              case .supported = snapshot.capability,
              let context = snapshot.context
        else {
            activationIndicatorController.hide(reason: "Activation indicator hidden.")
            return
        }

        activationIndicatorController.show(
            enabled: suggestionSettings.showIndicator,
            caretRect: context.caretRect,
            inputFrameRect: context.inputFrameRect
        )
    }

    /// Warm the local runtime only when the user is actually on a local engine path.
    /// This avoids noisy startup failures and wasted work for Apple Intelligence users.
    private func startRuntimeIfPreferredEngineRequiresIt() {
        switch suggestionSettings.selectedEngine {
        case .llamaOpenSource:
            runtimeModel.startIfNeeded()
        case .appleIntelligence:
            break
        }
    }

    /// Model availability can change after downloads or manual file drops. Re-scan first, then
    /// warm the runtime only if the current engine choice needs it.
    private func handleModelDirectoryChange() {
        runtimeModel.refreshAvailableModels()
        startRuntimeIfPreferredEngineRequiresIt()
    }

    /// Xcode's app-hosted unit tests launch the real menu-bar app binary before loading the test
    /// bundle. Those tests instantiate focused services directly, so starting global taps, focus
    /// polling, Sparkle, and the llama runtime in the host process only adds side effects and can
    /// crash before a test assertion runs. The environment variable is supplied by XCTest only.
    private static var isRunningUnderXCTest: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}
