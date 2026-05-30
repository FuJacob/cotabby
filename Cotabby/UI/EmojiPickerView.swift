import Combine
import SwiftUI

/// File overview:
/// The SwiftUI content hosted inside the floating emoji picker panel. It is a pure renderer of
/// `EmojiPickerViewModel`: the trigger state machine and controller own all behavior, while this view
/// only reflects the current query, matches, and highlighted row. Keyboard navigation arrives through
/// the global event tap (not the panel, which never becomes key), so this view does not handle key
/// input. Mouse clicks on a row report the index back through `onSelect`.

/// Observable state the controller pushes into the panel. Kept tiny so selection moves re-render only
/// the row highlight and scroll position, not the whole list.
@MainActor
final class EmojiPickerViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var matches: [EmojiMatch] = []
    @Published var selectedIndex: Int = 0
}

struct EmojiPickerView: View {
    @ObservedObject var model: EmojiPickerViewModel
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
        }
        .frame(width: EmojiPickerMetrics.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.1), lineWidth: 0.5)
        )
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text(":")
                .foregroundStyle(.secondary)
            Text(model.query)
                .foregroundStyle(.primary)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .lineLimit(1)
        .padding(.horizontal, 10)
        .frame(height: EmojiPickerMetrics.headerHeight)
    }

    @ViewBuilder
    private var content: some View {
        if model.matches.isEmpty {
            Text(model.query.isEmpty ? "Type to search emoji" : "No emoji found")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: EmojiPickerMetrics.rowHeight)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.matches.indices, id: \.self) { index in
                            EmojiPickerRow(
                                match: model.matches[index],
                                isSelected: index == model.selectedIndex
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

private struct EmojiPickerRow: View {
    let match: EmojiMatch
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(match.glyph)
                .font(.system(size: 18))
            Text(":\(match.primaryAlias):")
                .font(.system(size: 13))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: EmojiPickerMetrics.rowHeight)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isSelected ? Color.accentColor : Color.clear)
        )
        .padding(.horizontal, 4)
    }
}
