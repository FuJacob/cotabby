import AppKit
import SwiftUI

/// File overview:
/// Owns Cotabby's settings window as a long-lived AppKit resource.
/// This lives in `App/` for the same reason as `WelcomeCoordinator`: window lifetime and activation
/// rules are application concerns, while SwiftUI only renders the content hosted inside the window.
///
/// In frontend terms, this is closer to a route/window controller than a pure view. The important
/// invariant is that the app only creates one settings window and reuses it when the user opens
/// Settings again from the menu.
@MainActor
final class SettingsCoordinator: NSObject, NSWindowDelegate {
    private let appUpdateManager: AppUpdateManager
    private let permissionManager: PermissionManager
    private let permissionGuidanceController: PermissionGuidanceController
    private let suggestionSettings: SuggestionSettingsModel
    private let foundationModelAvailabilityService: FoundationModelAvailabilityService
    private let runtimeModel: RuntimeBootstrapModel
    private let modelDownloadManager: ModelDownloadManager
    private let huggingFaceSearchService: HuggingFaceSearchService
    private let suggestionEngine: any SuggestionGenerating
    private let configuration: SuggestionConfiguration
    private let performanceMetricsStore: PerformanceMetricsStore
    private let systemMetricsStore: SystemMetricsStore
    private let onShowWelcome: () -> Void
    private let clearEmojiHistory: () -> Void

    private var settingsWindowController: NSWindowController?

    init(
        appUpdateManager: AppUpdateManager,
        permissionManager: PermissionManager,
        permissionGuidanceController: PermissionGuidanceController,
        suggestionSettings: SuggestionSettingsModel,
        foundationModelAvailabilityService: FoundationModelAvailabilityService,
        runtimeModel: RuntimeBootstrapModel,
        modelDownloadManager: ModelDownloadManager,
        huggingFaceSearchService: HuggingFaceSearchService,
        suggestionEngine: any SuggestionGenerating,
        configuration: SuggestionConfiguration,
        performanceMetricsStore: PerformanceMetricsStore,
        systemMetricsStore: SystemMetricsStore,
        onShowWelcome: @escaping () -> Void,
        clearEmojiHistory: @escaping () -> Void
    ) {
        self.appUpdateManager = appUpdateManager
        self.permissionManager = permissionManager
        self.permissionGuidanceController = permissionGuidanceController
        self.suggestionSettings = suggestionSettings
        self.foundationModelAvailabilityService = foundationModelAvailabilityService
        self.runtimeModel = runtimeModel
        self.modelDownloadManager = modelDownloadManager
        self.huggingFaceSearchService = huggingFaceSearchService
        self.suggestionEngine = suggestionEngine
        self.configuration = configuration
        self.performanceMetricsStore = performanceMetricsStore
        self.systemMetricsStore = systemMetricsStore
        self.onShowWelcome = onShowWelcome
        self.clearEmojiHistory = clearEmojiHistory
    }

    /// Shows the settings window, reusing the existing instance if it is already open.
    /// Reusing one window avoids subtle state duplication and matches standard macOS settings
    /// behavior where there is a single shared preferences surface for the app.
    func showSettings() {
        if let window = settingsWindowController?.window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hostingController = NSHostingController(
            rootView: AnyView(
                SettingsContainerView(
                    appUpdateManager: appUpdateManager,
                    permissionManager: permissionManager,
                    permissionGuidanceController: permissionGuidanceController,
                    suggestionSettings: suggestionSettings,
                    foundationModelAvailabilityService: foundationModelAvailabilityService,
                    runtimeModel: runtimeModel,
                    modelDownloadManager: modelDownloadManager,
                    huggingFaceSearchService: huggingFaceSearchService,
                    performanceMetricsStore: performanceMetricsStore,
                    systemMetricsStore: systemMetricsStore,
                    suggestionEngine: suggestionEngine,
                    configuration: configuration,
                    onShowWelcome: onShowWelcome,
                    clearEmojiHistory: clearEmojiHistory
                )
            )
        )
        // Sized so the native split view opens with a readable sidebar and a comfortable grouped
        // detail form. The user can still resize from here; the sidebar provides its own range.
        let initialFrame = CGRect(x: 0, y: 0, width: 980, height: 700)
        let minSize = NSSize(width: 900, height: 560)
        // Bump the autosave name to reset everyone onto the current default instead of restoring
        // any narrower frame saved by the previous sidebar experiments.
        let autosaveName = "CotabbySettingsWindowV6"

        let window = NSWindow(
            contentRect: initialFrame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Settings"
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.minSize = minSize
        window.setFrameAutosaveName(autosaveName)
        window.delegate = self
        window.contentViewController = hostingController

        let windowController = NSWindowController(window: window)
        settingsWindowController = windowController

        NSApp.activate(ignoringOtherApps: true)
        windowController.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else {
            return
        }

        if closingWindow == settingsWindowController?.window {
            settingsWindowController = nil
        }
    }
}
