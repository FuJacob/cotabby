import AppKit
import CoreGraphics
import SwiftUI

/// The generic row picker's floating panel, behind a protocol so controllers can be unit tested
/// without constructing a real `NSPanel`.
@MainActor
protocol CommandPickerPresenting: AnyObject {
    var onSelectIndex: ((Int) -> Void)? { get set }
    var onClickOutside: (() -> Void)? { get set }

    func show(rows: [CommandRow], headerText: String, selectedIndex: Int, caretRect: CGRect, acceptKeyLabel: String?)
    func setSelectedIndex(_ index: Int)
    func hide()
}

/// File overview:
/// Owns the non-activating floating panel that renders a generic `CommandPickerView` near the caret.
/// The window configuration mirrors the emoji picker (floats across spaces and fullscreen without
/// stealing focus) with `ignoresMouseEvents` false so the user can click a row. Sizing comes from the
/// injected `CommandPickerMetrics`; positioning reuses `EmojiPickerPanelLayout`.
@MainActor
final class CommandPickerPanelController: CommandPickerPresenting {
    var onSelectIndex: ((Int) -> Void)?
    var onClickOutside: (() -> Void)?

    private(set) var isVisible = false

    private let metrics: CommandPickerMetrics
    private let model = CommandPickerViewModel()

    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?

    init(metrics: CommandPickerMetrics) {
        self.metrics = metrics
        model.width = metrics.width
        model.rowHeight = metrics.rowHeight
        model.headerHeight = metrics.headerHeight
        model.emptyMessage = metrics.emptyMessage
    }

    private lazy var panel: CommandPickerPanel = {
        let panel = CommandPickerPanel(
            contentRect: CGRect(x: 0, y: 0, width: metrics.width, height: metrics.rowHeight),
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

    private lazy var hostingView: NSHostingView<CommandPickerView> = {
        NSHostingView(
            rootView: CommandPickerView(model: model) { [weak self] index in
                self?.onSelectIndex?(index)
            }
        )
    }()

    func show(rows: [CommandRow], headerText: String, selectedIndex: Int, caretRect: CGRect, acceptKeyLabel: String?) {
        model.rows = rows
        model.headerText = headerText
        model.selectedIndex = selectedIndex
        model.acceptKeyLabel = acceptKeyLabel

        let contentSize = metrics.contentSize(rowCount: rows.count)
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

    func setSelectedIndex(_ index: Int) {
        model.selectedIndex = index
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

/// Non-activating panel: clicking a row must never pull keyboard focus away from the app the user is
/// typing in.
private final class CommandPickerPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
