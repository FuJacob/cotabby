import SwiftUI

/// File overview:
/// Editor for the user's custom autocomplete rules. Rules are short imperative style directives
/// (e.g. "Use British spelling") shown as removable chips, added freeform or by tapping a suggested
/// chip. "Clear" removes every rule (rules are opt-in, so the baseline is empty).
///
/// The chip and flow-layout primitives live in `TagChip.swift`, shared with `LanguageTagsEditor`.
struct CustomRulesEditor: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel

    @State private var inputText: String = ""

    private var rules: [String] { suggestionSettings.customRules }

    private var atCap: Bool { rules.count >= CustomRulesCatalog.maxRules }

    /// Palette entries the user has not already added (case-insensitive).
    private var availableSuggestions: [String] {
        let existing = Set(rules.map { $0.lowercased() })
        return CustomRulesCatalog.suggestedPalette.filter { !existing.contains($0.lowercased()) }
    }

    private var canClear: Bool {
        suggestionSettings.customRules != CustomRulesCatalog.defaultRules
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Rules")
                    .font(.system(size: 13, weight: .medium))
                    .cotabbyHelp("Short style instructions added to every prompt, like \"no em dashes\" "
                        + "or \"prefer short sentences\". Stored only on your Mac.")
                Spacer()
                if canClear {
                    Button("Clear") {
                        suggestionSettings.clearRules()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .cotabbyHelp("Remove all custom rules.")
                }
            }

            if !rules.isEmpty {
                TagFlowLayout(spacing: 10) {
                    ForEach(rules, id: \.self) { rule in
                        RemovableTagChip(text: rule) {
                            suggestionSettings.removeRule(rule)
                        }
                    }
                }
            }

            TextField(
                atCap ? "Rule limit reached" : "Add a rule, e.g. Use British spelling",
                text: $inputText
            )
            .textFieldStyle(.roundedBorder)
            .disabled(atCap)
            .onSubmit(commit)
            .onChange(of: inputText) { _, newValue in
                // A trailing comma commits, matching common tag-entry behavior.
                if newValue.hasSuffix(",") {
                    commit()
                }
            }

            if !availableSuggestions.isEmpty, !atCap {
                Text("Suggestions")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)

                TagFlowLayout(spacing: 10) {
                    ForEach(availableSuggestions, id: \.self) { suggestion in
                        AddableTagChip(text: suggestion) {
                            suggestionSettings.addRule(suggestion)
                        }
                    }
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
        suggestionSettings.addRule(trimmed)
    }
}
