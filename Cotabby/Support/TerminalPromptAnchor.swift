import CoreGraphics
import Foundation

/// Cached relationship between a shell command buffer and its rendered terminal row.
///
/// OCR establishes the row once; subsequent shell-hook updates move the caret arithmetically from
/// the exact cursor offset. This keeps OCR out of the per-keystroke hot path while refusing to draw
/// when the prompt cannot be matched confidently.
nonisolated struct TerminalPromptAnchor: Equatable, Sendable {
    let sessionIdentity: TerminalSessionIdentity
    let windowFrame: CGRect
    let captureRegion: CGRect
    let promptLineRect: CGRect
    let cellWidth: CGFloat
    let cellHeight: CGFloat
    let bufferStartX: CGFloat
    let columnCount: Int
    let wasEmptyBuffer: Bool
    let capturedAt: Date
}

nonisolated enum TerminalPromptAnchorResolver {
    static let maximumAge: TimeInterval = 20
    private static let cellWidthRange: ClosedRange<CGFloat> = 4...18
    private static let promptTerminators: Set<Character> = [">", "%", "$", "#"]

    static func makeAnchor(
        snapshot: TerminalFocusSnapshot,
        lines: [RecognizedTextLine],
        captureRegion: CGRect,
        windowFrame: CGRect,
        now: Date = Date()
    ) -> TerminalPromptAnchor? {
        guard let match = match(buffer: snapshot.commandBuffer, in: lines) else { return nil }
        let line = lines[match.lineIndex]
        let lineCharacterCount = max(line.text.count, 1)
        let lineRect = CGRect(
            x: captureRegion.minX + line.boundingBox.minX * captureRegion.width,
            y: captureRegion.minY + (1 - line.boundingBox.maxY) * captureRegion.height,
            width: line.boundingBox.width * captureRegion.width,
            height: max(line.boundingBox.height * captureRegion.height, 12)
        )
        let cellWidth = lineRect.width / CGFloat(lineCharacterCount)
        guard cellWidthRange.contains(cellWidth) else { return nil }

        let startX = match.rawBufferStart.map {
            lineRect.minX + CGFloat($0) * cellWidth
        } ?? (lineRect.maxX + cellWidth)
        return TerminalPromptAnchor(
            sessionIdentity: snapshot.sessionIdentity,
            windowFrame: windowFrame,
            captureRegion: captureRegion,
            promptLineRect: lineRect,
            cellWidth: cellWidth,
            cellHeight: lineRect.height,
            bufferStartX: startX,
            columnCount: max(Int(captureRegion.width / cellWidth), 20),
            wasEmptyBuffer: snapshot.commandBuffer.trimmingCharacters(in: .whitespaces).isEmpty,
            capturedAt: now
        )
    }

    static func geometry(
        cursorOffset: Int,
        anchor: TerminalPromptAnchor
    ) -> (caret: CGRect, input: CGRect) {
        let startColumn = max(
            Int(((anchor.bufferStartX - anchor.captureRegion.minX) / anchor.cellWidth).rounded()),
            0
        )
        let linearColumn = startColumn + max(cursorOffset, 0)
        let row = linearColumn / anchor.columnCount
        let column = linearColumn % anchor.columnCount
        let caret = CGRect(
            x: anchor.captureRegion.minX + CGFloat(column) * anchor.cellWidth,
            y: anchor.promptLineRect.minY + CGFloat(row) * anchor.cellHeight,
            width: anchor.cellWidth,
            height: anchor.cellHeight
        )
        let input = CGRect(
            x: anchor.captureRegion.minX,
            y: caret.minY,
            width: anchor.captureRegion.width,
            height: anchor.cellHeight
        )
        return (caret, input)
    }

    static func isValid(
        _ anchor: TerminalPromptAnchor,
        windowFrame: CGRect?,
        cursorOffset: Int,
        now: Date = Date()
    ) -> Bool {
        guard now.timeIntervalSince(anchor.capturedAt) <= maximumAge else { return false }
        if let windowFrame {
            guard abs(windowFrame.minX - anchor.windowFrame.minX) <= 1,
                  abs(windowFrame.minY - anchor.windowFrame.minY) <= 1,
                  abs(windowFrame.width - anchor.windowFrame.width) <= 1,
                  abs(windowFrame.height - anchor.windowFrame.height) <= 1 else { return false }
        }
        let caret = geometry(cursorOffset: cursorOffset, anchor: anchor).caret
        return anchor.windowFrame.insetBy(dx: -2, dy: -2).contains(
            CGPoint(x: caret.midX, y: caret.midY)
        )
    }

    private struct Match {
        let lineIndex: Int
        let rawBufferStart: Int?
    }

    private struct CandidateMatch {
        let lineIndex: Int
        let rawBufferStart: Int
        let minimumY: CGFloat
    }

    private static func match(buffer: String, in lines: [RecognizedTextLine]) -> Match? {
        guard !lines.isEmpty else { return nil }
        let trimmed = buffer.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            let candidates = lines.enumerated().filter {
                guard let last = folded($0.element.text).last else { return false }
                return promptTerminators.contains(last)
            }
            let pool = candidates.isEmpty ? Array(lines.enumerated()) : candidates
            return pool.min(by: { $0.element.boundingBox.minY < $1.element.boundingBox.minY })
                .map { Match(lineIndex: $0.offset, rawBufferStart: nil) }
        }

        let needleLengths = [min(trimmed.count, 24), min(trimmed.count, 10)]
        for length in needleLengths where length > 0 {
            let needle = String(trimmed.prefix(length))
            let matches = lines.enumerated().compactMap { index, line -> CandidateMatch? in
                guard let range = line.text.range(of: needle) else { return nil }
                let rawStart = line.text.distance(from: line.text.startIndex, to: range.lowerBound)
                return CandidateMatch(
                    lineIndex: index,
                    rawBufferStart: rawStart,
                    minimumY: line.boundingBox.minY
                )
            }
            if let bottomMost = matches.min(by: { $0.minimumY < $1.minimumY }) {
                return Match(
                    lineIndex: bottomMost.lineIndex,
                    rawBufferStart: bottomMost.rawBufferStart
                )
            }
        }
        return nil
    }

    private static func folded(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespaces).map { character in
            switch character {
            case "❯", "›", "»", "➜": ">"
            default: character
            }
        }.reduce(into: "") { $0.append($1) }
    }
}
