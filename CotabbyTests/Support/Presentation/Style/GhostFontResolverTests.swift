import AppKit
import XCTest
@testable import Cotabby

final class GhostFontResolverTests: XCTestCase {
    private func resolve(
        style: ResolvedFieldStyle?,
        metrics: HostTextMetrics? = nil,
        caretBoxHeight: CGFloat = 16,
        renderer: GhostBaselinePolicy.HostRenderer = .textKit,
        multiplier: CGFloat = 1
    ) -> GhostFontResolver.Resolution {
        GhostFontResolver.resolve(
            GhostFontResolver.Input(
                style: style,
                hostMetrics: metrics,
                caretBoxHeight: caretBoxHeight,
                renderer: renderer,
                sizeMultiplier: multiplier
            )
        )
    }

    func testHostFaceAndSizeAreUsedExactlyWithNoFloor() {
        let resolution = resolve(style: ResolvedFieldStyle(fontName: "Menlo-Regular", fontPointSize: 11, colorHex: nil), caretBoxHeight: 13)
        XCTAssertEqual(resolution.font.fontName, "Menlo-Regular")
        XCTAssertEqual(resolution.font.pointSize, 11)
        XCTAssertEqual(resolution.provenance, .hostFace)
    }

    func testDottedSystemFaceRoutesThroughSystemFontAPI() {
        let resolution = resolve(style: ResolvedFieldStyle(fontName: ".AppleSystemUIFont", fontPointSize: 13, colorHex: nil))
        XCTAssertEqual(resolution.font.fontName, NSFont.systemFont(ofSize: 13).fontName)
        XCTAssertEqual(resolution.font.pointSize, 13)
        XCTAssertEqual(resolution.provenance, .hostFace)
    }

    func testFamilyOnlyResolvesTheFamily() {
        let resolution = resolve(
            style: ResolvedFieldStyle(fontName: nil, fontFamily: "Georgia", fontPointSize: 18, colorHex: nil),
            caretBoxHeight: 21
        )
        XCTAssertEqual(resolution.font.familyName, "Georgia")
        XCTAssertEqual(resolution.font.pointSize, 18)
        XCTAssertEqual(resolution.provenance, .hostFamily)
    }

    func testSizeOnlyWithMeasuredWidthMatchesTheMonospaceFamily() {
        let sample = "alpha bravo charlie"
        let hostWidth = GhostFontResolver.width(of: sample, font: NSFont(name: "Menlo-Regular", size: 13)!)
        let resolution = resolve(
            style: ResolvedFieldStyle(fontName: nil, fontPointSize: 13, colorHex: nil),
            metrics: HostTextMetrics(sampleText: sample, sampleWidth: hostWidth),
            caretBoxHeight: 15,
            renderer: .webEngine
        )
        XCTAssertEqual(resolution.font.familyName, "Menlo")
        XCTAssertEqual(resolution.font.pointSize, 13)
        XCTAssertEqual(resolution.provenance, .hostSizeMatchedFamily)
        XCTAssertEqual(resolution.widthAgreement, 1, accuracy: 0.001)
    }

    func testSizeOnlyWithMeasuredWidthMatchesGeorgia() {
        let sample = "delta echo foxtrot golf hotel"
        let hostWidth = GhostFontResolver.width(of: sample, font: NSFont(name: "Georgia", size: 18)!)
        let resolution = resolve(
            style: ResolvedFieldStyle(fontName: nil, fontPointSize: 18, colorHex: nil),
            metrics: HostTextMetrics(sampleText: sample, sampleWidth: hostWidth),
            caretBoxHeight: 21,
            renderer: .webEngine
        )
        XCTAssertEqual(resolution.font.familyName, "Georgia")
        XCTAssertEqual(resolution.provenance, .hostSizeMatchedFamily)
    }

    func testSizeOnlyWithoutSampleUsesSystemFaceAtHostSize() {
        let resolution = resolve(
            style: ResolvedFieldStyle(fontName: nil, fontPointSize: 15, colorHex: "111111"),
            caretBoxHeight: 17,
            renderer: .webEngine
        )
        XCTAssertEqual(resolution.font.pointSize, 15)
        XCTAssertEqual(resolution.font.familyName, NSFont.systemFont(ofSize: 15).familyName)
        XCTAssertEqual(resolution.provenance, .hostSizeSystem)
    }

    func testSizeOnlyWithUnmatchedWidthScalesSystemFaceToTheMeasurement() {
        let sample = "alpha bravo charlie delta"
        let systemWidth = GhostFontResolver.width(of: sample, font: NSFont.systemFont(ofSize: 14))
        // A quarter narrower than the system face: no common family is that condensed at 14pt.
        let hostWidth = systemWidth * 0.75
        let resolution = resolve(
            style: ResolvedFieldStyle(fontName: nil, fontPointSize: 14, colorHex: nil),
            metrics: HostTextMetrics(sampleText: sample, sampleWidth: hostWidth),
            caretBoxHeight: 17,
            renderer: .webEngine
        )
        XCTAssertEqual(resolution.provenance, .hostSizeScaledSystem)
        let scaledWidth = GhostFontResolver.width(of: sample, font: resolution.font)
        XCTAssertEqual(scaledWidth / hostWidth, 1, accuracy: 0.02)
    }

    func testImplausibleReportedSizeFallsBackToCaretBox() {
        // A 40pt face cannot fit a 16pt caret box; the box is the measurement to trust.
        let resolution = resolve(style: ResolvedFieldStyle(fontName: "Helvetica", fontPointSize: 40, colorHex: nil), caretBoxHeight: 16)
        XCTAssertEqual(resolution.provenance, .caretDerived)
        XCTAssertLessThan(resolution.font.pointSize, 16)
    }

    func testNoStyleDerivesSizeFromTextKitLineHeight() {
        let resolution = resolve(style: nil, caretBoxHeight: 16, renderer: .textKit)
        XCTAssertEqual(resolution.provenance, .caretDerived)
        let lineHeight = NSLayoutManager().defaultLineHeight(for: resolution.font)
        XCTAssertEqual(lineHeight, 16, accuracy: 1)
    }

    func testNoStyleDerivesSizeFromWebContentArea() {
        let resolution = resolve(style: nil, caretBoxHeight: 21, renderer: .webEngine)
        let contentHeight = resolution.font.ascender - resolution.font.descender
        XCTAssertEqual(contentHeight, 21, accuracy: 1.2)
    }

    func testSizeMultiplierScalesTheHostSizeOnlyWhenNotOne() {
        let unit = resolve(style: ResolvedFieldStyle(fontName: "Menlo-Regular", fontPointSize: 14, colorHex: nil), multiplier: 1)
        XCTAssertEqual(unit.font.pointSize, 14)
        let scaled = resolve(style: ResolvedFieldStyle(fontName: "Menlo-Regular", fontPointSize: 14, colorHex: nil), multiplier: 1.5)
        XCTAssertEqual(scaled.font.pointSize, 21)
        XCTAssertEqual(scaled.font.fontName, "Menlo-Regular")
    }

    /// Xcode reports its editor face as "SFMono-Medium" (family "SF Mono"), which `NSFont(name:)`
    /// cannot load; it must come from the monospaced system font API, weight included.
    func testSFMonoNamesResolveThroughTheMonospacedSystemFont() {
        let medium = GhostFontResolver.font(named: "SFMono-Medium", size: 12)
        XCTAssertNotNil(medium)
        XCTAssertEqual(medium?.pointSize, 12)
        XCTAssertTrue(medium?.isFixedPitch ?? false)
        XCTAssertNotNil(GhostFontResolver.font(family: "SF Mono", size: 12))
    }

    /// Xcode's editor drew SF Mono 12 with 7.42pt advances (3% wider than the face at 12); the
    /// named face is kept and its size follows the host's own measurement.
    func testANamedFaceIsScaledWhenTheHostMeasuresItWider() {
        let sample = "The quick brown fox"
        let base = NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        let hostWidth = (sample as NSString).size(withAttributes: [.font: base]).width * 1.03
        let resolution = GhostFontResolver.resolve(
            GhostFontResolver.Input(
                style: ResolvedFieldStyle(fontName: "SFMono-Medium", fontFamily: "SF Mono", fontPointSize: 12, colorHex: nil),
                hostMetrics: HostTextMetrics(sampleText: sample, sampleWidth: hostWidth),
                caretBoxHeight: 17,
                renderer: .textKit
            )
        )
        XCTAssertEqual(resolution.provenance, .hostFaceScaled)
        XCTAssertEqual(resolution.widthAgreement, 1, accuracy: 0.01)
        XCTAssertGreaterThan(resolution.font.pointSize, 12)
    }
}
