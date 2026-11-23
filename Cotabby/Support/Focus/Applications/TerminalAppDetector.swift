import Foundation

/// Identifies terminal emulator applications by bundle identifier.
///
/// Terminal apps have their own completion, history, and shell integrations that conflict with
/// ghost-text autocomplete. Cotabby stays out of the way automatically so the user doesn't have to
/// manually disable each terminal they use.
nonisolated enum TerminalAppDetector {
    /// Bundle identifiers of well-known macOS terminal emulators, as each project's own Info.plist
    /// declares them. An id that is merely plausible fails silently here (the terminal just keeps
    /// getting suggestions), so check a new entry against the upstream bundle.
    private static let terminalBundleIdentifiers: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "net.kovidgoyal.kitty",
        // kitty's quick-access (drop-down) terminal is a separate bundle with its own id.
        "net.kovidgoyal.kitty-quick-access",
        // Alacritty 0.11 (2022) moved to `org.alacritty`; `io.alacritty` stays for older builds.
        "org.alacritty",
        "io.alacritty",
        "co.zeit.hyper",
        "dev.warp.Warp-Stable",
        "com.github.wez.wezterm",
        "com.raphaelamorim.rio"
    ]

    static func isTerminal(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return terminalBundleIdentifiers.contains(bundleIdentifier)
    }

    /// Hosts whose terminal is one Accessibility text area holding the whole screen (HerdrM, and
    /// Ghostty, whose surface HerdrM's terminal view is modelled on). Unlike the emulators above,
    /// Cotabby suggests there, by the user's choice, but only the caret's own line is the user's
    /// text: the rest of the screen (status lines, spinners, agent output) redraws on its own while
    /// the user types.
    private static let terminalScreenFieldBundleIdentifiers: Set<String> = [
        "dev.bybee.herdrm",
        "com.mitchellh.ghostty"
    ]

    static func isTerminalScreenField(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return terminalScreenFieldBundleIdentifiers.contains(bundleIdentifier)
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
