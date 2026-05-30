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
    private let launchAtLoginService: LaunchAtLoginService
    private let permissionManager: PermissionManager
    private let suggestionSettings: SuggestionSettingsModel
    private let foundationModelAvailabilityService: FoundationModelAvailabilityService
    private let runtimeModel: RuntimeBootstrapModel
    private let modelDownloadManager: ModelDownloadManager
    private let huggingFaceSearchService: HuggingFaceSearchService
    private let onShowWelcome: () -> Void

    private var settingsWindowController: NSWindowController?

    init(
        appUpdateManager: AppUpdateManager,
        launchAtLoginService: LaunchAtLoginService,
        permissionManager: PermissionManager,
        suggestionSettings: SuggestionSettingsModel,
        foundationModelAvailabilityService: FoundationModelAvailabilityService,
        runtimeModel: RuntimeBootstrapModel,
        modelDownloadManager: ModelDownloadManager,
        huggingFaceSearchService: HuggingFaceSearchService,
        onShowWelcome: @escaping () -> Void
    ) {
        self.appUpdateManager = appUpdateManager
        self.launchAtLoginService = launchAtLoginService
        self.permissionManager = permissionManager
        self.suggestionSettings = suggestionSettings
        self.foundationModelAvailabilityService = foundationModelAvailabilityService
        self.runtimeModel = runtimeModel
        self.modelDownloadManager = modelDownloadManager
        self.huggingFaceSearchService = huggingFaceSearchService
        self.onShowWelcome = onShowWelcome
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
                    launchAtLoginService: launchAtLoginService,
                    permissionManager: permissionManager,
                    suggestionSettings: suggestionSettings,
                    foundationModelAvailabilityService: foundationModelAvailabilityService,
                    runtimeModel: runtimeModel,
                    modelDownloadManager: modelDownloadManager,
                    huggingFaceSearchService: huggingFaceSearchService,
                    onShowWelcome: onShowWelcome
                )
            )
        )
        // Sized to fit the actual content: a fixed 260pt sidebar (see `SettingsSidebarView`)
        // plus a ~600pt detail column for the grouped form. The previous 1320x820 default with
        // a 1180 minimum was far wider than any pane's content, which is exactly what left the
        // detail area looking stretched and the window feeling empty.
        let initialFrame = CGRect(x: 0, y: 0, width: 860, height: 700)
        let minSize = NSSize(width: 820, height: 560)
        // Bump the autosave name so anyone holding a saved 1320-wide V3 frame gets the new
        // right-sized default once, instead of restoring the oversized window.
        let autosaveName = "CotabbySettingsWindowV4"

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
