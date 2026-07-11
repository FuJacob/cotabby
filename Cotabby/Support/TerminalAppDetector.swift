import Foundation

/// Identifies terminal emulator applications by bundle identifier.
///
/// Terminal apps have their own completion, history, and shell integrations that conflict with
/// ghost-text autocomplete. Cotabby stays out of the way automatically so the user doesn't have to
/// manually disable each terminal they use.
nonisolated enum TerminalAppDetector {
    /// Bundle identifiers of well-known macOS terminal emulators.
    private static let terminalBundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "co.zeit.hyper",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable",
        "com.github.wez.wezterm",
        "io.rio.terminal"
    ]

    /// Apps that can host a shell pane while also exposing ordinary AX text fields in the same
    /// process. They receive terminal treatment only while an authoritative hook/TUI source is
    /// active; the editor and command palette continue through normal AX capture.
    private static let embeddedTerminalHostBundleIdentifiers: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
        "com.todesktop.230313mzl4w4u92", // Cursor
        "com.exafunction.windsurf",
        "dev.zed.Zed",
        "com.jetbrains.intellij"
    ]

    static func isTerminal(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return terminalBundleIdentifiers.contains(bundleIdentifier)
    }

    static func hostsEmbeddedTerminal(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return embeddedTerminalHostBundleIdentifiers.contains(bundleIdentifier)
    }

    static func isTerminalHost(bundleIdentifier: String?) -> Bool {
        isTerminal(bundleIdentifier: bundleIdentifier)
            || hostsEmbeddedTerminal(bundleIdentifier: bundleIdentifier)
    }

    /// DOM class prefix xterm.js stamps on every node of its terminal subtree — most importantly the
    /// focusable `xterm-helper-textarea` that receives the caret.
    private static let integratedTerminalClassPrefix = "xterm"

    /// Whether a focused web element's `AXDOMClassList` marks it as an xterm.js terminal surface.
    ///
    /// VS Code, Cursor, Windsurf, and browser-hosted terminals (ttyd, Jupyter) all render their
    /// terminal through xterm.js, so an `xterm`-prefixed class is a reliable, localization-independent
    /// signal for "the caret is inside an integrated terminal". This is the piece `isTerminal` can't
    /// provide: the editor, Copilot chat, and integrated terminal share one process, so the app-level
    /// bundle blocklist can only ever block or allow all three together. Matching the whole `xterm`
    /// prefix (not just `xterm-helper-textarea`) keeps detection working if xterm renames its input
    /// node or focus lands on a sibling like `xterm-screen`.
    static func isIntegratedTerminal(domClassList: [String]) -> Bool {
        domClassList.contains { $0.hasPrefix(integratedTerminalClassPrefix) }
    }
}
