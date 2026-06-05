import Combine
import SwiftUI

/// File overview:
/// The generic SwiftUI content hosted inside an inline-command row picker panel. It is a pure
/// renderer of `CommandPickerViewModel`: the controller owns all behavior and pushes rows, the
/// highlighted index, and the accept-key hint. Keyboard navigation arrives through the global event
/// tap (not the panel, which never becomes key), so this view does not handle key input. Clicks
/// report the row index back through `onSelect`.

@MainActor
final class CommandPickerViewModel: ObservableObject {
    @Published var headerText: String = ""
    @Published var rows: [CommandRow] = []
    @Published var selectedIndex: Int = 0
    @Published var acceptKeyLabel: String?
    @Published var emptyMessage: String = "No results"
    @Published var width: CGFloat = 320
    @Published var rowHeight: CGFloat = 30
    @Published var headerHeight: CGFloat = 26
}

struct CommandPickerView: View {
    @ObservedObject var model: CommandPickerViewModel
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: model.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text(model.headerText)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: model.headerHeight)
    }

    @ViewBuilder
    private var content: some View {
        if model.rows.isEmpty {
            Text(model.emptyMessage)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: model.rowHeight)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.rows.indices, id: \.self) { index in
                            CommandPickerRow(
                                row: model.rows[index],
                                rowHeight: model.rowHeight,
                                isSelected: index == model.selectedIndex,
                                acceptKeyLabel: index == model.selectedIndex ? model.acceptKeyLabel : nil
                            )
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture { onSelect(index) }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: model.selectedIndex) { _, newValue in
                    proxy.scrollTo(newValue, anchor: .center)
                }
            }
        }
    }
}

private struct CommandPickerRow: View {
    let row: CommandRow
    let rowHeight: CGFloat
    let isSelected: Bool
    let acceptKeyLabel: String?

    var body: some View {
        HStack(spacing: 8) {
            leading
            VStack(alignment: .leading, spacing: 1) {
                Text(row.title)
                    .font(.system(size: 13))
                    .foregroundStyle(isSelected ? Color.white : Color.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle = row.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            Spacer(minLength: 0)
            if let acceptKeyLabel {
                CommandPickerKeycap(label: acceptKeyLabel, onAccent: isSelected)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var leading: some View {
        switch row.leading {
        case let .glyph(glyph):
            Text(glyph).font(.system(size: 18))
        case let .symbol(name):
            Image(systemName: name)
                .font(.system(size: 14))
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .frame(width: 18)
        case .none:
            EmptyView()
        }
    }
}

/// Small keycap pill on the highlighted row, mirroring the user's configured word-accept shortcut.
private struct CommandPickerKeycap: View {
    let label: String
    let onAccent: Bool

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundStyle(onAccent ? Color.white : Color.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(onAccent ? Color.white.opacity(0.22) : Color.primary.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(onAccent ? Color.white.opacity(0.35) : Color.primary.opacity(0.15), lineWidth: 1)
            )
            .fixedSize()
    }
}
