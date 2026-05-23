import AppKit
import SwiftUI

/// File overview:
/// Owns the first-run welcome experience. This type persists whether onboarding has already been
/// shown and manages the one compact AppKit window that hosts the SwiftUI welcome wizard.
///
/// We keep this in `App/` instead of `UI/` because it owns lifecycle and persistence, not just
/// rendering. In React terms, this is a tiny controller/store plus a window host.
@MainActor
final class WelcomeCoordinator: NSObject, NSWindowDelegate {
    private enum Layout {
        /// Match the first welcome step so the window does not flash at an oversized default before
        /// SwiftUI has a chance to report its preferred content size.
        static let initialContentSize = NSSize(width: 500, height: 320)
    }

    private let permissionManager: PermissionManager
    private let permissionGuidanceController: PermissionGuidanceController
    private let runtimeModel: RuntimeBootstrapModel
    private let modelDownloadManager: ModelDownloadManager
    private let suggestionSettings: SuggestionSettingsModel
    private let foundationModelAvailabilityService: FoundationModelAvailabilityService
    private let userDefaults: UserDefaults

    private var welcomeWindowController: NSWindowController?
    private var permissionReminderWindowController: NSWindowController?

    private static let onboardingCompletedDefaultsKey = "onboardingCompleted"

    init(
        permissionManager: PermissionManager,
        permissionGuidanceController: PermissionGuidanceController,
        runtimeModel: RuntimeBootstrapModel,
        modelDownloadManager: ModelDownloadManager,
        suggestionSettings: SuggestionSettingsModel,
        foundationModelAvailabilityService: FoundationModelAvailabilityService,
        userDefaults: UserDefaults = .standard
    ) {
        self.permissionManager = permissionManager
        self.permissionGuidanceController = permissionGuidanceController
        self.runtimeModel = runtimeModel
        self.modelDownloadManager = modelDownloadManager
        self.suggestionSettings = suggestionSettings
        self.foundationModelAvailabilityService = foundationModelAvailabilityService
        self.userDefaults = userDefaults
    }

    /// Whether the user completed the full onboarding wizard (reached "done" and dismissed).
    ///
    /// The legacy `hasShownWelcomeWindow` key is intentionally NOT migrated here. That key was
    /// set at presentation time (before the user finished), so treating it as "completed" would
    /// skip profile and model selection for upgrading users. Forcing one more pass through the
    /// wizard on upgrade is better than silently dropping steps.
    private var isOnboardingCompleted: Bool {
        userDefaults.bool(forKey: Self.onboardingCompletedDefaultsKey)
    }

    /// Presents the welcome wizard if the user has never completed onboarding.
    ///
    /// Unlike the previous approach, the completion flag is set when the user finishes the wizard
    /// (taps "Start Using tabby"), not when the window first appears. If the user closes the
    /// window mid-flow or macOS prompts a restart for permissions, the wizard will reappear on
    /// next launch so they don't lose their place.
    func presentIfNeeded() {
        guard !isOnboardingCompleted else {
            return
        }

        showWelcome()
    }

    /// Shows just the permission step when the user completed onboarding previously but one or
    /// more required permissions are now missing (e.g., after a permission-prompted restart, or
    /// if the user later revoked a permission in System Settings).
    func presentPermissionReminderIfNeeded() {
        guard isOnboardingCompleted,
              !permissionManager.requiredPermissionsGranted,
              permissionReminderWindowController == nil
        else {
            return
        }

        showPermissionReminder()
    }

    /// Manual entry point for reopening the welcome screen later from the menu.
    func showWelcome() {
        if let window = welcomeWindowController?.window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hostingController = NSHostingController(
            rootView: WelcomeView(
                permissionManager: permissionManager,
                runtimeModel: runtimeModel,
                modelDownloadManager: modelDownloadManager,
                suggestionSettings: suggestionSettings,
                foundationModelAvailabilityService: foundationModelAvailabilityService,
                permissionGuidanceController: permissionGuidanceController,
                onPreferredWindowSizeChange: { [weak self] size in
                    self?.resizeWelcomeWindow(to: size)
                },
                onDismiss: { [weak self] in
                    self?.completeOnboarding()
                }
            )
        )

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: Layout.initialContentSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to tabby"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self
        window.contentViewController = hostingController

        let windowController = NSWindowController(window: window)
        welcomeWindowController = windowController

        NSApp.activate(ignoringOtherApps: true)
        windowController.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else {
            return
        }

        if closingWindow == welcomeWindowController?.window {
            permissionGuidanceController.dismiss()
            welcomeWindowController = nil
        } else if closingWindow == permissionReminderWindowController?.window {
            permissionGuidanceController.dismiss()
            permissionReminderWindowController = nil
        }
    }

    /// Called when the user completes the full onboarding wizard ("Start Using tabby").
    /// Persists the completion flag so the wizard does not reappear.
    private func completeOnboarding() {
        userDefaults.set(true, forKey: Self.onboardingCompletedDefaultsKey)
        permissionGuidanceController.dismiss()
        welcomeWindowController?.close()
    }

    private func showPermissionReminder() {
        let hostingController = NSHostingController(
            rootView: PermissionReminderView(
                permissionManager: permissionManager,
                permissionGuidanceController: permissionGuidanceController,
                onDismiss: { [weak self] in
                    self?.dismissPermissionReminder()
                }
            )
        )

        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: NSSize(width: 540, height: 420)),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "tabby — Permissions"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self
        window.contentViewController = hostingController

        let windowController = NSWindowController(window: window)
        permissionReminderWindowController = windowController

        NSApp.activate(ignoringOtherApps: true)
        windowController.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
    }

    private func dismissPermissionReminder() {
        permissionGuidanceController.dismiss()
        permissionReminderWindowController?.close()
    }

    /// Window sizing is an AppKit responsibility, so the SwiftUI onboarding view reports its
    /// preferred content size upward and the coordinator applies it here.
    ///
    /// We keep the window centered while resizing because onboarding is a modal-like flow; letting
    /// the frame grow down and to the right makes it feel jumpy and accidental.
    private func resizeWelcomeWindow(to contentSize: NSSize) {
        guard let window = welcomeWindowController?.window else {
            return
        }

        let currentContentSize = window.contentLayoutRect.size
        guard abs(currentContentSize.width - contentSize.width) > 0.5
            || abs(currentContentSize.height - contentSize.height) > 0.5 else {
            return
        }

        let targetWindowFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: contentSize))
        let currentFrame = window.frame
        let centeredOrigin = NSPoint(
            x: currentFrame.midX - (targetWindowFrame.width / 2),
            y: currentFrame.midY - (targetWindowFrame.height / 2)
        )
        let centeredFrame = NSRect(origin: centeredOrigin, size: targetWindowFrame.size).integral

        window.setFrame(centeredFrame, display: true, animate: true)
    }
}
