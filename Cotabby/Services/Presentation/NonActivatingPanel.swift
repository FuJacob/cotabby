import AppKit

/// File overview:
/// The borderless floating panel every Cotabby overlay near the caret is drawn in: ghost text and
/// the card, the field-edge icon, the emoji picker, the macro preview and the debug overlays.
///
/// A non-activating panel that can never become key or main lets Cotabby draw (and, for the
/// interactive ones, take clicks) beside the caret without pulling keyboard focus out of the app
/// the user is typing in. The shared configuration keeps the panel on every Space and over
/// fullscreen apps, out of the window cycle, and free of AppKit's own show/hide animation so an
/// overlay reads as ink at the caret rather than a window being presented.
final class NonActivatingPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The level overlays that must sit above the field-edge icon use.
    static let aboveStatusBarLevel = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2)

    /// A transparent panel that ignores the mouse, for overlays that only draw.
    static func makeDisplayOnly(
        contentSize: CGSize = CGSize(width: 10, height: 10),
        level: NSWindow.Level = aboveStatusBarLevel
    ) -> NonActivatingPanel {
        let panel = make(contentSize: contentSize, level: level)
        panel.ignoresMouseEvents = true
        panel.hasShadow = false
        return panel
    }

    /// A panel the user can click. Mouse-down is still delivered with `canBecomeKey` false, and
    /// `hidesOnDeactivate` is off because Cotabby is never the active app while the user types.
    static func makeInteractive(contentSize: CGSize) -> NonActivatingPanel {
        let panel = make(contentSize: contentSize, level: aboveStatusBarLevel)
        panel.ignoresMouseEvents = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        return panel
    }

    private static func make(contentSize: CGSize, level: NSWindow.Level) -> NonActivatingPanel {
        let panel = NonActivatingPanel(
            contentRect: CGRect(origin: .zero, size: contentSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.animationBehavior = .none
        panel.level = level
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        return panel
    }
}

extension NSScreen {
    /// The screen an overlay anchored at `rect` belongs on: the one whose usable area holds the
    /// rect's centre, else one the rect touches at all (a caret under the menu bar or Dock is
    /// outside every visible frame). Nil when the rect is on no screen.
    static func overlayScreen(for rect: CGRect) -> NSScreen? {
        let midpoint = CGPoint(x: rect.midX, y: rect.midY)
        return screens.first { $0.visibleFrame.contains(midpoint) } ?? screens.first { $0.frame.intersects(rect) }
    }

    /// The visible frame of `overlayScreen(for:)`, else of the main screen.
    static func visibleFrame(containing rect: CGRect) -> CGRect {
        (overlayScreen(for: rect) ?? main)?.visibleFrame ?? CGRect(x: 0, y: 0, width: 800, height: 600)
    }
}
