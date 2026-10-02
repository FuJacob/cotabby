import CoreGraphics
import Foundation

/// One message as read from the screen: its text and where it sits, in global display points with a
/// top-left origin (ScreenCaptureKit / Accessibility space).
nonisolated struct MessageBlock: Equatable, Sendable {
    let text: String
    let frame: CGRect
}

/// Turns recognized text lines from a chat window into message blocks.
///
/// Pure geometry and text rules, so it is tested on recorded OCR output. It is conservative: when
/// in doubt it splits rather than merges, because a translation spanning two people's messages is
/// worse than two separate ones.
nonisolated enum MessageBlockGrouper {
    struct Line: Equatable, Sendable {
        let text: String
        let confidence: Float
        /// Vision's normalized box: unit square, bottom-left origin, relative to the captured image.
        let boundingBox: CGRect
    }

    /// Lines below this OCR confidence are usually icons, avatars, or reactions read as text.
    static let minimumConfidence: Float = 0.5

    /// - Parameters:
    ///   - windowFrame: the captured window, global points, top-left origin.
    ///   - composeFrame: the focused reply field, if any. Messages are read only above it and from
    ///     its left edge rightwards, which excludes the chat list and the reply being typed.
    static func blocks(from lines: [Line], windowFrame: CGRect, composeFrame: CGRect?) -> [MessageBlock] {
        let region = conversationRegion(windowFrame: windowFrame, composeFrame: composeFrame)
        let placed: [(text: String, frame: CGRect)] = lines.compactMap { line in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.confidence >= minimumConfidence, !isChrome(text) else { return nil }
            let frame = globalFrame(of: line.boundingBox, in: windowFrame)
            guard region.contains(CGPoint(x: frame.midX, y: frame.midY)) else { return nil }
            return (text, frame)
        }
        .sorted { $0.frame.minY == $1.frame.minY ? $0.frame.minX < $1.frame.minX : $0.frame.minY < $1.frame.minY }

        var blocks: [(texts: [String], frame: CGRect, lineHeight: CGFloat)] = []
        for line in placed {
            if let last = blocks.last, continues(last.frame, lineHeight: last.lineHeight, with: line.frame) {
                blocks[blocks.count - 1].texts.append(line.text)
                blocks[blocks.count - 1].frame = last.frame.union(line.frame)
            } else {
                blocks.append(([line.text], line.frame, line.frame.height))
            }
        }
        return blocks.map { MessageBlock(text: $0.texts.joined(separator: " "), frame: $0.frame) }
    }

    /// Maps a Vision box into global points (top-left origin) for a capture of `windowFrame`.
    static func globalFrame(of box: CGRect, in windowFrame: CGRect) -> CGRect {
        CGRect(
            x: windowFrame.minX + box.minX * windowFrame.width,
            y: windowFrame.minY + (1 - box.maxY) * windowFrame.height,
            width: box.width * windowFrame.width,
            height: box.height * windowFrame.height
        )
    }

    // MARK: - Rules

    /// The part of the window that holds the conversation. With a reply field, that is everything
    /// above it from its left edge (minus a small margin) to the window's right edge; without one,
    /// the window below its title bar.
    private static func conversationRegion(windowFrame: CGRect, composeFrame: CGRect?) -> CGRect {
        let titleBar: CGFloat = 52
        guard let composeFrame, windowFrame.intersects(composeFrame) else {
            return CGRect(x: windowFrame.minX, y: windowFrame.minY + titleBar,
                          width: windowFrame.width, height: max(0, windowFrame.height - titleBar))
        }
        let left = max(windowFrame.minX, composeFrame.minX - 24)
        let top = windowFrame.minY + titleBar
        return CGRect(x: left, y: top, width: windowFrame.maxX - left, height: max(0, composeFrame.minY - top))
    }

    /// The next line belongs to the same message when it starts right below (within 0.8 line
    /// heights) and lines up with the block's left edge or overlaps it horizontally.
    private static func continues(_ block: CGRect, lineHeight: CGFloat, with line: CGRect) -> Bool {
        let gap = line.minY - block.maxY
        guard gap >= -lineHeight * 0.3, gap <= lineHeight * 0.8 else { return false }
        let alignedLeft = abs(line.minX - block.minX) <= lineHeight * 1.5
        let overlaps = line.minX < block.maxX && line.maxX > block.minX
        return alignedLeft || overlaps
    }

    /// Timestamps, read receipts, and other non-message text chat apps draw.
    private static func isChrome(_ text: String) -> Bool {
        guard text.count >= 2 else { return true }
        let letters = text.filter(\.isLetter).count
        if letters == 0 { return true }
        let time = #"^\d{1,2}[:.]\d{2}(\s?[AaPp][Mm])?$"#
        if text.range(of: time, options: .regularExpression) != nil { return true }
        return false
    }
}
