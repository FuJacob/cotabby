import Foundation

/// Cheaply decides whether the frontmost terminal may be hosting Claude Code.
///
/// Process and title signals deliberately precede OCR. A positive signal starts capture quickly;
/// an inconclusive terminal still falls back to OCR because sandboxed/launchd-owned process trees
/// often expose only the terminal host, not the TUI beneath it. Pixel-level confirmation remains
/// the authority before a focus snapshot is used, so an ordinary shell cannot become eligible just
/// because its process tree was inconclusive.
nonisolated enum TuiSessionDetector {
    enum Classification: Equatable, Sendable {
        case claudeCode
        case notClaudeCode
        case unknown
    }

    private static let processNames: Set<String> = ["claude", "claude-code"]
    private static let titleMarkers = ["Claude Code", "claude-code", " claude "]

    static func classification(
        bundleIdentifier: String?,
        terminalAccessibilityTitle: String?,
        foregroundProcessNames: () -> [String]
    ) -> Classification {
        guard TerminalAppDetector.isTerminalHost(bundleIdentifier: bundleIdentifier) else {
            return .notClaudeCode
        }

        if let title = terminalAccessibilityTitle {
            let paddedTitle = " \(title) "
            if titleMarkers.contains(where: {
                paddedTitle.range(of: $0, options: .caseInsensitive) != nil
            }) {
                return .claudeCode
            }
        }

        let names = foregroundProcessNames().map { $0.lowercased() }
        if names.contains(where: processNames.contains) {
            return .claudeCode
        }
        // A negative process lookup is not authoritative on macOS. Terminal children may be
        // launchd-owned, and without a sourced shell hook Cotabby has no shell PID from which to
        // traverse. Returning `.unknown` lets the narrow window OCR check for Claude Code chrome;
        // that reader still requires both a stable screen fingerprint and an editable prompt line.
        return .unknown
    }
}
