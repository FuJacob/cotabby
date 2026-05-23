import SwiftUI

/// File overview:
/// Declares the SwiftUI app entry point and hosts the single menu-bar scene that renders
/// Tabby's compact status UI. Shared services are injected through `AppDelegate`.
///
/// `@main` marks the single process entry point for a Swift app.
@main
struct TabbyApp: App {
    /// Bridges old-style AppKit lifecycle callbacks into a SwiftUI app.
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    /// Defines the menu bar extra that surfaces Tabby's runtime, focus, and suggestion state.
    var body: some Scene {
        MenuBarExtra {
            MenuBarView(
                permissionManager: appDelegate.permissionManager,
                runtimeModel: appDelegate.runtimeModel,
                modelDownloadManager: appDelegate.modelDownloadManager,
                focusModel: appDelegate.focusModel,
                permissionGuidanceController: appDelegate.permissionGuidanceController,
                suggestionSettings: appDelegate.suggestionSettings,
                foundationModelAvailabilityService: appDelegate.foundationModelAvailabilityService,
                suggestionCoordinator: appDelegate.suggestionCoordinator,
                onOpenSettings: {
                    appDelegate.settingsCoordinator.showSettings()
                },
                onCheckForUpdates: {
                    appDelegate.appUpdateManager.checkForUpdates()
                }
            )
        } label: {
            MenuBarStatusLabelView()
        }
        .menuBarExtraStyle(.window)
    }
}
