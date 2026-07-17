import CoreGraphics
import XCTest
@testable import Cotabby

/// Direct tests for the Vision-backed OCR service boundary.
///
/// Screenshot-context tests usually stub OCR so they can focus on orchestration. This file exists
/// separately because the crash happened inside `ScreenTextExtractor`'s callback-to-async bridge,
/// which only runs when the real Vision request path is exercised.
final class ScreenTextExtractorTests: XCTestCase {
    func test_extractText_tinyImagesReturnNoRecognizedTextWithoutCrashing() async throws {
        let extractor = ScreenTextExtractor()

        for dimension in [1, 2] {
            let image = try makeSolidImage(width: dimension, height: dimension)
            await assertNoRecognizedText(from: image, extractor: extractor)
        }
    }

    func test_extractText_blankNormalImageReturnsNoRecognizedText() async throws {
        let image = try makeSolidImage(width: 128, height: 128)

        await assertNoRecognizedText(from: image, extractor: ScreenTextExtractor())
    }

    private func assertNoRecognizedText(
        from image: CGImage,
        extractor: ScreenTextExtractor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await extractor.extractText(from: image)
            XCTFail("Expected OCR to report no recognized text.", file: file, line: line)
        } catch ScreenTextExtractionError.noRecognizedText {
            // Expected: blank or degenerate screenshots should be treated as unavailable context.
        } catch {
            XCTFail("Expected noRecognizedText, got \(error).", file: file, line: line)
        }
    }

    private func makeSolidImage(width: Int, height: Int) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
}
