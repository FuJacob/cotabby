import SwiftUI

/// A list of short strings edited as removable chips, with a free-text field and a palette of
/// suggestions to tap. `CustomRulesEditor` and `LanguageTagsEditor` are thin wrappers that supply
/// the catalog and the settings-model calls, so both editors type, commit and reset the same way.
///
/// The editor only gathers input. Trimming, de-duplication and the cap are applied by the model
/// setters the callbacks route to, which is why `onAdd` receives the raw typed text.
struct TagListEditor: View {
    /// A palette entry: `value` is what gets stored, `label` what the chip shows.
    struct Suggestion: Identifiable {
        let value: String
        let label: String

        var id: String { value }
    }

    let title: String
    /// When false the editor drops its own title so an enclosing `Section` can supply the heading.
    let showsTitleHeader: Bool
    let items: [String]
    let isAtCap: Bool
    let placeholder: String
    let atCapPlaceholder: String
    /// Entries not yet in `items`; the editor hides the palette when this is empty or at the cap.
    let suggestions: [Suggestion]
    var footnote: String?
    /// Whether the list differs from its default, so Reset has something to do.
    let canReset: Bool
    let onAdd: (String) -> Void
    let onRemove: (String) -> Void
    let onReset: () -> Void

    @State private var inputText: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if showsTitleHeader {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
            }

            if !items.isEmpty {
                TagFlowLayout(spacing: 10) {
                    ForEach(items, id: \.self) { item in
                        RemovableTagChip(text: item) {
                            onRemove(item)
                        }
                    }
                }
            }

            TextField(isAtCap ? atCapPlaceholder : placeholder, text: $inputText)
                .textFieldStyle(.roundedBorder)
                .disabled(isAtCap)
                .onSubmit(commit)
                .onChange(of: inputText) { _, newValue in
                    // A trailing comma commits, matching common tag-entry behavior.
                    if newValue.hasSuffix(",") {
                        commit()
                    }
                }

            if !suggestions.isEmpty, !isAtCap {
                Text("Suggestions")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.tertiary)

                TagFlowLayout(spacing: 10) {
                    ForEach(suggestions) { suggestion in
                        AddableTagChip(text: suggestion.label) {
                            onAdd(suggestion.value)
                        }
                    }
                }
            }

            if let footnote {
                Text(footnote)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if canReset {
                HStack {
                    Spacer()
                    Button(action: onReset) {
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
        onAdd(trimmed)
    }
}
