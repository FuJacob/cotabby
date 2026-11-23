import SwiftUI

/// File overview:
/// Editor for the languages the user writes in. Declared languages are removable chips, added by
/// tapping a suggestion (shown with its native name) or typing a custom one. Reset restores the
/// default language set.
struct LanguageTagsEditor: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel

    /// When false, the editor drops its own "Languages" title so an enclosing `Section("Languages")`
    /// can supply the heading without duplicating it. Defaults to true so standalone uses keep their
    /// inline title.
    var showsTitleHeader: Bool = true

    var body: some View {
        let languages = suggestionSettings.responseLanguages
        let existing = Set(languages.map { $0.lowercased() })

        TagListEditor(
            title: "Languages",
            showsTitleHeader: showsTitleHeader,
            items: languages,
            isAtCap: languages.count >= LanguageCatalog.maxLanguages,
            placeholder: "Add a language, e.g. German",
            atCapPlaceholder: "Language limit reached",
            // Palette entries the user has not already added, matched case-insensitively on the
            // stored English name while the chip shows the native one.
            suggestions: LanguageCatalog.commonLanguages
                .filter { !existing.contains($0.name.lowercased()) }
                .map { TagListEditor.Suggestion(value: $0.name, label: $0.nativeLabel) },
            // The hint can only ask the model to use a language; whether it actually can depends
            // on the chosen engine, so say so plainly rather than implying universal support.
            footnote: "Language support depends on your selected model. Apple Intelligence covers a fixed "
                + "set of languages, and local models vary, so some languages may not work.",
            canReset: languages != LanguageCatalog.defaultLanguages,
            onAdd: { suggestionSettings.addLanguage($0) },
            onRemove: { language in
                // Removing the last language is refused: an empty list would leave the model with
                // no target language to write in.
                guard suggestionSettings.responseLanguages.count > 1 else { return }
                suggestionSettings.removeLanguage(language)
            },
            onReset: { suggestionSettings.resetLanguages() }
        )
    }
}
