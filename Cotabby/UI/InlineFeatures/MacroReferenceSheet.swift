import SwiftUI

/// File overview:
/// Reference sheet that lists every inline `/macro` family with a short description and a few live
/// examples evaluated by the real `MacroEngine`. Surfaced from the Home pane so a user can discover
/// the breadth of the feature without reading source. Engine-driven examples ensure the sheet can
/// never drift from the actual behavior: an example that the engine declines to evaluate is dropped
/// rather than shown with a stale or invented result.
struct MacroReferenceSheet: View {
    let onDismiss: () -> Void

    private let groups: [MacroGroup] = MacroReferenceSheet.buildGroups()

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(groups) { group in
                        groupSection(group)
                    }

                    Text("Type `/` in any text field, then the macro. Press Tab to accept.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.top, 4)
                }
                .padding(20)
            }
        }
        .frame(width: 560, height: 540)
    }

    @ViewBuilder
    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Inline macros")
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Text("Every macro Cotabby can resolve from a `/` query.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Done", action: onDismiss)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    @ViewBuilder
    private func groupSection(_ group: MacroGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: group.systemImage)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Text(group.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            Text(group.summary)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(group.examples) { example in
                    exampleRow(example)
                }
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.regularMaterial)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.white.opacity(0.08), lineWidth: 0.5)
            )
        }
    }

    @ViewBuilder
    private func exampleRow(_ example: MacroExample) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("/\(example.input)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.primary)
                .frame(minWidth: 160, alignment: .leading)
            Text("→")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text(example.result)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    private struct MacroGroup: Identifiable {
        let id: String
        let title: String
        let summary: String
        let systemImage: String
        let examples: [MacroExample]
    }

    private struct MacroExample: Identifiable {
        let input: String
        let result: String
        var id: String { input }
    }

    /// Build the groups against the real engine so every shown result matches actual behavior. Engine
    /// returns `nil` for inputs it does not resolve, and those are filtered out automatically.
    private static func buildGroups() -> [MacroGroup] {
        let engine = MacroEngine.standard()
        func make(_ id: String, title: String, summary: String, systemImage: String, inputs: [String]) -> MacroGroup {
            let examples = inputs.compactMap { input -> MacroExample? in
                guard let result = engine.evaluate(input) else { return nil }
                return MacroExample(input: input, result: result.insertionText)
            }
            return MacroGroup(id: id, title: title, summary: summary, systemImage: systemImage, examples: examples)
        }
        return [
            make(
                "math",
                title: "Arithmetic",
                summary: "Safe arithmetic: + - * / ^, parentheses, decimals, and trailing % (percent). " +
                    "Accepting inserts only the result.",
                systemImage: "plus.forwardslash.minus",
                inputs: ["5+5=", "2^10=", "(3+4)*5=", "100*15%=", "12/4="]
            ),
            make(
                "units",
                title: "Unit conversion",
                summary: "Same-quantity conversions across length, mass, temperature, and volume. " +
                    "Fully offline via Foundation Measurement.",
                systemImage: "ruler",
                inputs: ["10km->mi", "100f->c", "5ft->m", "2lb->kg", "3cup->ml"]
            ),
            make(
                "currency",
                title: "Currency",
                summary: "Offline currency conversions using a bundled approximate rate table. " +
                    "Accepts ISO codes, symbols, and common names.",
                systemImage: "dollarsign.circle",
                inputs: ["100usd->eur", "50gbp->jpy", "100 dollars to yen", "$25 to cad"]
            ),
            make(
                "date",
                title: "Date and time",
                summary: "Locale-aware dates and times. Supports weekday navigation, relative offsets, " +
                    "and format hints like (iso), (long), (short), (24h).",
                systemImage: "calendar",
                inputs: ["today", "now", "tomorrow", "next-fri", "+3d", "+1week", "today(iso)", "now(24h)"]
            ),
            make(
                "random",
                title: "Random and generators",
                summary: "Random numbers, dice (`/d20`), coin flips, and UUIDs.",
                systemImage: "dice",
                inputs: ["random", "random(100)", "random(1,6)", "d20", "coin", "uuid"]
            )
        ]
    }
}
