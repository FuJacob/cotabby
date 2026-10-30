import CoreGraphics
import Foundation

/// File overview:
/// The focused field's own rectangle inside one captured screenshot, and the two rules that keep
/// that rectangle out of screen context: OCR lines inside it are dropped, and its pixels do not
/// count as a change when deciding whether a recapture can reuse the previous OCR.
///
/// Why the field is excluded: its text already reaches the prompt through Accessibility as the
/// caret prefix, exactly and without OCR's lag or misreadings. Re-reading it from pixels only adds a
/// noisy duplicate, and because it changes with every keystroke it made each periodic refresh
/// produce a different excerpt. `SuggestionCoordinator` treats a changed excerpt as navigation (it
/// retires the suggestion, and the new prompt head forces a full llama re-prefill), so typing in a
/// chat composer used to reset completions every three seconds. With the field excluded, a refresh
/// whose only change is the user's typing reuses the cached OCR and yields a byte-identical excerpt,
/// while any change outside the field (another conversation, a new message) still changes it.
///
/// `WindowScreenshotService` builds this value from the snapshot's unwidened `elementFrameRect` (the
/// widened `inputFrameRect` can cover a neighbouring label or button); `ScreenshotContextGenerator`
/// applies it. The value lives for one capture and holds only geometry, never pixels or text.
///
/// Known limit: a host that reports a scrolled text view's whole content frame (AppKit text views
/// do) makes the region cover whatever the overflow overlaps on screen, for example the messages
/// just above a long draft in a composer that scrolls internally. Those lines are then left out of
/// the excerpt until the draft shrinks.
nonisolated struct FocusedFieldScreenRegion: Equatable, Sendable {
    /// A rectangle of image pixels in memory order (row 0 is the top row), half-open on both axes.
    struct PixelRect: Equatable, Sendable {
        let rows: Range<Int>
        let columns: Range<Int>
    }

    /// The field in Vision's space: the unit square of the captured image, origin bottom-left,
    /// already clipped to the image. The same space as `OCRTextHygiene.OCRLine.boundingBox`.
    let bounds: CGRect

    /// Places a field frame inside the captured rectangle. Both rectangles are global display points
    /// in Core Graphics orientation (origin top-left, y grows downward), the space ScreenCaptureKit
    /// crops in. Returns nil when the field does not overlap the capture, for example when the
    /// endpoint profile captures only the band above the field.
    init?(fieldFrame: CGRect, captureRect: CGRect) {
        guard captureRect.width > 0, captureRect.height > 0,
              !fieldFrame.isNull, !fieldFrame.isInfinite, fieldFrame.width > 0, fieldFrame.height > 0 else {
            return nil
        }
        // Vision measures y up from the bottom edge, so the field's bottom edge (its largest Core
        // Graphics y) becomes its normalized minimum.
        let normalized = CGRect(
            x: (fieldFrame.minX - captureRect.minX) / captureRect.width,
            y: (captureRect.maxY - fieldFrame.maxY) / captureRect.height,
            width: fieldFrame.width / captureRect.width,
            height: fieldFrame.height / captureRect.height
        )
        self.init(bounds: normalized)
    }

    /// Wraps bounds that are already in Vision's normalized space, clipping them to the image.
    init?(bounds: CGRect) {
        let clipped = bounds.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else {
            return nil
        }
        self.bounds = clipped
    }

    /// A line belongs to the field when the center of its box is inside the field. The center rather
    /// than full containment tolerates Vision merging the typed text with an adjacent glyph such as
    /// a composer's "+" button; a line without geometry (text-only fixtures) is never claimed.
    func contains(_ line: OCRTextHygiene.OCRLine) -> Bool {
        guard let box = line.boundingBox else {
            return false
        }
        return bounds.contains(CGPoint(x: box.midX, y: box.midY))
    }

    /// The lines outside the field, in their original reading order.
    func excluding(_ lines: [OCRTextHygiene.OCRLine]) -> [OCRTextHygiene.OCRLine] {
        lines.filter { !contains($0) }
    }

    /// The field in the pixel grid of an image of the given size, rounded outward so a fractional
    /// edge never leaves a sliver of the field (and its caret) counted as a change. Image memory
    /// stores the top row first, the opposite of Vision's bottom-left origin, hence the flip.
    func pixelRect(width: Int, height: Int) -> PixelRect {
        let imageWidth = CGFloat(max(width, 0))
        let imageHeight = CGFloat(max(height, 0))
        func clamped(_ value: CGFloat, to limit: Int) -> Int {
            min(max(Int(value), 0), max(limit, 0))
        }
        let firstColumn = clamped((bounds.minX * imageWidth).rounded(.down), to: width)
        let endColumn = clamped((bounds.maxX * imageWidth).rounded(.up), to: width)
        let firstRow = clamped(((1 - bounds.maxY) * imageHeight).rounded(.down), to: height)
        let endRow = clamped(((1 - bounds.minY) * imageHeight).rounded(.up), to: height)
        return PixelRect(
            rows: firstRow..<max(firstRow, endRow),
            columns: firstColumn..<max(firstColumn, endColumn)
        )
    }
}
