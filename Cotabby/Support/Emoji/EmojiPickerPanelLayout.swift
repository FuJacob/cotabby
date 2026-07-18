import CoreGraphics

/// File overview:
/// Pure geometry for the emoji picker panel: how big it is for a given match count and where it sits
/// relative to the caret. Keeping this separate from the AppKit panel controller makes the
/// flip-above and on-screen clamping rules unit testable without a window server.
///
/// All rectangles are in AppKit screen coordinates (bottom-left origin, y increases upward), the
/// same space `FocusedInputSnapshot.caretRect` already uses.
/// Pure geometry for the two-row emoji picker: a typed-query row above a horizontal ribbon of
/// ranked glyphs. The window width hugs the ribbon's cells up to `maxVisibleCells` (then the ribbon
/// scrolls), so the panel stays compact for a narrow result set instead of reserving a fixed slab.
enum EmojiPickerMetrics {
    /// Square cell that holds one glyph and its selection chip.
    static let cellSize: CGFloat = 30
    /// Gap between adjacent ribbon cells.
    static let cellSpacing: CGFloat = 2
    /// Leading/trailing inset shared by the query row and the ribbon.
    static let horizontalInset: CGFloat = 8
    /// Height of the typed-query row sitting above the ribbon.
    static let queryRowHeight: CGFloat = 22
    /// Height of the glyph ribbon row (the cell plus a little vertical breathing room).
    static let ribbonRowHeight: CGFloat = 40
    /// How many cells are shown before the ribbon scrolls horizontally.
    static let maxVisibleCells = 8
    /// Floor so a one- or two-match ribbon (or the bare-":" empty state) never collapses to a sliver.
    static let minWidth: CGFloat = 132

    /// The panel size for a given number of matches. An empty result still reserves the ribbon row
    /// so the panel never collapses to nothing when the query is empty or matches nothing.
    static func contentSize(matchCount: Int) -> CGSize {
        let cells = matchCount == 0 ? 0 : min(matchCount, maxVisibleCells)
        let ribbonWidth = cells == 0
            ? minWidth
            : CGFloat(cells) * cellSize + CGFloat(cells - 1) * cellSpacing + horizontalInset * 2
        return CGSize(
            width: max(minWidth, ribbonWidth),
            height: queryRowHeight + ribbonRowHeight
        )
    }
}

enum EmojiPickerPanelLayout {
    /// Vertical gap between the caret and the panel edge.
    static let caretGap: CGFloat = 6

    /// Positions the panel below the caret when it fits, flips it above when the caret is near the
    /// bottom of the screen, and clamps to the visible frame on every edge so the panel is never
    /// pushed off-screen on a small or secondary display.
    static func frame(caretRect: CGRect, contentSize: CGSize, visibleFrame: CGRect) -> CGRect {
        var originX = caretRect.minX
        if originX + contentSize.width > visibleFrame.maxX {
            originX = visibleFrame.maxX - contentSize.width
        }
        originX = max(originX, visibleFrame.minX)

        // "Below" the caret means smaller y in bottom-left coordinates: the panel hangs under the
        // caret's bottom edge.
        let belowOriginY = caretRect.minY - caretGap - contentSize.height
        let aboveOriginY = caretRect.maxY + caretGap

        let originY: CGFloat
        if belowOriginY >= visibleFrame.minY {
            originY = belowOriginY
        } else if aboveOriginY + contentSize.height <= visibleFrame.maxY {
            originY = aboveOriginY
        } else {
            // Neither placement fits fully (tiny screen). Keep it on-screen, preferring the bottom.
            originY = max(visibleFrame.minY, min(belowOriginY, visibleFrame.maxY - contentSize.height))
        }

        return CGRect(x: originX, y: originY, width: contentSize.width, height: contentSize.height)
    }
}
