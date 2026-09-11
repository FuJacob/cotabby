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
        XCTAssertEqual(rightSize.font.pointSize, 15.4, accuracy: 0.05)
    }

    func testTheSampleSetsAMatchedFacesSizeWithinTheTolerance() {
        // Obsidian: the pixels named the system face at 16, the caret's own travel over this text
        // ran 1.5% short of CoreText's advance at 16. The face stands; its size follows the host.
        let text = "the ghost text is placed when a"
        let hostWidth = GhostFontResolver.width(of: text, font: NSFont.systemFont(ofSize: 16)) * 0.985
        let sample = TypefaceEvidence.Sample(text: text, width: hostWidth)
        let standIn = resolution(NSFont.systemFont(ofSize: 16.2), .caretDerivedCalibrated)
        let matched = OverlayController.applyingMatchedTypeface(
            standIn, match: record(".AppleSystemUIFont", 16), hostNamesFace: false, widthSample: sample, sizeMultiplier: 1
        )
        XCTAssertEqual(matched.provenance, .pixelMatched)
        XCTAssertEqual(GhostFontResolver.width(of: text, font: matched.font), hostWidth, accuracy: hostWidth * 0.004)
        XCTAssertLessThan(matched.font.pointSize, 16)
        XCTAssertGreaterThan(matched.font.pointSize, 15.6)
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

    /// Claude's composer reports 14px and paints at Electron's zoom level 0.5 (its config.json:
    /// `windowControlsZoomFactor` 1.0954451150103321); Obsidian's 16px system text matched at 16.10.
    func testAMatchedSizeTakesTheHostsZoomStep() {
        let standIn = resolution(NSFont.systemFont(ofSize: 14), .hostSizeScaledSystem)
        let claude = OverlayController.applyingMatchedTypeface(
            standIn, match: record("Georgia", 15.4), hostNamesFace: false, sizeMultiplier: 1, reportedSize: 14, zoomKind: .electron
        )
        XCTAssertEqual(claude.font.pointSize, 14 * 1.0954451150103321, accuracy: 0.001)
        let obsidian = OverlayController.applyingMatchedTypeface(
            standIn, match: record(".AppleSystemUIFont", 16.096), hostNamesFace: false, sizeMultiplier: 1,
            reportedSize: 16, zoomKind: .electron
        )
        XCTAssertEqual(obsidian.font.pointSize, 16, accuracy: 0.001)
        let noLadder = OverlayController.applyingMatchedTypeface(
            standIn, match: record(".AppleSystemUIFont", 16.096), hostNamesFace: false, sizeMultiplier: 1, reportedSize: 16, zoomKind: nil
        )
        XCTAssertEqual(noLadder.font.pointSize, 16.096, accuracy: 0.001, "a host with no known ladder keeps the measurement")
    }

    func testASizeFittedToTheHostsAdvanceOffTheLadderKeepsItsFit() {
        // The advance 1.5% short of CoreText's at 16 (above) is past the ladder's tolerance: the
        // host's own advance still sets the size.
        let text = "the ghost text is placed when a"
        let hostWidth = GhostFontResolver.width(of: text, font: NSFont.systemFont(ofSize: 16)) * 0.985
        let sample = TypefaceEvidence.Sample(text: text, width: hostWidth)
        let standIn = resolution(NSFont.systemFont(ofSize: 16.2), .caretDerivedCalibrated)
        let matched = OverlayController.applyingMatchedTypeface(
            standIn, match: record(".AppleSystemUIFont", 16), hostNamesFace: false, widthSample: sample, sizeMultiplier: 1,
            reportedSize: 16, zoomKind: .electron
        )
        XCTAssertLessThan(matched.font.pointSize, 15.9)
    }

    func testTheUsersSizeMultiplierScalesTheSnappedSize() {
        let standIn = resolution(NSFont.systemFont(ofSize: 14), .hostSizeScaledSystem)
        let matched = OverlayController.applyingMatchedTypeface(
            standIn, match: record("Georgia", 15.4), hostNamesFace: false, sizeMultiplier: 1.5, reportedSize: 14, zoomKind: .electron
        )
        XCTAssertEqual(matched.font.pointSize, 14 * 1.0954451150103321 * 1.5, accuracy: 0.002)
    }
}
