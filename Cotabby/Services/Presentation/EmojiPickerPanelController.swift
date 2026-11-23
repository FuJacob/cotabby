import AppKit
import SwiftUI

/// File overview:
/// Owns the non-activating floating panel that renders the emoji picker near the caret. It is the
/// interactive kind of `NonActivatingPanel`: unlike the ghost-text overlay it takes mouse events,
/// so the user can click a row, and a click anywhere else dismisses it (EMOJI.md §6.4).
///
/// The panel never becomes key. Keyboard navigation is driven entirely by the global event tap via
/// the controller, so the picker works while the user keeps typing in another app. This controller is
/// a thin AppKit shell: all selection and lifecycle logic lives in `EmojiPickerController`.
@MainActor
final class EmojiPickerPanelController: EmojiPickerPanelPresenting {
    /// Called with the row index when the user clicks a match.
    var onSelectIndex: ((Int) -> Void)?

    /// Called when the user clicks anywhere outside the panel, so the controller can cancel capture.
    var onClickOutside: (() -> Void)?

    /// Present exactly while the panel is up, so a click outside it can dismiss the picker.
    private var clickAwayMonitor: ClickAwayMonitor?

    private let model = EmojiPickerViewModel()

    private lazy var panel = NonActivatingPanel.makeInteractive(contentSize: EmojiPickerMetrics.contentSize(matchCount: 0))

    private lazy var hostingView: NSHostingView<EmojiPickerView> = {
        NSHostingView(
            rootView: EmojiPickerView(model: model) { [weak self] index in
                self?.onSelectIndex?(index)
            }
        )
    }()

    /// Shows or repositions the panel for the current query and matches. Recomputes the panel frame
    /// because the match count (and therefore the height) can change between calls.
    func show(query: String, matches: [EmojiMatch], selectedIndex: Int, caretRect: CGRect) {
        model.query = query
        model.matches = matches
        model.selectedIndex = selectedIndex

        let contentSize = EmojiPickerMetrics.contentSize(matchCount: matches.count)
        let visibleFrame = NSScreen.visibleFrame(containing: caretRect)
        let frame = EmojiPickerPanelLayout.frame(
            caretRect: caretRect,
            contentSize: contentSize,
            visibleFrame: visibleFrame
        )

        if panel.contentView !== hostingView {
            panel.contentView = hostingView
        }
        panel.setFrame(frame.integral, display: true)
        panel.orderFrontRegardless()

        if clickAwayMonitor == nil {
            clickAwayMonitor = ClickAwayMonitor(panel: panel) { [weak self] in
                self?.onClickOutside?()
            }
        }
    }

    /// Updates only the highlighted row. Cheaper than `show` because the frame and match list are
    /// unchanged, so the list just re-highlights and scrolls the selection into view.
    func setSelectedIndex(_ index: Int) {
        model.selectedIndex = index
    }

    func hide() {
        guard let clickAwayMonitor else { return }
        clickAwayMonitor.remove()
        self.clickAwayMonitor = nil
        panel.orderOut(nil)
    }
}
