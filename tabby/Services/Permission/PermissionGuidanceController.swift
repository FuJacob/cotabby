import AppKit
import Foundation

/// File overview:
/// Coordinates Tabby's guided permission flow.
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
    private var activePermission: TabbyPermissionKind?
    private var pendingSourceFrameInScreen: CGRect?
    private var didPresentCurrentOverlay = false

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
    func requestAccess(for permission: TabbyPermissionKind, sourceFrameInScreen: CGRect? = nil) {
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
        didPresentCurrentOverlay = false
    }

    private func presentGuidance(for permission: TabbyPermissionKind, sourceFrameInScreen: CGRect?) {
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
        trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in
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

        guard let snapshot = SystemSettingsWindowLocator.frontmostWindow() else {
            overlayController?.hide()
            return
        }

        if didPresentCurrentOverlay {
            overlayController?.updatePosition(
                with: snapshot.frame,
                visibleFrame: snapshot.visibleFrame
            )
            return
        }

        overlayController?.present(
            from: pendingSourceFrameInScreen,
            settingsFrame: snapshot.frame,
            visibleFrame: snapshot.visibleFrame
        )
        didPresentCurrentOverlay = true
    }
}
