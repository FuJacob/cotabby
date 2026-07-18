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
/// The window configuration mirrors the emoji picker (floats across spaces and fullscreen without
/// stealing focus), with `ignoresMouseEvents` false so the user can click to accept. Positioning
/// reuses `EmojiPickerPanelLayout` (flip-above and on-screen clamping).
@MainActor
final class InlinePreviewPanelController: InlinePreviewPresenting {
    var onClick: (() -> Void)?
    var onClickOutside: (() -> Void)?

    private(set) var isVisible = false

    private let model = InlinePreviewViewModel()
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?

    private lazy var panel: InlinePreviewPanel = {
        let panel = InlinePreviewPanel(
            contentRect: CGRect(x: 0, y: 0, width: 120, height: 30),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = false
        panel.animationBehavior = .none
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.hidesOnDeactivate = false
        return panel
    }()

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
        let visibleFrame = targetVisibleFrame(for: caretRect)
        let frame = EmojiPickerPanelLayout.frame(
            caretRect: caretRect,
            contentSize: contentSize,
            visibleFrame: visibleFrame
        )
        panel.setFrame(frame.integral, display: true)
        panel.orderFrontRegardless()

        if !isVisible {
            isVisible = true
            installClickMonitors()
        }
    }

    func hide() {
        guard isVisible else { return }
        isVisible = false
        removeClickMonitors()
        panel.orderOut(nil)
    }

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

    private func installClickMonitors() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
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

/// Non-activating panel: clicking to accept must never pull keyboard focus away from the app the user
/// is typing in.
private final class InlinePreviewPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
