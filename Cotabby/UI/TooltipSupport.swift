import AppKit
import SwiftUI

/// File overview:
/// AppKit-backed tooltip support for the Settings window and the menu-bar panel.
///
/// SwiftUI's `.help(_:)` modifier silently stopped rendering tooltips on the macOS 26 beta in
/// menu-bar (LSUIElement) apps. Issue #313 wired up dozens of `.help(...)` calls that the user
/// can no longer see. Until SwiftUI's bridge is fixed we paint our own tooltip via an
/// `NSViewRepresentable` overlay that sets `NSView.toolTip` directly — AppKit's tooltip subsystem
/// still works fine in this environment. We also keep calling `.help(_:)` so accessibility help
/// stays wired up and the SwiftUI path "just starts working" again on a future macOS update.

extension View {
    /// Drop-in replacement for `.help(_:)` that also installs an AppKit tooltip overlay, so the
    /// tip is actually visible on macOS 26 beta where SwiftUI's tooltip bridge is broken.
    func cotabbyHelp(_ text: String) -> some View {
        modifier(CotabbyTooltipModifier(text: text))
    }
}

private struct CotabbyTooltipModifier: ViewModifier {
    let text: String

    func body(content: Content) -> some View {
        content
            .help(text)
            .overlay(TooltipOverlayView(text: text))
    }
}

/// Transparent NSView whose only job is to advertise a tooltip to AppKit's `NSToolTipManager`.
/// `hitTest` returns `nil` so the overlay never intercepts clicks meant for the underlying
/// SwiftUI control; tracking-area-based tooltip delivery is independent of hit testing.
private struct TooltipOverlayView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSView {
        let view = ClickThroughTooltipView()
        view.toolTip = text
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.toolTip = text
    }
}

private final class ClickThroughTooltipView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }
}
