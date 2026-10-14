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
        guard wordCount(text) >= minimumWords else { return .tooShort }
        guard input.selectedText.count <= maximumCharacters else { return .tooLong }
        return .eligible
    }

    /// Words by the system's word boundaries rather than spaces: Japanese, Chinese and Thai put no
    /// spaces between words, so a whole sentence there would otherwise count as one word.
    static func wordCount(_ text: String) -> Int {
        var count = 0
        text.enumerateSubstrings(in: text.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in
            count += 1
        }
        return count
    }

    /// Whether Cotabby is on where the selection is, by the same switches autocomplete honours: on
    /// globally, not paused, not off for Low Power Mode, the app not disabled, and the page's domain
    /// not disabled. Nil settings (the graph is going away) mean no.
    static func isAppAllowed(
        for input: FocusedInputSnapshot,
        settings: SuggestionSettingsSnapshot?,
        isLowPowerModeEnabled: Bool,
        disabledDomains: Set<String>
    ) -> Bool {
        guard let settings, settings.isGloballyEnabled, !settings.isTemporarilyPaused,
              !(isLowPowerModeEnabled && settings.isLowPowerModeAutoDisableEnabled),
              !settings.disabledAppBundleIdentifiers.contains(input.bundleIdentifier)
        else { return false }
        guard let urlString = input.focusedURLString else { return true }
        return !BrowserDomain.isHostDisabled(BrowserDomain.host(fromURLString: urlString), disabledDomains: disabledDomains)
    }
}
