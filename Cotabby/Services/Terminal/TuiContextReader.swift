import CoreGraphics
import Foundation

/// Reduces one terminal-window OCR result to Claude Code's editable prompt.
///
/// This type is intentionally independent of ScreenCaptureKit and app focus. It owns only the
/// pixel-to-text interpretation, which makes the risky heuristic testable with fixed OCR fixtures.
struct TuiContextReader {
    struct PromptReading: Equatable, Sendable {
        let promptText: String
        let estimatedCursorOffset: Int
        let promptLineBox: CGRect?
        let recognizedLineCount: Int
        let latencyMilliseconds: Int
        let looksLikeClaudeCode: Bool
    }

    enum ReadError: LocalizedError {
        case failed(String)

        var errorDescription: String? {
            switch self {
            case let .failed(message): "Claude Code OCR failed: \(message)"
            }
        }
    }

    private static let promptGlyphs = ["❯", "›", ">", ")"]
    /// These are stable screen chrome, not user content. Requiring one makes process-wide
    /// detection safe when Claude runs in another tab of the same terminal application.
    private static let screenMarkers = [
        "Claude Code",
        "context left",
        "esc to interrupt",
        "bypass permissions",
        "shift+tab"
    ]

    private let extractor: any ScreenTextExtracting

    init(extractor: any ScreenTextExtracting = ScreenTextExtractor()) {
        self.extractor = extractor
    }

    func read(image: CGImage) async throws -> PromptReading {
        let startedAt = Date()
        let extracted: ExtractedScreenText
        do {
            extracted = try await extractor.extractText(from: image)
        } catch ScreenTextExtractionError.noRecognizedText {
            return PromptReading(
                promptText: "",
                estimatedCursorOffset: 0,
                promptLineBox: nil,
                recognizedLineCount: 0,
                latencyMilliseconds: elapsed(since: startedAt),
                looksLikeClaudeCode: false
            )
        } catch {
            throw ReadError.failed(error.localizedDescription)
        }

        let prompt = promptLine(in: extracted)
        return PromptReading(
            promptText: prompt.text,
            estimatedCursorOffset: prompt.text.count,
            promptLineBox: prompt.box,
            recognizedLineCount: extracted.lineCount,
            latencyMilliseconds: elapsed(since: startedAt),
            looksLikeClaudeCode: Self.screenMarkers.contains {
                extracted.text.localizedCaseInsensitiveContains($0)
            }
        )
    }

    private func promptLine(in extraction: ExtractedScreenText) -> (text: String, box: CGRect?) {
        let glyphLines = extraction.positionedLines.compactMap { line -> RecognizedTextLine? in
            Self.promptGlyphs.contains(where: { line.text.hasPrefix($0) }) ? line : nil
        }
        if let line = glyphLines.min(by: { $0.boundingBox.minY < $1.boundingBox.minY }) {
            let glyph = Self.promptGlyphs.first(where: { line.text.hasPrefix($0) }) ?? ""
            return (
                String(line.text.dropFirst(glyph.count)).trimmingCharacters(in: .whitespaces),
                line.boundingBox
            )
        }

        // Geometry-free test fakes retain a safe fallback. Production OCR always provides boxes.
        let textLines = extraction.text.split(separator: "\n").map {
            String($0).trimmingCharacters(in: .whitespaces)
        }
        for line in textLines.reversed() {
            if let glyph = Self.promptGlyphs.first(where: { line.hasPrefix($0) }) {
                return (String(line.dropFirst(glyph.count)).trimmingCharacters(in: .whitespaces), nil)
            }
        }
        return ("", nil)
    }

    private func elapsed(since start: Date) -> Int {
        Int(Date().timeIntervalSince(start) * 1_000)
    }
}
