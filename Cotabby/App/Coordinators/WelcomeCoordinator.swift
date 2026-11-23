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
        /// Keep a margin between the onboarding window and the screen edges when a step's preferred
        /// height would otherwise exceed the visible screen. The SwiftUI content scrolls to absorb
        /// the difference, so clamping here only ever shrinks the window, never clips the footer.
        static let screenEdgeMargin: CGFloat = 24
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

    /// Read fresh on every use rather than cached: UserDefaults is the source of truth, and the
    /// wizard's own callbacks rewrite it while a window is open.
    private var progress: OnboardingProgress {
        OnboardingProgress.load(from: userDefaults)
    }

    /// Presents the welcome wizard if the user has not completed the current onboarding version.
    ///
    /// Completion is stamped when the user finishes the wizard (taps "Start Using Cotabby"), not
    /// when the window first appears. So if the user closes the window mid-flow, or macOS forces a
    /// relaunch to apply a permission, the wizard reappears on next launch at the step they reached.
    func presentIfNeeded() {
        guard !progress.isCompleted else {
            return
        }

        showWelcome()
    }

    /// Shows just the permission step when the user completed onboarding previously but one or
    /// more required permissions are now missing (e.g., after a permission-prompted restart, or
    /// if the user later revoked a permission in System Settings).
    func presentPermissionReminderIfNeeded() {
        guard progress.isCompleted,
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

        let progress = self.progress

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
                },
                initialStep: progress.resumeStep,
                isReturningUser: progress.isReturningUser,
                onStepChange: { [weak self] step in
                    self?.recordProgress(reaching: step)
                }
            )
        )

        // Size the window for the step the wizard actually opens on (the resume point) so it never
        // flashes at one size and immediately animates to another.
        let windowController = makeOnboardingWindowController(
            title: "Welcome to Cotabby",
            contentSize: progress.resumeStep.preferredWindowSize,
            contentViewController: hostingController
        )
        welcomeWindowController = windowController
        present(windowController)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closingWindow = notification.object as? NSWindow else {
            return
        }

        // Either window can have the drag-helper guidance overlay anchored to one of its buttons,
        // so it must not outlive the window it points into.
        if closingWindow == welcomeWindowController?.window {
            permissionGuidanceController.dismiss()
            welcomeWindowController = nil
        } else if closingWindow == permissionReminderWindowController?.window {
            permissionGuidanceController.dismiss()
            permissionReminderWindowController = nil
        }
    }

    /// Both onboarding surfaces share one window recipe: chromeless (hidden title over a
    /// full-size content view) so the SwiftUI backdrop reads edge to edge, draggable from anywhere
    /// because there is no visible title bar to grab, and kept alive after close because the
    /// coordinator, not AppKit, decides when its controller is released.
    private func makeOnboardingWindowController(
        title: String,
        contentSize: NSSize,
        contentViewController: NSViewController
    ) -> NSWindowController {
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: contentSize),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.center()
        window.isReleasedWhenClosed = false
        window.level = .normal
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.delegate = self
        window.contentViewController = contentViewController
        return NSWindowController(window: window)
    }

    /// Cotabby is a menu bar (accessory) app, so it has to activate itself before a window it
    /// opens can become key; otherwise the window appears behind whatever app the user was in.
    private func present(_ windowController: NSWindowController) {
        NSApp.activate(ignoringOtherApps: true)
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
    }

    /// Called when the user completes the full onboarding wizard ("Start Using Cotabby"). This is
    /// the only thing that clears the gate: closing the window mid-flow leaves the stored progress
    /// unchanged, so the wizard returns on next launch.
    private func completeOnboarding() {
        let current = progress
        current.completing().save(to: userDefaults, replacing: current)
        permissionGuidanceController.dismiss()
        welcomeWindowController?.close()
    }

    private func recordProgress(reaching step: WelcomeStep) {
        let current = progress
        current.reaching(step).save(to: userDefaults, replacing: current)
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

        let windowController = makeOnboardingWindowController(
            title: "Cotabby — Permissions",
            contentSize: NSSize(width: 540, height: 420),
            contentViewController: hostingController
        )
        permissionReminderWindowController = windowController
        present(windowController)
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

        // Clamp the requested height so a tall step can never push the window taller than the screen,
        // which on smaller or scaled MacBook displays used to leave the bottom (and the Continue
        // button) off-screen with no way to reach it. The content scrolls to fill any shortfall.
        let clampedContentSize = clampedContentSize(contentSize, for: window)

        let currentContentSize = window.contentLayoutRect.size
        guard Swift.abs(currentContentSize.width - clampedContentSize.width) > 0.5
            || Swift.abs(currentContentSize.height - clampedContentSize.height) > 0.5 else {
            return
        }

        let targetWindowFrame = window.frameRect(forContentRect: NSRect(origin: .zero, size: clampedContentSize))
        let currentFrame = window.frame
        let centeredOrigin = NSPoint(
            x: currentFrame.midX - (targetWindowFrame.width / 2),
            y: currentFrame.midY - (targetWindowFrame.height / 2)
        )
        let centeredFrame = constrainedToScreen(
            NSRect(origin: centeredOrigin, size: targetWindowFrame.size),
            for: window
        )

        window.setFrame(centeredFrame.integral, display: true, animate: true)
    }

    /// Shrinks the requested content height to what fits within the active screen's visible frame
    /// (minus chrome and a margin). Width is left untouched.
    private func clampedContentSize(_ contentSize: NSSize, for window: NSWindow) -> NSSize {
        guard let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame else {
            return contentSize
        }

        let chromeHeight = window.frameRect(forContentRect: .zero).height
        let maxContentHeight = visibleFrame.height - chromeHeight - (Layout.screenEdgeMargin * 2)
        guard maxContentHeight > 0 else {
            return contentSize
        }

        return NSSize(width: contentSize.width, height: min(contentSize.height, maxContentHeight))
    }

    /// Nudges a proposed window frame so it stays fully within the visible screen after recentering.
    private func constrainedToScreen(_ frame: NSRect, for window: NSWindow) -> NSRect {
        guard let visibleFrame = (window.screen ?? NSScreen.main)?.visibleFrame else {
            return frame
        }

        var origin = frame.origin
        origin.x = min(max(origin.x, visibleFrame.minX + Layout.screenEdgeMargin),
                       visibleFrame.maxX - frame.width - Layout.screenEdgeMargin)
        origin.y = min(max(origin.y, visibleFrame.minY + Layout.screenEdgeMargin),
                       visibleFrame.maxY - frame.height - Layout.screenEdgeMargin)

        return NSRect(origin: origin, size: frame.size)
    }
}
