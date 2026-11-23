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

    /// Everything one guided flow owns. Held as a single optional (`nil` means no guidance is
    /// showing) so the overlay window, its tracking timer and observer, and the overlay phase are
    /// created and torn down together.
    nonisolated private struct GuidanceSession {
        let permission: CotabbyPermissionKind
        /// Where the fly-in starts: the onboarding or menu control that asked for help.
        let sourceFrameInScreen: CGRect?
        let overlay: PermissionOverlayWindowController
        var trackingTimer: Timer?
        var activationObserver: NSObjectProtocol?
        var overlayPhase = PermissionOverlayPhase.notPresented
    }

    private var session: GuidanceSession?

    init(
        permissionManager: PermissionManager,
        hostApp: PermissionHostApp? = nil
    ) {
        self.permissionManager = permissionManager
        self.hostApp = hostApp ?? PermissionHostApp.current()
    }

    deinit {
        session?.trackingTimer?.invalidate()
        if let activationObserver = session?.activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    /// Public entry point used by onboarding and menu-bar permission buttons.
    ///
    /// Callers only ask for help with a permission. The system prompt is tried first, and the
    /// guided System Settings overlay is the fallback when macOS will not grant from the prompt.
    func requestAccess(for permission: CotabbyPermissionKind, sourceFrameInScreen: CGRect? = nil) {
        permissionManager.refresh()
        guard !permissionManager.isGranted(permission) else {
            return
        }

        permissionManager.requestSystemAccess(for: permission)
        guard !permissionManager.isGranted(permission) else {
            return
        }

        presentGuidance(for: permission, sourceFrameInScreen: sourceFrameInScreen)
    }

    func dismiss() {
        guard let session else {
            return
        }
        // Cleared first so the overlay's own dismiss callback, if closing triggers it, finds
        // nothing left to tear down.
        self.session = nil

        session.trackingTimer?.invalidate()
        if let activationObserver = session.activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
        session.overlay.close()
    }

    private func presentGuidance(for permission: CotabbyPermissionKind, sourceFrameInScreen: CGRect?) {
        dismiss()
        permissionManager.refresh()
        guard !permissionManager.isGranted(permission) else {
            return
        }

        session = GuidanceSession(
            permission: permission,
            sourceFrameInScreen: sourceFrameInScreen,
            overlay: PermissionOverlayWindowController(
                hostApp: hostApp,
                permission: permission,
                onDismiss: { [weak self] in
                    self?.dismiss()
                }
            )
        )

        permissionManager.openSettings(for: permission)
        startTracking()
    }

    private func startTracking() {
        session?.trackingTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self else {
                return
            }
            MainActor.assumeIsolated {
                self.refreshPosition()
            }
        }

        session?.activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
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
        guard let session else {
            return
        }

        permissionManager.refresh()
        guard !permissionManager.isGranted(session.permission) else {
            dismiss()
            return
        }

        // The tracker fires on a timer *and* on every app activation. Route the decision through a
        // pure rule and only touch the window when the action actually changes — re-ordering or
        // hiding on every tick is what made the helper flicker as focus moved between System
        // Settings, the macOS permission dialog, and Cotabby's own windows.
        let snapshot = SystemSettingsWindowLocator.frontmostWindow()
        let (transition, nextPhase) = PermissionOverlayTracker.transition(
            settingsFrame: snapshot?.frame,
            phase: session.overlayPhase
        )
        self.session?.overlayPhase = nextPhase

        // `present` and `reposition` are only ever decided when a Settings window was found.
        switch (transition, snapshot) {
        case (.present, let snapshot?):
            session.overlay.present(
                from: session.sourceFrameInScreen,
                settingsFrame: snapshot.frame,
                visibleFrame: snapshot.visibleFrame
            )

        case (.reposition, let snapshot?):
            session.overlay.updatePosition(
                with: snapshot.frame,
                visibleFrame: snapshot.visibleFrame
            )

        case (.hide, _):
            session.overlay.hide()

        case (.none, _), (.present, nil), (.reposition, nil):
            break
        }
    }
}
