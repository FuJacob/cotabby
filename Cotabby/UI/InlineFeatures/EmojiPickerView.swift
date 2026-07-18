import Combine
import SwiftUI

/// File overview:
/// The SwiftUI content hosted inside the floating emoji picker panel. It is a pure renderer of
/// `EmojiPickerViewModel`: the trigger state machine and controller own all behavior, while this view
/// only reflects the current query, matches, and selected glyph. Keyboard navigation arrives through
/// the global event tap (not the panel, which never becomes key), so this view does not handle key
/// input. Mouse clicks on a cell report the index back through `onSelect`.

/// Observable state the controller pushes into the panel. Kept tiny so selection moves re-render only
/// the highlighted cell and scroll position, not the whole ribbon.
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
            queryRow
            ribbon
        }
        .frame(width: EmojiPickerMetrics.contentSize(matchCount: model.matches.count).width)
        .popupHUDChrome()
    }

    /// Row 1: the live ":query" the user is typing. Echoing it titles the ribbon and confirms which
    /// query produced these glyphs, since the ribbon itself shows no per-glyph names.
    private var queryRow: some View {
        HStack(spacing: 1) {
            Text(":").foregroundStyle(PopupTheme.secondaryText)
            Text(model.query).foregroundStyle(PopupTheme.primaryText)
            Spacer(minLength: 0)
        }
        .font(.system(size: 12, weight: .medium, design: .monospaced))
        .lineLimit(1)
        .padding(.horizontal, EmojiPickerMetrics.horizontalInset)
        .frame(height: EmojiPickerMetrics.queryRowHeight)
    }

    /// Row 2: ranked glyphs left-to-right, the selection moved by the arrow keys. Scrolls horizontally
    /// once the match count passes `maxVisibleCells`, keeping the selected cell centered in view.
    @ViewBuilder
    private var ribbon: some View {
        if model.matches.isEmpty {
            emptyRibbon
        } else {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: EmojiPickerMetrics.cellSpacing) {
                        ForEach(model.matches.indices, id: \.self) { index in
                            EmojiRibbonCell(
                                glyph: model.matches[index].glyph,
                                isSelected: index == model.selectedIndex
                            )
                            .id(index)
                            .contentShape(Rectangle())
                            .onTapGesture { onSelect(index) }
                        }
                    }
                    .padding(.horizontal, EmojiPickerMetrics.horizontalInset)
                }
                .frame(height: EmojiPickerMetrics.ribbonRowHeight)
                .onChange(of: model.selectedIndex) { _, newValue in
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
    }

    /// Empty state. A bare ":" with no recents reserves the ribbon row so the panel keeps its shape; a
    /// typed query that matches nothing says so rather than showing a blank strip.
    @ViewBuilder
    private var emptyRibbon: some View {
        if model.query.isEmpty {
            Color.clear.frame(height: EmojiPickerMetrics.ribbonRowHeight)
        } else {
            Text("No emoji")
                .font(.system(size: 12))
                .foregroundStyle(PopupTheme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, EmojiPickerMetrics.horizontalInset)
                .frame(height: EmojiPickerMetrics.ribbonRowHeight)
        }
    }
}

/// One ribbon glyph. The selected cell gets a soft white chip (the calm Spotlight-style highlight);
/// the rest are bare so the row reads as a clean line of emoji.
private struct EmojiRibbonCell: View {
    let glyph: String
    let isSelected: Bool

    var body: some View {
        Text(glyph)
            .font(.system(size: 20))
            .frame(width: EmojiPickerMetrics.cellSize, height: EmojiPickerMetrics.cellSize)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? PopupTheme.selectionFill : Color.clear)
            )
    }
}
