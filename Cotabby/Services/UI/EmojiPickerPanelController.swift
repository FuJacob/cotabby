import AppKit
import SwiftUI

/// File overview:
/// Owns the non-activating floating panel that renders the emoji picker near the caret. The window
/// configuration mirrors `OverlayController`'s ghost-text panel (so it floats across spaces and
/// fullscreen without stealing focus), with one deliberate difference: `ignoresMouseEvents` is false
/// so the user can click a row.
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

    private(set) var isVisible = false

    private let model = EmojiPickerViewModel()

    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?

    private lazy var panel: EmojiPickerPanel = {
        let panel = EmojiPickerPanel(
            contentRect: CGRect(x: 0, y: 0, width: EmojiPickerMetrics.width, height: EmojiPickerMetrics.rowHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // Unlike the ghost-text overlay, the picker is interactive, so it must receive mouse events.
        panel.ignoresMouseEvents = false
        panel.animationBehavior = .none
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        return panel
    }()

    private lazy var hostingView: NSHostingView<EmojiPickerView> = {
        NSHostingView(
            rootView: EmojiPickerView(model: model) { [weak self] index in
                self?.onSelectIndex?(index)
            }
        )
    }()

    /// Shows or repositions the panel for the current query and matches. Recomputes the panel frame
    /// because the match count (and therefore the height) can change between calls.
    func show(query: String, matches: [EmojiMatch], selectedIndex: Int, caretRect: CGRect, acceptKeyLabel: String?) {
        model.query = query
        model.matches = matches
        model.selectedIndex = selectedIndex
        model.acceptKeyLabel = acceptKeyLabel

        let contentSize = EmojiPickerMetrics.contentSize(matchCount: matches.count)
        let visibleFrame = targetVisibleFrame(for: caretRect)
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

        if !isVisible {
            isVisible = true
            installClickMonitors()
        }
    }

    /// Updates only the highlighted row. Cheaper than `show` because the frame and match list are
    /// unchanged, so the list just re-highlights and scrolls the selection into view.
    func setSelectedIndex(_ index: Int) {
        model.selectedIndex = index
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        removeClickMonitors()
        panel.orderOut(nil)
    }

    // MARK: - Screen selection

    private func targetVisibleFrame(for caretRect: CGRect) -> CGRect {
        let midpoint = CGPoint(x: caretRect.midX, y: caretRect.midY)
        if let screen = NSScreen.screens.first(where: { $0.visibleFrame.contains(midpoint) }) {
            return screen.visibleFrame
        }
        if let screen = NSScreen.screens.first(where: { $0.frame.intersects(caretRect) }) {
            return screen.visibleFrame
        }
        return NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
    }

    // MARK: - Click-away dismissal (EMOJI.md §6.4)

    private func installClickMonitors() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            // A click in any other application is, by definition, outside our panel.
            self?.onClickOutside?()
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.panel {
                self.onClickOutside?()
            }
            return event
        }
    }

    private func removeClickMonitors() {
        if let globalMouseMonitor {
            NSEvent.removeMonitor(globalMouseMonitor)
            self.globalMouseMonitor = nil
        }
        if let localMouseMonitor {
            NSEvent.removeMonitor(localMouseMonitor)
            self.localMouseMonitor = nil
        }
    }
}

/// Non-activating panel: clicking a row must never pull keyboard focus away from the app the user is
/// typing in. `canBecomeKey` stays false, yet mouse-down is still delivered for row selection.
private final class EmojiPickerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
