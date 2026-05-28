import AppKit
import SwiftUI

/// File overview:
/// Custom hover-tooltip support for the Settings window and the menu-bar panel.
///
/// SwiftUI's `.help(_:)` does not render visible tooltips for LSUIElement apps on the macOS 26
/// beta, and an earlier AppKit attempt (#350) failed because the click-through overlay returned
/// `nil` from `hitTest(_:)` — which makes `NSToolTipManager` skip the view entirely, so the
/// `toolTip` property was set but never queried. This file replaces that with a hand-rolled
/// tracking + floating-panel implementation that does not depend on `NSToolTipManager` at all:
///
///   - An overlay `NSView` reports `nil` from `hitTest(_:)` so clicks still reach the SwiftUI
///     control underneath.
///   - The same view installs an `NSTrackingArea` whose `mouseEntered:`/`mouseExited:` callbacks
///     do *not* require hit testing — they fire purely on the mouse position vs the tracked
///     rect, which is exactly the property the previous attempt mistakenly relied on.
///   - On enter, after a short delay, we order in a borderless floating `NSPanel` next to the
///     anchor. The panel ignores mouse events, so the chicken-and-egg (mouse enters panel →
///     exits anchor → panel closes) cycle never happens.
///   - `.help(_:)` is still applied alongside so VoiceOver accessibility-help text stays wired
///     up; when SwiftUI's tooltip bridge is fixed, the overlay becomes a harmless redundancy.

extension View {
    /// Drop-in replacement for `.help(_:)` that also shows a visible tooltip via a floating panel.
    /// Use everywhere `.help(_:)` is used in Settings and the menu bar — see issue #350.
    func cotabbyHelp(_ text: String) -> some View {
        modifier(CotabbyTooltipModifier(text: text))
    }
}

private struct CotabbyTooltipModifier: ViewModifier {
    let text: String

    func body(content: Content) -> some View {
        content
            .help(text)
            .overlay(TooltipOverlay(text: text).accessibilityHidden(true))
    }
}

private struct TooltipOverlay: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSView {
        let view = TooltipTrackingView()
        view.text = text
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? TooltipTrackingView else { return }
        view.text = text
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: ()) {
        (nsView as? TooltipTrackingView)?.dismantle()
    }
}

/// Tracking-only NSView. Hit testing is intentionally disabled so clicks pass through to the
/// SwiftUI control beneath. Tracking-area entered/exited events fire independently of hit testing,
/// which is what makes the click-through-and-still-hover trick work here.
private final class TooltipTrackingView: NSView {
    var text: String = "" {
        didSet { refreshPanelContentIfShowing() }
    }

    private var trackingArea: NSTrackingArea?
    private var showWorkItem: DispatchWorkItem?
    private var panel: TooltipPanel?
    private var hostingView: NSHostingView<TooltipBody>?

    /// macOS shows the first tooltip after a longer delay and subsequent ones immediately while
    /// the user keeps scrubbing across help-equipped controls. Matching that behavior keeps the
    /// tooltips feeling native rather than chatty.
    private static var lastDismissedAt: Date = .distantPast
    private static let standardDelay: TimeInterval = 0.6
    private static let scrubbingWindow: TimeInterval = 0.5

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var isFlipped: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        scheduleShow()
    }

    override func mouseExited(with event: NSEvent) {
        cancelShow()
        hidePanelIfNeeded()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil {
            cancelShow()
            hidePanelIfNeeded()
        }
    }

    func dismantle() {
        cancelShow()
        panel?.orderOut(nil)
        panel = nil
        hostingView = nil
    }

    private func scheduleShow() {
        cancelShow()
        guard !text.isEmpty else { return }
        let delay = Date().timeIntervalSince(Self.lastDismissedAt) < Self.scrubbingWindow
            ? 0
            : Self.standardDelay
        let item = DispatchWorkItem { [weak self] in
            self?.showPanelNow()
        }
        showWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func cancelShow() {
        showWorkItem?.cancel()
        showWorkItem = nil
    }

    private func showPanelNow() {
        guard !text.isEmpty,
              let window,
              window.isVisible,
              window.isKeyWindow || NSApp.isActive
        else { return }

        let panel = ensurePanel()
        hostingView?.rootView = TooltipBody(text: text)
        hostingView?.layoutSubtreeIfNeeded()
        let contentSize = hostingView?.fittingSize ?? CGSize(width: 200, height: 24)
        panel.setContentSize(contentSize)

        // Position the panel just below the anchor view. AppKit windows are y-up, but our view is
        // flipped (y-down) — convert both edges through the window/screen to land the panel where
        // a native tooltip would sit.
        let belowAnchorInView = NSPoint(x: 0, y: bounds.maxY + 4)
        let belowAnchorInWindow = convert(belowAnchorInView, to: nil)
        let onScreen = window.convertPoint(toScreen: belowAnchorInWindow)
        // Flipped → on-screen y was the top edge of where we want the panel; subtract its height.
        let origin = NSPoint(x: onScreen.x, y: onScreen.y - contentSize.height)
        panel.setFrameOrigin(clampedOnScreen(origin: origin, size: contentSize))
        panel.orderFrontRegardless()
    }

    private func ensurePanel() -> TooltipPanel {
        if let panel {
            return panel
        }
        let host = NSHostingView(rootView: TooltipBody(text: text))
        host.autoresizingMask = [.width, .height]

        let panel = TooltipPanel(
            contentRect: CGRect(x: 0, y: 0, width: 200, height: 28),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = true
        panel.contentView = host

        self.panel = panel
        self.hostingView = host
        return panel
    }

    private func hidePanelIfNeeded() {
        guard let panel, panel.isVisible else { return }
        panel.orderOut(nil)
        Self.lastDismissedAt = Date()
    }

    private func refreshPanelContentIfShowing() {
        guard let hostingView, let panel, panel.isVisible else { return }
        hostingView.rootView = TooltipBody(text: text)
    }

    /// Keep the tooltip inside the active screen so a control flush against the screen edge
    /// doesn't push the panel into the abyss.
    private func clampedOnScreen(origin: NSPoint, size: CGSize) -> NSPoint {
        guard let screen = window?.screen ?? NSScreen.main else { return origin }
        let visible = screen.visibleFrame
        let clampedX = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
        let clampedY = min(max(origin.y, visible.minY + 4), visible.maxY - size.height - 4)
        return NSPoint(x: clampedX, y: clampedY)
    }
}

private final class TooltipPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// SwiftUI body of the tooltip. Sized with `fixedSize(vertical:)` so long help strings wrap up to
/// `maxWidth` instead of forcing a single line, which keeps the layout close to what AppKit's
/// native tooltips do.
private struct TooltipBody: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.primary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .frame(maxWidth: 280, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
            )
    }
}
