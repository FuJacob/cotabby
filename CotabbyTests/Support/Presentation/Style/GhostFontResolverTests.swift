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

    func testACaretBoxFarTallerThanTheReportedSizeFallsBackToTheBox() {
        // A 13pt size cannot own a 40pt line box; the box is the measurement to trust.
        let resolution = resolve(style: ResolvedFieldStyle(fontName: "Helvetica", fontPointSize: 13, colorHex: nil), caretBoxHeight: 40)
        XCTAssertEqual(resolution.provenance, .caretDerived)
        XCTAssertGreaterThan(resolution.font.pointSize, 13)
    }

    func testACaretBoxShorterThanTheReportedSizeNeverShrinksTheFace() {
        // Measured in VS Code: the hidden textarea's 8.5pt caret box for a 14pt editor. Text never
        // paints in a line shorter than its glyphs, so the box is not the line and the size stands.
        let resolution = resolve(style: ResolvedFieldStyle(fontName: nil, fontPointSize: 14, colorHex: nil), caretBoxHeight: 8.5)
        XCTAssertEqual(resolution.font.pointSize, 14)
        XCTAssertNotEqual(resolution.provenance, .caretDerived)
    }

    /// Measured 2026-09-11: a Menlo textarea whose host reported no style. Its width samples were a
    /// face wider than the system face its caret box named, and scaled to them the system face grew
    /// from 15.5 to 22pt over twelve seconds of typing. The box's size stands until something names
    /// the face.
    func testASampleFromAnotherFaceDoesNotRescaleTheCaretBoxFace() throws {
        let sample = "it is still in the list, I will fill it in"
        let boxOnly = resolve(style: nil, caretBoxHeight: 18, renderer: .webEngine)
        let hostWidth = GhostFontResolver.width(of: sample, font: try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 14.3)))
        XCTAssertGreaterThan(hostWidth / GhostFontResolver.width(of: sample, font: boxOnly.font), 1.15, "a face apart, not a size")
        let resolution = resolve(
            style: nil, metrics: HostTextMetrics(sampleText: sample, sampleWidth: hostWidth), caretBoxHeight: 18, renderer: .webEngine
        )
        XCTAssertEqual(resolution.provenance, .caretDerived)
        XCTAssertEqual(resolution.font.pointSize, boxOnly.font.pointSize, accuracy: 0.01)
    }

    func testASampleCloseToTheCaretBoxFaceStillCalibratesIt() {
        let sample = "it is still in the list, I will fill it in"
        let boxOnly = resolve(style: nil, caretBoxHeight: 18, renderer: .webEngine)
        let hostWidth = GhostFontResolver.width(of: sample, font: boxOnly.font) * 1.06
        let resolution = resolve(
            style: nil, metrics: HostTextMetrics(sampleText: sample, sampleWidth: hostWidth), caretBoxHeight: 18, renderer: .webEngine
        )
        XCTAssertEqual(resolution.provenance, .caretDerivedCalibrated)
        // The system face's advance per point shrinks as it grows (its tracking changes with size),
        // so a sample 6% wider takes a size nearly 8% larger: what must agree is the width.
        XCTAssertEqual(GhostFontResolver.width(of: sample, font: resolution.font) / hostWidth, 1, accuracy: 0.01)
    }

    /// The monospaced system face names its family ".AppleSystemUIFontMonospaced"; read as a dotted
    /// system name it became the proportional face, so a field that matched it failed every later
    /// sample in it (a Menlo textarea in Chrome, 2026-09-11, then settled on SF scaled to 17.2).
    func testTheMonospacedSystemFamilyIsTheMonospacedFace() throws {
        let monospaced = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        let family = try XCTUnwrap(monospaced.familyName)
        let resolved = try XCTUnwrap(GhostFontResolver.familyFont(family, size: 13))
        XCTAssertTrue(resolved.isFixedPitch || resolved.fontDescriptor.symbolicTraits.contains(.monoSpace))
        // Its own text fits it; Menlo's, 2.7% narrower, does not (they are different faces).
        let sample = "Thanks for sending the report"
        XCTAssertTrue(GhostFontResolver.familyFits(family, sample: sample, width: GhostFontResolver.width(of: sample, font: monospaced), size: 13))
        let menloWidth = GhostFontResolver.width(of: sample, font: try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 13)))
        XCTAssertFalse(GhostFontResolver.familyFits(family, sample: sample, width: menloWidth, size: 13))
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

    /// A host that names a face the Mac does not have (Gemini names its bundled Google Sans) gets
    /// the system face scaled to its measured width, never a guessed installed family: the real
    /// face is known and is none of the candidates, and guessing one flipped per sample.
    func testUnavailableNamedFaceUsesTheScaledSystemFace() {
        let sample = "delta echo foxtrot golf hotel"
        let hostWidth = GhostFontResolver.width(of: sample, font: NSFont(name: "Georgia", size: 17)!)
        let resolution = resolve(
            style: ResolvedFieldStyle(fontName: "GoogleSansText-Regular", fontFamily: "Google Sans Text", fontPointSize: 17, colorHex: nil),
            metrics: HostTextMetrics(sampleText: sample, sampleWidth: hostWidth),
            caretBoxHeight: 21,
            renderer: .webEngine
        )
        XCTAssertEqual(resolution.provenance, .hostSizeScaledSystem)
        XCTAssertNotEqual(resolution.font.familyName, "Georgia")
        XCTAssertEqual(resolution.widthAgreement, 1, accuracy: 0.01, "scaled so its advances match the host's measurement")
    }

    func testUnavailableNamedFaceWithoutASampleUsesTheSystemFaceAtHostSize() {
        let resolution = resolve(
            style: ResolvedFieldStyle(fontName: "GoogleSansText-Regular", fontFamily: nil, fontPointSize: 17, colorHex: nil),
            metrics: nil,
            caretBoxHeight: 21,
            renderer: .webEngine
        )
        XCTAssertEqual(resolution.provenance, .hostSizeSystem)
        XCTAssertEqual(resolution.font.pointSize, 17)
    }
}

/// Rescaling keeps the face: the system face rebuilt from its descriptor answers to the raw
/// PostScript name (`.SFNS-Regular`), which the logs and the typeface match then take for a
/// different face (Obsidian, 2026-09-10).
final class GhostFontResolverResizingTests: XCTestCase {
    func testTheSystemFaceKeepsItsNameAndAdvancesWhenResized() {
        let system = NSFont.systemFont(ofSize: 16)
        let resized = GhostFontResolver.resized(system, to: 15.8)
        XCTAssertEqual(resized.fontName, system.fontName)
        XCTAssertEqual(resized.pointSize, 15.8, accuracy: 0.001)
        XCTAssertEqual(
            GhostFontResolver.width(of: "the words that wrap", font: resized),
            GhostFontResolver.width(of: "the words that wrap", font: NSFont.systemFont(ofSize: 15.8)),
            accuracy: 0.001
        )
        let text = "the ghost text is placed"
        let scaled = GhostFontResolver.scaled(system, toSample: text, width: GhostFontResolver.width(of: text, font: system) * 0.97)
        XCTAssertEqual(scaled.fontName, system.fontName, "a sample-scaled system face is still the system face")
        XCTAssertLessThan(scaled.pointSize, 16)
    }

    func testANamedFaceIsResizedInPlace() throws {
        let georgia = try XCTUnwrap(NSFont(name: "Georgia", size: 18))
        let resized = GhostFontResolver.resized(georgia, to: 15.4)
        XCTAssertEqual(resized.fontName, "Georgia")
        XCTAssertEqual(resized.pointSize, 15.4, accuracy: 0.001)
    }

    /// A system-font Chrome field (2026-09-11): " was thinking t" measured 99.0pt from the caret, the
    /// system face 0.41% off and Trebuchet MS 0.20%, and the best fit showed Trebuchet.
    func testTheSystemFaceStaysWhenAFamilyFitsOnlyByChance() {
        let resolution = GhostFontResolver.resolve(
            GhostFontResolver.Input(
                style: ResolvedFieldStyle(fontName: nil, fontPointSize: 15, colorHex: nil),
                hostMetrics: HostTextMetrics(sampleText: " was thinking t", sampleWidth: 99.0),
                caretBoxHeight: 18,
                renderer: .webEngine,
                sizeMultiplier: 1
            )
        )
        XCTAssertEqual(resolution.provenance, GhostFontResolver.Provenance.hostSizeSystem)
        XCTAssertEqual(resolution.font.familyName, NSFont.systemFont(ofSize: 15).familyName)
    }
}
