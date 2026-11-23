import SwiftUI

/// File overview:
/// Editor for the user's custom autocomplete rules. Rules are short imperative style directives
/// (e.g. "Use British spelling") shown as removable chips, added freeform or by tapping a suggested
/// chip. Reset removes every rule, because rules are opt-in and the baseline is empty.
struct CustomRulesEditor: View {
    @ObservedObject var suggestionSettings: SuggestionSettingsModel

    /// When false, the editor drops its own "Rules" title so an enclosing `Section("Rules")` can
    /// supply the heading without duplicating it. Defaults to true so standalone uses keep their
    /// inline title.
    var showsTitleHeader: Bool = true

    var body: some View {
        let rules = suggestionSettings.customRules
        let existing = Set(rules.map { $0.lowercased() })

        TagListEditor(
            title: "Rules",
            showsTitleHeader: showsTitleHeader,
            items: rules,
            isAtCap: rules.count >= CustomRulesCatalog.maxRules,
            placeholder: "Add a rule, e.g. Use British spelling",
            atCapPlaceholder: "Rule limit reached",
            // Palette entries the user has not already added, compared case-insensitively.
            suggestions: CustomRulesCatalog.suggestedPalette
                .filter { !existing.contains($0.lowercased()) }
                .map { TagListEditor.Suggestion(value: $0, label: $0) },
            canReset: rules != CustomRulesCatalog.defaultRules,
            onAdd: { suggestionSettings.addRule($0) },
            onRemove: { suggestionSettings.removeRule($0) },
            onReset: { suggestionSettings.resetRules() }
        )
    }
}
