import SwiftUI

/// Settings control for the bundled frequency dictionaries eligible for typo correction.
///
/// This view owns presentation only. `SuggestionSettingsModel` normalizes and persists each toggle,
/// while `SpellingLanguageResolver` and `SymSpellCorrector` own runtime selection and loading. Keeping
/// those responsibilities separate prevents a Settings view from constructing heavyweight indexes.
struct SpellingDictionaryPicker: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel

    /// The dictionary choices only change behavior when a correction can actually be produced and
    /// surfaced. The typo gate must be armed (`suppressCompletionsOnTypo`) and at least one
    /// correction path active: both "Offer Corrections on Typo" and "Automatically Fix Typos" rank
    /// candidates through the enabled SymSpell dictionaries (see `TypoGate`/`bestCorrection`). When
    /// none of those is on, ticking a dictionary has no observable effect, so we disable the
    /// checkboxes, mirroring how the correction toggles disable themselves when the gate is off.
    private var dictionariesAffectCorrections: Bool {
        suggestionSettings.suppressCompletionsOnTypo
            && (suggestionSettings.offerTypoCorrections || suggestionSettings.automaticallyFixTypos)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Spelling Dictionaries")
                .font(.system(size: 13, weight: .medium))

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
            .disabled(!dictionariesAffectCorrections)

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
