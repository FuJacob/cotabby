import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Small AX boundary for terminal-window metadata.
///
/// Terminal text is opaque, but the owning app still exposes its active window frame and title.
/// OCR coordinators use the frame to map Vision boxes into screen coordinates and the TUI detector
/// may use the title as its cheapest Claude Code signal.
@MainActor
enum TerminalGeometryResolver {
    struct CellMetrics: Equatable, Sendable {
        let cellWidth: CGFloat
        let cellHeight: CGFloat
    }

    static let defaultCellMetrics = CellMetrics(cellWidth: 7.8, cellHeight: 17.0)

    static func terminalAppPid(forBundleIdentifier bundleIdentifier: String) -> Int32? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { $0.isActive })?.processIdentifier
            ?? NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
                .first?.processIdentifier
    }

    /// Returns the active terminal frame in Accessibility/ScreenCaptureKit's top-left coordinate
    /// space. Conversion to AppKit happens only after prompt/caret geometry has been resolved.
    static func windowFrame(forPid pid: pid_t) -> CGRect? {
        guard pid > 0 else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        if let window = window(from: kAXFocusedWindowAttribute as CFString, app: app),
           let frame = AXHelper.rectValue(for: "AXFrame" as CFString, on: window) {
            return frame
        }
        if let window = window(from: kAXMainWindowAttribute as CFString, app: app),
           let frame = AXHelper.rectValue(for: "AXFrame" as CFString, on: window) {
            return frame
        }
        return nil
    }

    static func windowTitle(forPid pid: pid_t) -> String? {
        guard pid > 0 else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.05)
        guard let window = window(from: kAXFocusedWindowAttribute as CFString, app: app) else {
            return nil
        }
        return AXHelper.stringValue(for: kAXTitleAttribute as CFString, on: window)
    }

    private static func window(from attribute: CFString, app: AXUIElement) -> AXUIElement? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, attribute, &raw) == .success,
              let raw else { return nil }
        return unsafeBitCast(raw, to: AXUIElement.self)
    }
}
