import AppKit
import SwiftUI

/// File overview:
/// Shows and hides the answer card at the reply's caret.
///
/// One borderless, non-activating panel (it must never take focus from the app the user is replying
/// in), sized to the card's content and placed just under the caret line, where the answer will go,
/// or above it when there is no room below. The panel takes clicks: a click on the card inserts the
/// draft. Because the panel is non-activating and can never become key, the click leaves the host
/// app active and its caret where it was, so the paste lands in the reply. Owned by
/// `AnswerCoordinator`.
@MainActor
final class AnswerCardController {
    private var panel: AnswerPanel?

    var isVisible: Bool { panel?.isVisible ?? false }

    /// See `AnswerDraftEngine`: released through a nonisolated deinit.
    nonisolated deinit {}

    /// `caret` and `field` are in AppKit screen coordinates. The card starts at the caret and spans
    /// the rest of the field's width, within readable bounds.
    func show(_ offer: AnswerOffer, caret: CGRect, field: CGRect?, tabInserts: Bool, onInsert: @escaping () -> Void) {
        let panel = panel ?? Self.makePanel()
        self.panel = panel
        let view = FirstClickHostingView(rootView: AnswerCardView(offer: offer, tabInserts: tabInserts, onInsert: onInsert))
        let available = field.map { $0.maxX - caret.minX } ?? 560
        let width = min(max(available, 360), 560)
        view.frame.size.width = width
        let height = view.fittingSize.height
        let screen = NSScreen.screens.first { $0.frame.intersects(caret) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? caret
        var origin = CGPoint(x: caret.minX - 2, y: caret.minY - height - 4)
        if origin.y < visible.minY { origin.y = min(caret.maxY + 4, visible.maxY - height) }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - width - 8)
        panel.contentView = view
        panel.setFrame(CGRect(origin: origin, size: CGSize(width: width, height: height)), display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private static func makePanel() -> AnswerPanel {
        let panel = AnswerPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none
        return panel
    }
}

/// Never key or main: the card must not steal focus from the reply field.
private final class AnswerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// A window that is not key would otherwise spend the first click on activation and deliver
/// nothing; accepting the first mouse makes that one click insert.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
