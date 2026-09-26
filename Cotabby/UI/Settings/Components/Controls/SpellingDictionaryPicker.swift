import SwiftUI

/// Settings control for the bundled frequency dictionaries eligible for typo correction.
///
/// This view owns presentation only. `SuggestionSettingsModel` normalizes and persists each toggle,
/// while `SpellingLanguageResolver` and `SymSpellCorrector` own runtime selection and loading. Keeping
/// those responsibilities separate prevents a Settings view from constructing heavyweight indexes.
///
/// Relevance gating lives in the parent (`WritingPaneView`): the picker is only rendered once the
/// typo gate and at least one correction action are on, so the checkboxes here are always live and
/// carry no self-disabling logic. The enclosing `Section("Spelling Dictionaries")` supplies the
/// header, so this view starts straight at its explanatory caption.
struct SpellingDictionaryPicker: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(
                "Choose which bundled dictionaries Cotabby may use for frequency-ranked corrections. "
                    + "With several enabled, Cotabby selects one from the surrounding text."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(SpellingDictionaryLanguage.allCases) { language in
                    Toggle(
                        language.settingsLabel,
                        isOn: Binding(
                            get: {
                                suggestionSettings.isSpellingDictionaryEnabled(language)
                            },
                            set: {
                                suggestionSettings.setSpellingDictionary(
                                    language,
                                    enabled: $0
                                )
                            }
                        )
                    )
                    .toggleStyle(.checkbox)
                }
            }

            Text(
                "Indexes load on demand and Cotabby keeps at most two in memory. If no bundled "
                    + "dictionary matches, macOS supplies the correction."
            )
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 6)
    }
}
