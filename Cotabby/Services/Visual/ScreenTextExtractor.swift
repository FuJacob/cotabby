import CoreGraphics
import Foundation
import Logging
@preconcurrency import Vision

/// File overview:
/// Runs OCR over a captured window screenshot and returns a reading-order text excerpt.
/// This is the bridge between raw image capture and the existing text-only local LLM runtime.
///
/// We deliberately downsample very large screenshots before OCR. The goal is not archival fidelity;
/// it is bounded semantic extraction for autocomplete context. This pass favors useful text
/// recovery over minimum latency because the output is captured once per focused field.

struct ExtractedScreenText: Sendable {
    let text: String
    let lineCount: Int
    /// Per-line OCR text paired with Vision's recognition confidence, in reading order. Carries the
    /// confidence that the joined `text` discards, so `OCRTextHygiene.dropLowConfidence` can filter on
    /// real values instead of a synthesized constant. Defaults to empty for callers (and tests) that
    /// only supply joined text.
    let lines: [OCRTextHygiene.OCRLine]

    init(text: String, lineCount: Int, lines: [OCRTextHygiene.OCRLine] = []) {
        self.text = text
        self.lineCount = lineCount
        self.lines = lines
    }
}

/// Test seam for screenshot OCR.
///
/// `ScreenshotContextGenerator` owns orchestration, while this protocol lets tests inject
/// deterministic OCR without depending on Vision, Screen Recording permission, or real pixels.
protocol ScreenTextExtracting {
    func extractText(from image: CGImage) async throws -> ExtractedScreenText
}

enum ScreenTextExtractionError: LocalizedError {
    case noRecognizedText
    case ocrFailed(String)

    var errorDescription: String? {
        switch self {
        case .noRecognizedText:
            return "No usable visible text was recognized in the screenshot."
        case let .ocrFailed(message):
            return "Screenshot OCR failed: \(message)"
        }
    }
}

struct ScreenTextExtractor: ScreenTextExtracting {
    let maxImageDimension: Int
    let maxRecognizedCharacters: Int

    init(
        maxImageDimension: Int = VisualContextConfiguration.default.maxImageDimension,
        maxRecognizedCharacters: Int = VisualContextConfiguration.default.maxRecognizedCharacters
    ) {
        self.maxImageDimension = maxImageDimension
        self.maxRecognizedCharacters = maxRecognizedCharacters
    }

    /// Performs OCR asynchronously so the main actor is not blocked by Vision processing.
    func extractText(from image: CGImage) async throws -> ExtractedScreenText {
        let startedAt = Date()
        let preparedImage = downsampledImageIfNeeded(image)
        let wasDownsampled = preparedImage.width != image.width || preparedImage.height != image.height

        log(
            "ocr-start input=\(image.width)x\(image.height) prepared=\(preparedImage.width)x\(preparedImage.height) " +
                "downsampled=\(wasDownsampled)"
        )

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let request = VNRecognizeTextRequest { request, error in
                    if let error {
                        let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
                        self.log("ocr-failed elapsed_ms=\(elapsedMilliseconds) reason=\(error.localizedDescription)")
                        continuation.resume(throwing: ScreenTextExtractionError.ocrFailed(error.localizedDescription))
                        return
                    }

                    let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                    // Keep each line's confidence (from its top candidate) so the hygiene pass can drop
                    // the recognizer's weakest guesses; the joined `text` below is for logging and the
                    // window-title fallback only.
                    let recognizedLines: [OCRTextHygiene.OCRLine] = observations
                        .sorted {
                            if Swift.abs($0.boundingBox.minY - $1.boundingBox.minY) > 0.02 {
                                return $0.boundingBox.minY > $1.boundingBox.minY
                            }

                            return $0.boundingBox.minX < $1.boundingBox.minX
                        }
                        .compactMap { observation -> OCRTextHygiene.OCRLine? in
                            guard let candidate = observation.topCandidates(1).first else { return nil }
                            let trimmed = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !trimmed.isEmpty else { return nil }
                            return OCRTextHygiene.OCRLine(text: trimmed, confidence: candidate.confidence)
                        }

                    let joinedText = recognizedLines.map(\.text).joined(separator: "\n")
                    let cappedText = String(joinedText.prefix(maxRecognizedCharacters))

                    guard !cappedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
                        self.log("ocr-empty elapsed_ms=\(elapsedMilliseconds) lines=\(recognizedLines.count)")
                        continuation.resume(throwing: ScreenTextExtractionError.noRecognizedText)
                        return
                    }

                    let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
                    self.log(
                        "ocr-success elapsed_ms=\(elapsedMilliseconds) lines=\(recognizedLines.count) chars=\(cappedText.count) " +
                            "preview=\(self.preview(cappedText))"
                    )

                    continuation.resume(
                        returning: ExtractedScreenText(
                            text: cappedText,
                            lineCount: recognizedLines.count,
                            lines: recognizedLines
                        )
                    )
                }

                // Accurate OCR is slower, but visual context is only captured once per focused
                // field and the result can materially improve autocomplete relevance.
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = false
                request.minimumTextHeight = 0.008

                do {
                    let handler = VNImageRequestHandler(cgImage: preparedImage, options: [:])
                    try handler.perform([request])
                } catch {
                    let elapsedMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1000)
                    self.log("ocr-failed elapsed_ms=\(elapsedMilliseconds) reason=\(error.localizedDescription)")
                    continuation.resume(throwing: ScreenTextExtractionError.ocrFailed(error.localizedDescription))
                }
            }
        }
    }

    /// Keeps OCR latency bounded on very large Retina windows by scaling the image to a reasonable
    /// max dimension before text recognition.
    private func downsampledImageIfNeeded(_ image: CGImage) -> CGImage {
        let width = image.width
        let height = image.height
        let largestDimension = max(width, height)

        guard largestDimension > maxImageDimension else {
            return image
        }

        let scale = CGFloat(maxImageDimension) / CGFloat(largestDimension)
        let targetWidth = max(Int(CGFloat(width) * scale), 1)
        let targetHeight = max(Int(CGFloat(height) * scale), 1)
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage() ?? image
    }

    private func log(_ message: String) {
        // OCR log messages include preview text from the user's screen. Route them through
        // the debug gate so they only appear when the developer explicitly opts in.
        CotabbyDebugOptions.log(message)
    }

    private func preview(_ text: String) -> String {
        let compact = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if compact.count <= 80 {
            return compact
        }

        let cut = compact.index(compact.startIndex, offsetBy: 80)
        return "\(compact[..<cut])..."
    }
}
