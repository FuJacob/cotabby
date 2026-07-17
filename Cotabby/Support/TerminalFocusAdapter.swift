import CoreGraphics
import Foundation

/// Adapts cooperative shell state into the focus shape the suggestion pipeline already consumes.
///
/// The adapter is pure: socket lifecycle, app matching, and screen capture stay in services. A
/// zero caret is intentional while the OCR prompt anchor is unresolved; presentation suppresses
/// the overlay rather than painting a plausible-looking suggestion over unrelated terminal output.
enum TerminalFocusAdapter {
    static func adapt(
        _ snapshot: TerminalFocusSnapshot,
        terminalPid: Int32,
        focusChangeSequence: UInt64 = 0
    ) -> FocusedInputSnapshot {
        FocusedInputSnapshot(
            applicationName: applicationName(for: snapshot.terminalBundleIdentifier),
            bundleIdentifier: snapshot.terminalBundleIdentifier,
            processIdentifier: terminalPid,
            elementIdentifier: snapshot.sessionIdentity.elementIdentifier,
            role: TerminalInputRole.shell.rawValue,
            subrole: snapshot.shellType.rawValue,
            caretRect: snapshot.estimatedCursorRect ?? .zero,
            inputFrameRect: snapshot.promptLineRect ?? snapshot.terminalWindowFrame,
            caretSource: "TerminalShellIntegration",
            caretQuality: .estimated,
            observedCharWidth: snapshot.observedCellWidth ?? TerminalGeometryResolver.defaultCellMetrics.cellWidth,
            precedingText: snapshot.precedingText,
            trailingText: snapshot.trailingText,
            selection: NSRange(location: snapshot.cursorCharacterOffset, length: 0),
            isSecure: false,
            isIntegratedTerminal: TerminalAppDetector.hostsEmbeddedTerminal(
                bundleIdentifier: snapshot.terminalBundleIdentifier
            ),
            focusChangeSequence: focusChangeSequence,
            resolvedFieldStyle: ResolvedFieldStyle(
                fontName: "Menlo-Regular",
                fontPointSize: 13,
                colorHex: nil
            ),
            windowTitle: snapshot.workingDirectory,
            terminalWorkingDirectory: snapshot.workingDirectory,
            terminalTTY: snapshot.tty,
            sourceRevision: snapshot.sourceRevision
        )
    }

    private static func applicationName(for bundleIdentifier: String) -> String {
        applicationNames[bundleIdentifier] ?? bundleIdentifier
    }

    private static let applicationNames = [
        "com.mitchellh.ghostty": "Ghostty",
        "com.apple.Terminal": "Terminal",
        "com.googlecode.iterm2": "iTerm2",
        "net.kovidgoyal.kitty": "Kitty",
        "io.alacritty": "Alacritty",
        "co.zeit.hyper": "Hyper",
        "dev.warp.Warp-Stable": "Warp",
        "com.github.wez.wezterm": "WezTerm",
        "io.rio.terminal": "Rio",
        "com.microsoft.VSCode": "VS Code",
        "com.microsoft.VSCodeInsiders": "VS Code Insiders",
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "dev.zed.Zed": "Zed"
    ]
}
