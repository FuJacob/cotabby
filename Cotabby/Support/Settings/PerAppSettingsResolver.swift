import Foundation

/// Resolves the effective suggestion behavior for the app being typed in.
///
/// Every per-app choice is "follow the global setting, or force on/off" (`PerAppToggle`). Keeping
/// that rule in one pure type, like `ShortcutResolver` does for accept keys, means the request
/// factory, the typo gate, and the generation gate can never disagree about what "Default" means.
enum PerAppSettingsResolver {
    /// Whether a new suggestion may start while text follows the caret on its line. The global
    /// default is on: Cotabby already shows those suggestions as a card under the caret.
    static func allowsMidLineCompletions(bundleIdentifier: String?, settings: SuggestionSettingsSnapshot) -> Bool {
        behavior(bundleIdentifier, settings)?.midLineCompletions.resolve(default: true) ?? true
    }

    /// The typo gate's switches in this app. Turning autocorrect off disables all three, so a word
    /// that looks misspelled neither hides the completion nor gets a correction. Turning it on
    /// enables hiding and offering; automatic fixing stays the user's global choice because it
    /// edits text without asking.
    static func typoSettings(bundleIdentifier: String?, settings: SuggestionSettingsSnapshot) -> TypoGate.Settings {
        let global = TypoGate.Settings(
            suppressCompletionsOnTypo: settings.suppressCompletionsOnTypo,
            offerTypoCorrections: settings.offerTypoCorrections,
            automaticallyFixTypos: settings.automaticallyFixTypos
        )
        switch behavior(bundleIdentifier, settings)?.autocorrect ?? .useDefault {
        case .useDefault:
            return global
        case .on:
            return TypoGate.Settings(
                suppressCompletionsOnTypo: true,
                offerTypoCorrections: true,
                automaticallyFixTypos: settings.automaticallyFixTypos
            )
        case .off:
            return TypoGate.Settings(suppressCompletionsOnTypo: false, offerTypoCorrections: false, automaticallyFixTypos: false)
        }
    }

    /// Whether autocorrect is effectively on, for the "Default (on/off)" label in Settings.
    static func globalAutocorrectIsOn(_ settings: SuggestionSettingsSnapshot) -> Bool {
        settings.suppressCompletionsOnTypo && settings.offerTypoCorrections
    }

    /// Global Extended Context followed by this app's instructions, or nil when both are empty.
    /// They share one prompt section so both engines render app notes the same way global notes are
    /// rendered today.
    static func extendedContext(bundleIdentifier: String?, settings: SuggestionSettingsSnapshot) -> String? {
        let global = settings.extendedContext.trimmingCharacters(in: .whitespacesAndNewlines)
        let app = (behavior(bundleIdentifier, settings)?.instructions ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let combined = [global, app].filter { !$0.isEmpty }.joined(separator: "\n")
        return combined.isEmpty ? nil : combined
    }

    private static func behavior(_ bundleIdentifier: String?, _ settings: SuggestionSettingsSnapshot) -> PerAppBehavior? {
        guard let bundleIdentifier else { return nil }
        return settings.perAppBehaviors[bundleIdentifier]
    }
}
