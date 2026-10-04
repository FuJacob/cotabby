import AppKit
import Foundation
import SwiftUI

/// File overview:
/// Owns the tiny non-activating panel that marks supported inputs with Cotabby's icon near
/// the field edge. Unlike the ghost-text overlay, this controller is focus-driven and toggled
/// by a simple boolean.
///
/// Keeping this as a separate controller preserves the architectural split between:
/// supported-field affordances and suggestion-specific UI.
@MainActor
final class ActivationIndicatorController {
    /// Field-edge mode should visually touch the input's outside edge.
    private let fieldEdgeGap: CGFloat = 0
    private let screenInset: CGFloat = 2

    private lazy var contentView: ClickableHostingView = {
        let view = ClickableHostingView(rootView: AnyView(EmptyView()))
        view.onClick = { [weak self] in
            guard let self else { return }
            self.onClick?(self.panel.frame)
        }
        return view
    }()

    /// Called with the icon's screen frame when the user clicks it; `AppDelegate` opens the
    /// field-scope popup from here.
    var onClick: ((CGRect) -> Void)?

    private lazy var panel: ActivationIndicatorPanel = {
        let panel = ActivationIndicatorPanel(
            contentRect: CGRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // Clickable: the icon opens the field-scope popup. It sits just outside the field's edge,
        // so taking its 14pt of clicks never covers the host's own text.
        panel.ignoresMouseEvents = false
        panel.hasShadow = false
        panel.animationBehavior = .none
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = contentView
        return panel
    }()

    private var isVisible = false

    /// Shows or hides the field-edge Cotabby icon indicator.
    func show(
        enabled: Bool,
        caretRect: CGRect,
        inputFrameRect: CGRect?,
        dimmed: Bool = false
    ) {
        guard enabled else {
            hide(reason: "Activation indicator hidden because it is disabled.")
            return
        }

        guard !caretRect.isEmpty else {
            hide(reason: "Activation indicator hidden because the caret rect was empty.")
            return
        }

        contentView.rootView = AnyView(FieldEdgeIconIndicatorView(dimmed: dimmed))
        contentView.layoutSubtreeIfNeeded()
        let contentSize = contentView.fittingSize
        let origin = fieldEdgeIconOrigin(
            caretRect: caretRect,
            inputFrameRect: inputFrameRect,
            contentSize: contentSize
        )

        let frame = CGRect(origin: origin, size: contentSize).integral
        if isVisible, panel.frame == frame, panel.isVisible {
            return
        }

        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        isVisible = true
    }

    /// Hides the indicator when Cotabby is not actively supporting the current field.
    func hide(reason _: String) {
        panel.orderOut(nil)
        isVisible = false
    }

    /// Places Cotabby's icon just outside the text area's left edge. When the field is flush against
    /// the screen edge we fall back to the right side so the icon stays fully visible.
    private func fieldEdgeIconOrigin(
        caretRect: CGRect,
        inputFrameRect: CGRect?,
        contentSize: CGSize
    ) -> CGPoint {
        let anchorRect = if let inputFrameRect, !inputFrameRect.isEmpty {
            inputFrameRect
        } else {
            caretRect
        }

        // Horizontal placement follows the field's edge, but vertical placement follows the *caret*.
        // Centering vertically on the field only reads as "beside this input" when the field is
        // about one line tall. In a document-shaped text area it is badly wrong: Word publishes the
        // whole page as one `AXTextArea` (846pt tall), so the icon landed halfway down an empty page,
        // hundreds of points below the line being typed. The caret is always on the active line, and
        // for single-line fields it sits at the field's own centre anyway, so short inputs are
        // unaffected. Falls back to the field when the caret rect is empty.
        let verticalAnchor = caretRect.isEmpty ? anchorRect : caretRect

        let preferredLeftX = anchorRect.minX - contentSize.width - fieldEdgeGap
        let fallbackRightX = anchorRect.maxX + fieldEdgeGap
        let centeredY = verticalAnchor.midY - (contentSize.height / 2)

        guard let screen = screen(for: anchorRect) else {
            return CGPoint(x: preferredLeftX, y: centeredY)
        }

        let visibleFrame = screen.visibleFrame
        let preferredX = preferredLeftX >= visibleFrame.minX + screenInset
            ? preferredLeftX
            : fallbackRightX

        let clampedX = min(
            max(preferredX, visibleFrame.minX + screenInset),
            visibleFrame.maxX - contentSize.width - screenInset
        )
        let clampedY = min(
            max(centeredY, visibleFrame.minY + screenInset),
            visibleFrame.maxY - contentSize.height - screenInset
        )

        return CGPoint(x: clampedX, y: clampedY)
    }

    /// Chooses the screen that currently contains the given rect's center point.
    private func screen(for rect: CGRect) -> NSScreen? {
        let midpoint = CGPoint(x: rect.midX, y: rect.midY)

        if let containingScreen = NSScreen.screens.first(where: {
            $0.visibleFrame.contains(midpoint)
        }) {
            return containingScreen
        }

        return NSScreen.screens.first(where: { $0.frame.intersects(rect) })
    }
}

private final class ActivationIndicatorPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosting view for the icon that turns a click into `onClick`.
///
/// `acceptsFirstMouse` returns true because the panel is never key (it is non-activating), and
/// without it AppKit would spend the first click making the window key instead of delivering it.
final class ClickableHostingView: NSHostingView<AnyView> {
    var onClick: (() -> Void)?

    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func mouseDown(with _: NSEvent) {
        onClick?()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }
}
