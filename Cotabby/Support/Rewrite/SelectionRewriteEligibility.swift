import Foundation

/// File overview:
/// Pure gate for the selection-rewrite button. A selection qualifies when it is a draft worth
/// rewriting (at least two words) in a field the user may have rewritten: not a password field,
/// not a terminal (an emulator app or an integrated xterm.js terminal), and in an app where Cotabby
/// is on. "Too long" is a separate verdict so the popup can say why instead of
/// silently not appearing.
nonisolated enum SelectionRewriteEligibility {
    static let minimumWords = 2
    static let maximumCharacters = 2_000

    enum Verdict: Equatable {
        case eligible, noSelection, tooShort, tooLong, ineligible
    }

    static func verdict(for input: FocusedInputSnapshot, appAllowed: Bool) -> Verdict {
        // A terminal's selection is shell output or a command line, never a draft to polish, and
        // a pasted line break there can run a command.
        guard appAllowed, !input.isSecure, !input.isIntegratedTerminal,
              !TerminalAppDetector.isTerminal(bundleIdentifier: input.bundleIdentifier)
        else { return .ineligible }
        let text = input.selectedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .noSelection }
        guard text.split(whereSeparator: { $0.isWhitespace }).count >= minimumWords else { return .tooShort }
        guard input.selectedText.count <= maximumCharacters else { return .tooLong }
        return .eligible
    }
}
