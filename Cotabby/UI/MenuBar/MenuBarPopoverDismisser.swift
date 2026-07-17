import AppKit
import Combine
import SwiftUI

/// Captures the `NSWindow` that backs a `MenuBarExtra(.window)` popover so SwiftUI buttons can
/// programmatically dismiss the popover the same way a `Link` would.
///
/// Why this exists:
/// `MenuBarExtra` with `.window` style does not surface its host window through SwiftUI's
/// `@Environment(\.dismiss)` action, so a `Button` action stays open after firing. `Link` gets
/// dismissal for free because `NSWorkspace.shared.open` resigns key from the popover. Every other
/// button that triggers an app-window transition (Settings, eventually Onboarding/Welcome) needs
/// to dismiss the popover itself or it sits on top of the just-opened window.
///
/// The dismisser hooks into the same `viewDidMoveToWindow` lifecycle that
/// `MenuBarPresentationObserver` uses to grab the popover's real `NSWindow`, then stores a weak
/// reference so the SwiftUI side can call `dismiss()` on demand.
@MainActor
final class MenuBarPopoverDismisser: ObservableObject {
    /// Weak so it dies with the popover; the SwiftUI view never owns the AppKit window.
    fileprivate weak var hostWindow: NSWindow?

    /// Closes the captured popover and clears the status bar button's pressed-state highlight.
    /// Safe to call when the popover isn't visible — `orderOut` is a no-op on a hidden window.
    func dismiss() {
        // `resignKey` first so any responder-chain bookkeeping (e.g. a focused text field) flushes
        // before the window goes off-screen; `orderOut` then matches the system's own popover
        // dismissal animation path.
        hostWindow?.resignKey()
        hostWindow?.orderOut(nil)
        // The status bar button keeps its highlighted/pressed appearance after a programmatic
        // `orderOut` because AppKit only clears that state when the popover dismisses through its
        // own click-toggle path. Walk our own windows for the `NSStatusBarButton` and reset the
        // highlight so the menu bar icon doesn't look stuck in the "open" state once Settings is up.
        Self.unhighlightStatusBarButton()
    }

    private static func unhighlightStatusBarButton() {
        for window in NSApp.windows {
            guard let contentView = window.contentView else { continue }
            if let button = findStatusBarButton(in: contentView) {
                button.highlight(false)
                return
            }
        }
    }

    private static func findStatusBarButton(in view: NSView) -> NSStatusBarButton? {
        if let button = view as? NSStatusBarButton {
            return button
        }
        for subview in view.subviews {
            if let button = findStatusBarButton(in: subview) {
                return button
            }
        }
        return nil
    }
}

/// Invisible `NSView` whose only job is to forward its host `NSWindow` to a
/// `MenuBarPopoverDismisser`. Attached as a `.background` modifier so it inherits the popover's
/// real backing window without affecting layout.
struct MenuBarPopoverDismisserBinder: NSViewRepresentable {
    let dismisser: MenuBarPopoverDismisser
    let onWindowBind: (NSWindow) -> Void

    init(
        dismisser: MenuBarPopoverDismisser,
        onWindowBind: @escaping (NSWindow) -> Void = { _ in }
    ) {
        self.dismisser = dismisser
        self.onWindowBind = onWindowBind
    }

    func makeNSView(context: Context) -> WindowBindingView {
        let view = WindowBindingView()
        view.dismisser = dismisser
        view.onWindowBind = onWindowBind
        return view
    }

    func updateNSView(_ nsView: WindowBindingView, context: Context) {
        nsView.dismisser = dismisser
        nsView.onWindowBind = onWindowBind
    }

    final class WindowBindingView: NSView {
        weak var dismisser: MenuBarPopoverDismisser?
        var onWindowBind: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // `window` is nil while the popover is being torn down. Skipping the update in that
            // case keeps a stale reference from outliving the actual popover instance.
            if let window {
                dismisser?.hostWindow = window
                onWindowBind?(window)
            }
        }
    }
}
