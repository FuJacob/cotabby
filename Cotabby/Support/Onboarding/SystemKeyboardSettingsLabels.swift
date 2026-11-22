import Foundation

/// File overview:
/// The words System Settings uses on the way to the inline predictive text switch, in the user's
/// macOS language.
///
/// Cotabby's own interface is English, but the user follows the directions in System Settings,
/// which speaks the system language: a German Mac says "Texteingabe › Bearbeiten …" and
/// "Inline-Textvorschläge einblenden". English labels there would send the user looking for words
/// that are not on screen. The Keyboard settings extension carries these strings for every language
/// it supports, so they are read from it at runtime. Any label that cannot be resolved (macOS before 15.4,
/// a moved bundle, a renamed key) falls back to the English wording, which is what the
/// directions said before.
struct SystemKeyboardSettingsLabels: Equatable {
    static let english = SystemKeyboardSettingsLabels(
        textInput: "Text Input",
        edit: "Edit\u{2026}",
        showInlinePredictiveText: "Show inline predictive text"
    )

    static let keyboardSettingsBundlePath = "/System/Library/ExtensionKit/Extensions/KeyboardSettings.appex"

    let textInput: String
    let edit: String
    let showInlinePredictiveText: String

    /// The sentence both the onboarding callout and the week-later reminder use.
    var turnOffInstruction: String {
        "In Keyboard settings, choose \(textInput) \u{203A} \(edit) and turn off "
            + "\u{201C}\(showInlinePredictiveText)\u{201D} so only Cotabby suggests."
    }

    /// Resolves each English label through `lookup`; a nil or empty result keeps the English one.
    static func resolved(using lookup: (String) -> String?) -> SystemKeyboardSettingsLabels {
        func label(_ english: String) -> String {
            guard let localized = lookup(english), !localized.isEmpty else { return english }
            return localized
        }
        return SystemKeyboardSettingsLabels(
            textInput: label(english.textInput),
            edit: label(english.edit),
            showInlinePredictiveText: label(english.showInlinePredictiveText)
        )
    }

    /// The labels in the user's macOS language, read once per launch.
    static let current: SystemKeyboardSettingsLabels = resolved(using: systemLookup())

    /// Looks a label up in the Keyboard settings extension in the user's preferred language.
    /// The language is chosen explicitly: a plain lookup would follow Cotabby's own English-only
    /// bundle rather than the system language.
    private static func systemLookup() -> (String) -> String? {
        guard #available(macOS 15.4, *),
              let bundle = Bundle(path: keyboardSettingsBundlePath) else {
            return { _ in nil }
        }
        let languages = Bundle.preferredLocalizations(
            from: bundle.localizations,
            forPreferences: Locale.preferredLanguages
        ).map { Locale.Language(identifier: $0) }
        return { key in
            let missing = "\u{0}"
            let value = bundle.localizedString(forKey: key, value: missing, table: nil, localizations: languages)
            return value == missing ? nil : value
        }
    }
}
