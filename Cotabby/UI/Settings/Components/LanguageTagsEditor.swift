import SwiftUI

/// File overview:
/// Editor for the languages the user writes in. Mirrors `CustomRulesEditor`: declared languages are
/// removable chips, added by tapping a suggestion (shown with its native name) or typing a custom
/// one. A bottom "Reset" button restores the default language set. The chip and flow-layout
/// primitives are shared via `TagChip.swift`.
struct LanguageTagsEditor: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel

    /// When false, the editor drops its own "Languages" title so an enclosing `Section("Languages")`
    /// can supply the heading without duplicating it. The Reset control stays in place either way.
    /// Defaults to true so standalone uses (e.g. onboarding) keep their inline title.
    var showsTitleHeader: Bool = true

    @State private var inputText: String = ""

    private var languages: [String] { suggestionSettings.responseLanguages }

    private var atCap: Bool { languages.count >= LanguageCatalog.maxLanguages }

    /// Palette entries the user has not already added, matched case-insensitively on the stored name.
    private var availableSuggestions: [LanguageOption] {
        let existing = Set(languages.map { $0.lowercased() })
        return LanguageCatalog.commonLanguages.filter { !existing.contains($0.name.lowercased()) }
    }

    private var canClear: Bool {
        suggestionSettings.responseLanguages != LanguageCatalog.defaultLanguages
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsTitleHeader {
                Text("Languages")
                    .font(.system(size: 13, weight: .medium))
            }

            if !languages.isEmpty {
                TagFlowLayout(spacing: 10) {
                    ForEach(languages, id: \.self) { language in
                        // Block removing the last language so the user can never reach an empty set.
                        // An empty list would leave the model with no target language to write in.
                        RemovableTagChip(text: language) {
                            guard languages.count > 1 else { return }
                            suggestionSettings.removeLanguage(language)
                        }
                    }
                }
            }

            TextField(
                atCap ? "Language limit reached" : "Add a language, e.g. German",
                text: $inputText
            )
            .textFieldStyle(.roundedBorder)
            .disabled(atCap)
            .onSubmit(commit)
            .onChange(of: inputText) { _, newValue in
                // A trailing comma commits, matching the rules editor and common tag entry.
                if newValue.hasSuffix(",") {
                    commit()
                }
            }

            if !availableSuggestions.isEmpty, !atCap {
                Text("Suggestions")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)

                TagFlowLayout(spacing: 10) {
                    ForEach(availableSuggestions) { option in
                        AddableTagChip(text: option.nativeLabel) {
                            suggestionSettings.addLanguage(option.name)
                        }
                    }
                }
            }

            // The hint can only ask the model to use a language; whether it actually can depends on
            // the chosen engine, so we say so plainly rather than implying universal support.
            Text("Language support depends on your selected model. Apple Intelligence covers a fixed "
                + "set of languages, and local models vary, so some languages may not work.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            if canClear {
                HStack {
                    Spacer()
                    Button {
                        suggestionSettings.clearLanguages()
                    } label: {
                        Label("Reset", systemImage: "arrow.counterclockwise")
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func commit() {
        let trimmed = inputText
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        inputText = ""
        guard !trimmed.isEmpty else { return }
        suggestionSettings.addLanguage(trimmed)
    }
}
