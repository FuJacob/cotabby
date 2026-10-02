import AppKit
import SwiftUI

/// Owns the small floating panel that holds `FieldScopeMenuView` next to the field-edge icon.
///
/// Why a non-activating `NSPanel` and not an `NSPopover` or menu: the user opens this mid-sentence
/// in another app (Teams, WhatsApp). Activating Cotabby would move keyboard focus out of the host's
/// compose field, and the host would see a focus change. A `.nonactivatingPanel` takes clicks
/// without becoming the active app, so the host keeps focus while the switches are flipped.
///
/// Lifetime: built once by `CotabbyAppEnvironment`; `AppDelegate` calls `show` when the icon is
/// clicked and `dismiss` when focus leaves the target window. The panel itself dismisses on a click
/// anywhere else or on Escape, through global event monitors installed only while it is open.
@MainActor
final class FieldScopeMenuController {
    private let panel: NSPanel
    private let hostingView = FirstMouseHostingView(rootView: AnyView(EmptyView()))
    /// Opaque tokens returned by `NSEvent.addGlobalMonitorForEvents`; removed on dismiss so no
    /// monitor outlives the panel.
    private var eventMonitors: [Any] = []
    private(set) var target: FieldScopeTarget?

    var isShown: Bool { panel.isVisible }

    init() {
        panel = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // The window is clear, so the window server shapes this shadow from the rounded content.
        panel.hasShadow = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        // Above the field-edge icon (`.statusBar`) so the popup is never covered by it.
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = hostingView
    }

    /// Shows `content` for `target` beside `anchorRect` (the icon's frame, AppKit screen coords).
    func show(_ content: some View, for target: FieldScopeTarget, anchorRect: CGRect) {
        self.target = target
        hostingView.rootView = AnyView(content)
        hostingView.layoutSubtreeIfNeeded()
        let size = hostingView.fittingSize
        panel.setFrame(CGRect(origin: Self.origin(for: size, anchorRect: anchorRect), size: size).integral, display: true)
        panel.orderFrontRegardless()
        installDismissMonitors()
    }

    func dismiss() {
        guard panel.isVisible || !eventMonitors.isEmpty else { return }
        panel.orderOut(nil)
        target = nil
        eventMonitors.forEach(NSEvent.removeMonitor)
        eventMonitors.removeAll()
    }

    /// Global monitors see events delivered to *other* apps, which is exactly "a click outside the
    /// panel" (clicks inside it are local events and never reach these).
    private func installDismissMonitors() {
        guard eventMonitors.isEmpty else { return }
        if let click = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }) {
            eventMonitors.append(click)
        }
        if let escape = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            guard event.keyCode == 53 else { return } // Escape
            MainActor.assumeIsolated { self?.dismiss() }
        }) {
            eventMonitors.append(escape)
        }
    }

    /// Below the icon, left edges aligned, flipped above it when there is no room below; clamped to
    /// the screen so the popup is always fully visible.
    private static func origin(for size: CGSize, anchorRect: CGRect) -> CGPoint {
        let gap: CGFloat = 6
        let midpoint = CGPoint(x: anchorRect.midX, y: anchorRect.midY)
        let visible = (NSScreen.screens.first { $0.frame.contains(midpoint) } ?? NSScreen.main)?.visibleFrame
            ?? CGRect(origin: .zero, size: size)
        var y = anchorRect.minY - gap - size.height
        if y < visible.minY { y = anchorRect.maxY + gap }
        let x = min(max(anchorRect.minX, visible.minX + 4), visible.maxX - size.width - 4)
        y = min(max(y, visible.minY + 4), visible.maxY - size.height - 4)
        return CGPoint(x: x, y: y)
    }
}

/// The panel is never key, so without `acceptsFirstMouse` AppKit would spend the first click on a
/// switch trying to make the window key instead of delivering it to the control.
private final class FirstMouseHostingView: NSHostingView<AnyView> {
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }
}
