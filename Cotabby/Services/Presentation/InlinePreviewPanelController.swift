import AppKit
import CoreGraphics
import SwiftUI

/// The macro inline-preview panel's behavior, behind a protocol so `MacroController` can be unit
/// tested without constructing a real `NSPanel`.
@MainActor
protocol InlinePreviewPresenting: AnyObject {
    /// Called when the user clicks the preview to accept it.
    var onClick: (() -> Void)? { get set }
    /// Called when the user clicks anywhere outside the panel, so the controller can cancel.
    var onClickOutside: (() -> Void)? { get set }

    func show(previewText: String, caretRect: CGRect, acceptKeyLabel: String?)
    func hide()
}

/// File overview:
/// Owns the non-activating floating panel that renders the single-row macro preview near the caret.
/// Like the emoji picker's it is the interactive kind of `NonActivatingPanel`, so the user can click
/// to accept without the click pulling keyboard focus out of the app they are typing in.
/// Positioning reuses `EmojiPickerPanelLayout` (flip-above and on-screen clamping).
@MainActor
final class InlinePreviewPanelController: InlinePreviewPresenting {
    var onClick: (() -> Void)?
    var onClickOutside: (() -> Void)?

    /// Present exactly while the panel is up, so a click outside it can cancel the preview.
    private var clickAwayMonitor: ClickAwayMonitor?

    private let model = InlinePreviewViewModel()

    private lazy var panel = NonActivatingPanel.makeInteractive(contentSize: CGSize(width: 120, height: 30))

    private lazy var hostingView: NSHostingView<InlinePreviewView> = {
        NSHostingView(
            rootView: InlinePreviewView(model: model) { [weak self] in
                self?.onClick?()
            }
        )
    }()

    func show(previewText: String, caretRect: CGRect, acceptKeyLabel: String?) {
        model.previewText = previewText
        model.acceptKeyLabel = acceptKeyLabel

        if panel.contentView !== hostingView {
            panel.contentView = hostingView
        }
        hostingView.layoutSubtreeIfNeeded()
        let fitting = hostingView.fittingSize
        let contentSize = CGSize(width: max(fitting.width, 44), height: max(fitting.height, 30))
        let visibleFrame = NSScreen.visibleFrame(containing: caretRect)
        let frame = EmojiPickerPanelLayout.frame(
            caretRect: caretRect,
            contentSize: contentSize,
            visibleFrame: visibleFrame
        )
        panel.setFrame(frame.integral, display: true)
        panel.orderFrontRegardless()

        if clickAwayMonitor == nil {
            clickAwayMonitor = ClickAwayMonitor(panel: panel) { [weak self] in
                self?.onClickOutside?()
            }
        }
    }

    func hide() {
        guard let clickAwayMonitor else { return }
        clickAwayMonitor.remove()
        self.clickAwayMonitor = nil
        panel.orderOut(nil)
    }
}
