import AppKit
import SwiftUI

/// File overview:
/// The two surfaces of selection rewrite: the button, which is the field-edge Cotabby icon turned
/// into a wand (`ActivationIndicatorController.showRewrite`), and the popup that opens beside it.
/// Reusing the icon keeps the affordance outside the field: a separate button at the caret would
/// cover the start of the selected text. The popup is a non-activating panel (like
/// the ghost-text overlay), so the host app stays the active app and keeps its selection; it takes
/// the keyboard as soon as it opens, so Return and typing go to the popup and never fall through to
/// the edited app (Return in a chat app would send the message). Owned by
/// `SelectionRewriteCoordinator`.
@MainActor
final class SelectionRewritePanelController {
    private let indicator: ActivationIndicatorController
    private var popupPanel: RewritePanel?

    init(indicator: ActivationIndicatorController) {
        self.indicator = indicator
    }
    /// The caret rect the popup was last opened at. Kept so `refit()` can recompute placement for
    /// the new content size with the same rule `showPopup` used.
    private var popupAnchor: CGRect?

    var isPopupKey: Bool { popupPanel?.isKeyWindow ?? false }

    /// Shows the rewrite button where the Cotabby icon sits, just outside the field's edge.
    /// `caretRect` and `fieldFrame` are AppKit screen coordinates (bottom-left origin).
    func showButton(caretRect: CGRect, fieldFrame: CGRect?, onPress: @escaping () -> Void) {
        indicator.showRewrite(caretRect: caretRect, inputFrameRect: fieldFrame, onPress: onPress)
    }

    /// Shows the popup beside the rewrite icon when it is on screen (else at `anchor`). With
    /// `takesKeyboard` it also becomes key, so its keystrokes reach the popup rather than the edited
    /// app; a notice passes false and leaves the host's keyboard alone.
    func showPopup(near anchor: CGRect, model: SelectionRewritePopupModel, takesKeyboard: Bool) {
        popupAnchor = indicator.rewriteIconFrame ?? anchor
        let panel = popupPanel ?? Self.makePanel()
        popupPanel = panel
        let hosting = FirstClickHostingView(rootView: SelectionRewritePopupView(model: model))
        panel.contentView = hosting
        place(panel, size: hosting.fittingSize)
        panel.orderFrontRegardless()
        // Keyboard only after the panel is on screen. `allowsKey` is what lets an NSPanel with
        // `.nonactivatingPanel` become key at all; the host app is not activated by this.
        panel.allowsKey = takesKeyboard
        if takesKeyboard { panel.makeKey() }
    }

    /// Resizes the popup to its content after a phase change (preview text arrives), then places it
    /// again with the same rule as `showPopup`, so it stays on screen as it grows.
    func refit() {
        guard let panel = popupPanel, let view = panel.contentView else { return }
        place(panel, size: view.fittingSize)
    }

    /// Closes both panels. Takes the keyboard back first (`allowsKey = false`) so that no later
    /// `makeKey` call can pull focus into a panel that is already gone.
    func hideAll() {
        indicator.endRewrite()
        popupPanel?.allowsKey = false
        popupPanel?.orderOut(nil)
    }

    /// The one placement rule for the popup, used by both `showPopup` and `refit`: below the caret
    /// when the popup fits there, otherwise above it, then clamped inside the visible frame of the
    /// screen that holds the caret's midpoint. The midpoint is used because the caret's origin can sit
    /// on a screen edge, and the origin can fall outside every screen's frame.
    private func place(_ panel: RewritePanel, size: CGSize) {
        guard let anchor = popupAnchor else { return }
        let midpoint = CGPoint(x: anchor.midX, y: anchor.midY)
        let screen = (NSScreen.screens.first { $0.frame.contains(midpoint) } ?? NSScreen.main)?.visibleFrame ?? .zero
        var origin = CGPoint(x: anchor.minX, y: anchor.minY - size.height - 8)
        if origin.y < screen.minY { origin.y = anchor.maxY + 8 }
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - size.height - 8)
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }

    /// Built like Cotabby's other floating panels: non-activating, floating above normal
    /// windows (`.statusBar`), visible on every Space and over full-screen apps, and with no
    /// open/close animation so it appears at the caret without lag.
    private static func makePanel() -> RewritePanel {
        let panel = RewritePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none
        panel.hidesOnDeactivate = false
        return panel
    }
}

/// A borderless panel that refuses key status unless `allowsKey` is set, which the popup does
/// while it is open.
private final class RewritePanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
}

/// A window that is not key would otherwise spend the first click on activation and deliver
/// nothing; accepting the first mouse makes that one click press the button or preset.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
