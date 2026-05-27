import AppKit
import Foundation

/// File overview:
/// Coordinates Cotabby's guided permission flow.
///
/// `PermissionManager` answers whether a permission is granted. This controller answers how we
/// guide the user through granting it. Keeping those roles separate avoids turning the permission
/// state store into an AppKit window manager.
@MainActor
final class PermissionGuidanceController {
    private let permissionManager: PermissionManager
    private let hostApp: PermissionHostApp

    private var overlayController: PermissionOverlayWindowController?
    private var trackingTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var activePermission: CotabbyPermissionKind?
    private var pendingSourceFrameInScreen: CGRect?
    private var hasPresentedOverlay = false
    private var isOverlayVisible = false
    private var lastSettingsFrame: CGRect?

    init(
        permissionManager: PermissionManager,
        hostApp: PermissionHostApp? = nil
    ) {
        self.permissionManager = permissionManager
        self.hostApp = hostApp ?? PermissionHostApp.current()
    }

    deinit {
        trackingTimer?.invalidate()
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    /// Public entry point used by onboarding and menu-bar permission buttons.
    ///
    /// The controller chooses the appropriate experience based on the permission's metadata. That
    /// keeps the view layer simple: onboarding asks for help with a permission, and this type
    /// decides whether that means a rich guided overlay or a plain Settings deep link.
    func requestAccess(for permission: CotabbyPermissionKind, sourceFrameInScreen: CGRect? = nil) {
        permissionManager.refresh()
        guard !permissionManager.isGranted(permission) else {
            return
        }

        permissionManager.requestSystemAccess(for: permission)
        guard !permissionManager.isGranted(permission) else {
            return
        }

        switch permission.guidanceStyle {
        case .guidedOverlay:
            presentGuidance(for: permission, sourceFrameInScreen: sourceFrameInScreen)
        case .settingsOnly:
            dismiss()
            permissionManager.openSettings(for: permission)
        }
    }

    func dismiss() {
        trackingTimer?.invalidate()
        trackingTimer = nil

        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }

        overlayController?.close()
        overlayController = nil
        activePermission = nil
        pendingSourceFrameInScreen = nil
        hasPresentedOverlay = false
        isOverlayVisible = false
        lastSettingsFrame = nil
    }

    private func presentGuidance(for permission: CotabbyPermissionKind, sourceFrameInScreen: CGRect?) {
        dismiss()
        permissionManager.refresh()
        guard !permissionManager.isGranted(permission) else {
            return
        }

        activePermission = permission
        pendingSourceFrameInScreen = sourceFrameInScreen
        overlayController = PermissionOverlayWindowController(
            hostApp: hostApp,
            permission: permission,
            onDismiss: { [weak self] in
                self?.dismiss()
            }
        )

        permissionManager.openSettings(for: permission)
        startTracking()
    }

    private func startTracking() {
        trackingTimer?.invalidate()
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self else {
                return
            }
            MainActor.assumeIsolated {
                self.refreshPosition()
            }
        }

        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else {
                return
            }
            MainActor.assumeIsolated {
                self.refreshPosition()
            }
        }

        refreshPosition()
    }

    private func refreshPosition() {
        guard let activePermission else {
            dismiss()
            return
        }

        permissionManager.refresh()
        guard !permissionManager.isGranted(activePermission) else {
            dismiss()
            return
        }

        // The tracker fires on a timer *and* on every app activation. Route the decision through a
        // pure rule and only touch the window when the action actually changes — re-ordering or
        // hiding on every tick is what made the helper flicker as focus moved between System
        // Settings, the macOS permission dialog, and Cotabby's own windows.
        let snapshot = SystemSettingsWindowLocator.frontmostWindow()
        switch PermissionOverlayTracker.transition(
            settingsFrame: snapshot?.frame,
            hasPresented: hasPresentedOverlay,
            isVisible: isOverlayVisible,
            lastFrame: lastSettingsFrame
        ) {
        case .present:
            guard let snapshot else { return }
            overlayController?.present(
                from: pendingSourceFrameInScreen,
                settingsFrame: snapshot.frame,
                visibleFrame: snapshot.visibleFrame
            )
            hasPresentedOverlay = true
            isOverlayVisible = true
            lastSettingsFrame = snapshot.frame

        case .reposition:
            guard let snapshot else { return }
            overlayController?.updatePosition(
                with: snapshot.frame,
                visibleFrame: snapshot.visibleFrame
            )
            isOverlayVisible = true
            lastSettingsFrame = snapshot.frame

        case .hide:
            overlayController?.hide()
            isOverlayVisible = false
            lastSettingsFrame = nil

        case .none:
            break
        }
    }
}
