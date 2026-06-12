import Foundation

/// The coarse kind of writing surface the focused app presents. Drives prompt conditioning: what
/// surface the model is told it is continuing, and for which surfaces saying anything at all would
/// hurt (app metadata biases small base models toward code/numbers in editors and terminals).
nonisolated enum AppSurfaceClass: Equatable, Sendable {
    case codeEditor
    case terminal
    case email
    case chat
    case browser
    case other
}

/// Single source of truth for bundle-identifier → surface classification, shared by the
/// Foundation Models tone hints and the base-model surface preface so the two engines never
/// disagree about what kind of app the user is in.
///
/// The sets are intentionally small: each entry has to earn its place, so they cover the surfaces
/// real users write in most (code editors, email/chat clients, browsers) and everything else falls
/// through to `.other`. Cursor ships under opaque ToDesktop hashes (com.todesktop.<id>) that change
/// between builds, so prefix-matching it is unreliable and it is omitted intentionally.
nonisolated enum AppSurfaceClassifier {
    static func classify(bundleIdentifier: String?, isIntegratedTerminal: Bool = false) -> AppSurfaceClass {
        // An xterm.js surface inside an editor/browser process is a terminal regardless of the
        // host bundle, and terminal beats every other classification: shell prompts and pagers
        // must never get app-conditioned prose.
        if isIntegratedTerminal {
            return .terminal
        }
        guard let rawIdentifier = bundleIdentifier, !rawIdentifier.isEmpty else {
            return .other
        }
        // TerminalAppDetector matches exact, case-sensitive bundle ids; hand it the original.
        // The prefix tables below are lowercase, so everything else compares case-folded.
        if TerminalAppDetector.isTerminal(bundleIdentifier: rawIdentifier) {
            return .terminal
        }
        let identifier = rawIdentifier.lowercased()
        if codeEditorBundlePrefixes.contains(where: { identifier.hasPrefix($0) }) {
            return .codeEditor
        }
        if emailBundlePrefixes.contains(where: { identifier.hasPrefix($0) }) {
            return .email
        }
        if chatBundlePrefixes.contains(where: { identifier.hasPrefix($0) }) {
            return .chat
        }
        if BrowserAppDetector.isBrowser(bundleIdentifier: identifier) {
            return .browser
        }
        return .other
    }

    static let codeEditorBundlePrefixes: [String] = [
        "com.apple.dt.xcode",
        "com.microsoft.vscode",
        "com.jetbrains.",
        "com.sublimetext.",
        "com.panic.nova"
    ]

    static let emailBundlePrefixes: [String] = [
        "com.apple.mail",
        "com.readdle.smartemail",
        "com.airmailapp.airmail",
        "com.microsoft.outlook"
    ]

    static let chatBundlePrefixes: [String] = [
        "com.tinyspeck.slackmacgap",
        "com.microsoft.teams",
        "com.hnc.discord",
        "com.apple.mobilesms",
        "ru.keepcoder.telegram",
        "net.whatsapp.whatsapp"
    ]
}
