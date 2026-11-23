import AppKit
import Foundation
import SwiftUI

/// File overview:
/// Owns the tiny non-activating panel that marks supported inputs with Cotabby's icon near
/// the field edge. Unlike the ghost-text overlay, this controller is focus-driven: every focus
/// snapshot either places the icon beside the field being typed in or takes it down.
///
/// Keeping this as a separate controller preserves the architectural split between:
/// supported-field affordances and suggestion-specific UI.
@MainActor
final class ActivationIndicatorController {
    private let screenInset: CGFloat = 2

    private lazy var contentView = NSHostingView(rootView: FieldEdgeIconIndicatorView())

    private lazy var panel: NonActivatingPanel = {
        // Below the ghost text and the pickers, which use `aboveStatusBarLevel`.
        let panel = NonActivatingPanel.makeDisplayOnly(level: .statusBar)
        panel.contentView = contentView
        return panel
    }()

    /// Shows or hides the field-edge Cotabby icon indicator.
    func show(
        enabled: Bool,
        caretRect: CGRect,
        inputFrameRect: CGRect?
    ) {
        // A caret with no line (see `CGRect.describesCaretLine`) cannot say which line to sit beside.
        guard enabled, caretRect.describesCaretLine else {
            hide()
            return
        }

        contentView.layoutSubtreeIfNeeded()
        let contentSize = contentView.fittingSize
        let origin = fieldEdgeIconOrigin(
            caretRect: caretRect,
            inputFrameRect: inputFrameRect,
            contentSize: contentSize
        )

        let frame = CGRect(origin: origin, size: contentSize).integral
        if panel.isVisible, panel.frame == frame {
            return
        }

        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    /// Hides the indicator when Cotabby is not actively supporting the current field.
    func hide() {
        panel.orderOut(nil)
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
        // unaffected. The icon touches the field's outside edge, with no gap.
        let preferredLeftX = anchorRect.minX - contentSize.width
        let fallbackRightX = anchorRect.maxX
        let centeredY = caretRect.midY - (contentSize.height / 2)

        guard let screen = NSScreen.overlayScreen(for: anchorRect) else {
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
}
