import Foundation

/// Identifies terminal emulator applications by bundle identifier.
///
/// Terminal apps have their own completion, history, and shell integrations that conflict with
/// ghost-text autocomplete. Tabby stays out of the way automatically so the user doesn't have to
/// manually disable each terminal they use.
enum TerminalAppDetector {
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
        "com.colliderli.iina-terminal",
        "io.rio.terminal",
    ]

    static func isTerminal(bundleIdentifier: String?) -> Bool {
        guard let bundleIdentifier else { return false }
        return terminalBundleIdentifiers.contains(bundleIdentifier)
    }
}
