import AppKit
import XCTest
@testable import Cotabby

/// The overlay's last word on a pixel-matched face: it must agree with the width the host itself
/// rendered, when one was measured.
@MainActor
final class OverlayControllerTypefaceTests: XCTestCase {
    private func resolution(_ font: NSFont, _ provenance: GhostFontResolver.Provenance) -> GhostFontResolver.Resolution {
        GhostFontResolver.Resolution(font: font, provenance: provenance, widthAgreement: 1)
    }

    private func record(_ fontName: String, _ size: CGFloat) -> HostBaselineCalibrator.TypefaceMatchRecord {
        HostBaselineCalibrator.TypefaceMatchRecord(fontName: fontName, pointSize: size, score: 0.9, textLength: 20, attempts: 1)
    }

    func testAMatchWhoseAdvanceDisagreesWithTheHostsSampleIsRefused() {
        // Claude's composer: the caret travelled the width of Georgia 15.4 over this text; the
        // system face at 16.15 scored well on the shapes but is five percent wider than that.
        let text = "the user writes, and then"
        let sample = TypefaceEvidence.Sample(text: text, width: GhostFontResolver.width(of: text, font: NSFont(name: "Georgia", size: 15.4)!))
        let standIn = resolution(NSFont.systemFont(ofSize: 15.4), .hostSizeScaledSystem)

        let wrongSize = OverlayController.applyingMatchedTypeface(
            standIn, match: record("Georgia", 16.15), hostNamesFace: false, widthSample: sample, sizeMultiplier: 1
        )
        XCTAssertEqual(wrongSize.provenance, .hostSizeScaledSystem, "a face five percent off the measured advance is refused")

        let rightSize = OverlayController.applyingMatchedTypeface(
            standIn, match: record("Georgia", 15.4), hostNamesFace: false, widthSample: sample, sizeMultiplier: 1
        )
        XCTAssertEqual(rightSize.provenance, .pixelMatched)
        XCTAssertEqual(rightSize.font.familyName, "Georgia")
        XCTAssertEqual(rightSize.font.pointSize, 15.4)
    }

    func testWithoutASampleTheMatchStandsOnItsShapes() {
        let standIn = resolution(NSFont.systemFont(ofSize: 15.4), .hostSizeSystem)
        let matched = OverlayController.applyingMatchedTypeface(
            standIn, match: record("Georgia", 16.15), hostNamesFace: false, widthSample: nil, sizeMultiplier: 1
        )
        XCTAssertEqual(matched.provenance, .pixelMatched)
    }

    func testTheUsersSizeMultiplierScalesTheMatchedFaceAfterTheCheck() {
        let text = "the user writes, and then"
        let sample = TypefaceEvidence.Sample(text: text, width: GhostFontResolver.width(of: text, font: NSFont(name: "Georgia", size: 15.4)!))
        let standIn = resolution(NSFont.systemFont(ofSize: 15.4), .hostSizeScaledSystem)
        let matched = OverlayController.applyingMatchedTypeface(
            standIn, match: record("Georgia", 15.4), hostNamesFace: false, widthSample: sample, sizeMultiplier: 1.5
        )
        XCTAssertEqual(matched.provenance, .pixelMatched, "the multiplier is the user's request, not a disagreement with the host")
        XCTAssertEqual(matched.font.pointSize, 15.4 * 1.5, accuracy: 0.001)
    }
}
