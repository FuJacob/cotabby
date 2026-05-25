import SwiftUI

/// File overview:
/// Editor for the user's custom autocomplete rules. Rules are short imperative style directives
/// (e.g. "Use British spelling") shown as removable chips, added freeform or by tapping a suggested
/// chip. "Clear" removes every rule (rules are opt-in, so the baseline is empty).
///
/// This is intentionally independent of `TagsInputView`: it needs suggested-chip behavior, a cap,
/// and a clear affordance that the generic tags input does not provide.
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
                Spacer()
                if canClear {
                    Button("Clear") {
                        suggestionSettings.clearRules()
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                }
            }

            Text("Short style instructions for your completions. Stored only on your Mac.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !rules.isEmpty {
                RulesFlowLayout(spacing: 10) {
                    ForEach(rules, id: \.self) { rule in
                        RuleChip(text: rule) {
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

                RulesFlowLayout(spacing: 10) {
                    ForEach(availableSuggestions, id: \.self) { suggestion in
                        SuggestionChip(text: suggestion) {
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

/// A current rule, removable via its trailing ✕.
private struct RuleChip: View {
    let text: String
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(text)
                .font(.system(size: 12, weight: .medium))
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(isHovering ? 1.0 : 0.6)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.tertiary.opacity(0.3))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.secondary.opacity(0.2), lineWidth: 1)
        )
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) { isHovering = hovering }
        }
    }
}

/// A tappable suggestion that adds itself as a rule.
private struct SuggestionChip: View {
    let text: String
    let onAdd: () -> Void

    var body: some View {
        Button(action: onAdd) {
            HStack(spacing: 4) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                Text(text)
                    .font(.system(size: 12))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1, dash: [3]))
            )
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
    }
}

/// Minimal wrapping layout for chips. Local to this file so the editor stays self-contained.
private struct RulesFlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        FlowResult(in: proposal.width ?? 0, subviews: subviews, spacing: spacing).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(in: bounds.width, subviews: subviews, spacing: spacing)
        for (index, subview) in subviews.enumerated() {
            let point = result.frames[index].origin
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y), proposal: .unspecified)
        }
    }

    private struct FlowResult {
        var size: CGSize = .zero
        var frames: [CGRect] = []

        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var currentX: CGFloat = 0
            var currentY: CGFloat = 0
            var lineHeight: CGFloat = 0

            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                if currentX + size.width > maxWidth, currentX > 0 {
                    currentX = 0
                    currentY += lineHeight + spacing
                    lineHeight = 0
                }
                frames.append(CGRect(x: currentX, y: currentY, width: size.width, height: size.height))
                lineHeight = max(lineHeight, size.height)
                currentX += size.width + spacing
            }
            self.size = CGSize(width: maxWidth, height: currentY + lineHeight)
        }
    }
}
