import CoreGraphics

/// File overview:
/// Pure geometry for the emoji picker panel: how big it is for a given match count and where it sits
/// relative to the caret. Keeping this separate from the AppKit panel controller makes the
/// flip-above and on-screen clamping rules unit testable without a window server.
///
/// All rectangles are in AppKit screen coordinates (bottom-left origin, y increases upward), the
/// same space `FocusedInputSnapshot.caretRect` already uses.
enum EmojiPickerMetrics {
    static let width: CGFloat = 300
    static let rowHeight: CGFloat = 30
    static let headerHeight: CGFloat = 26
    static let footerHeight: CGFloat = 28
    static let dividerHeight: CGFloat = 1
    static let listVerticalPadding: CGFloat = 8
    static let maxVisibleRows = 8

    /// The panel size for a given number of matches. An empty result still reserves one row for the
    /// "type to search" / "no emoji" hint so the panel never collapses to nothing.
    static func contentSize(matchCount: Int) -> CGSize {
        let rows = matchCount == 0 ? 1 : min(matchCount, maxVisibleRows)
        let listHeight = CGFloat(rows) * rowHeight + (matchCount == 0 ? 0 : listVerticalPadding)
        return CGSize(
            width: width,
            height: headerHeight + dividerHeight + listHeight + dividerHeight + footerHeight
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
