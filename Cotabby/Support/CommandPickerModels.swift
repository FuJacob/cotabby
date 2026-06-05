import CoreGraphics

/// File overview:
/// Shared value types for the generic inline-command row picker. The picker renders a list of
/// `CommandRow`s near the caret; row-based features (clipboard now, and emoji later) build their rows
/// from their own data. These types are free of AppKit so they stay easy to build and compare.

/// One row in the generic picker.
struct CommandRow: Identifiable, Equatable {
    /// What is shown at the leading edge of the row.
    enum Leading: Equatable {
        case glyph(String)    // a text or emoji glyph, rendered large
        case symbol(String)   // an SF Symbol name
        case none
    }

    let id: String
    let leading: Leading
    let title: String
    let subtitle: String?

    init(id: String, leading: Leading = .none, title: String, subtitle: String? = nil) {
        self.id = id
        self.leading = leading
        self.title = title
        self.subtitle = subtitle
    }
}

/// Direction for moving the highlighted row while the picker is open.
enum CommandSelectionMove: Equatable {
    case up
    case down
}

/// Sizing for a picker instance. Different features pick different row heights (clipboard rows carry
/// a subtitle, so they are taller than emoji rows). All rectangles end up in AppKit screen
/// coordinates via `EmojiPickerPanelLayout`.
struct CommandPickerMetrics {
    let width: CGFloat
    let rowHeight: CGFloat
    let headerHeight: CGFloat
    let maxVisibleRows: Int
    let emptyMessage: String

    /// The panel size for a given number of rows. An empty result still reserves one row so the panel
    /// never collapses to nothing.
    func contentSize(rowCount: Int) -> CGSize {
        let rows = rowCount == 0 ? 1 : min(rowCount, maxVisibleRows)
        let dividerHeight: CGFloat = 1
        let listVerticalPadding: CGFloat = rowCount == 0 ? 0 : 8
        let listHeight = CGFloat(rows) * rowHeight + listVerticalPadding
        return CGSize(width: width, height: headerHeight + dividerHeight + listHeight)
    }
}
