import AppKit
import XCTest
@testable import Cotabby

/// How a field's ghost face and size are settled from what the field measured: a pixel-matched
/// face must agree with the width the host itself rendered, when one was measured, and every size
/// rebuilt from the host's takes the user's multiplier exactly once.
@MainActor
final class HostTypefaceResolverTests: XCTestCase {
    private func resolution(_ font: NSFont, _ provenance: GhostFontResolver.Provenance) -> GhostFontResolver.Resolution {
        GhostFontResolver.Resolution(font: font, provenance: provenance, widthAgreement: 1)
    }

    private func record(_ fontName: String, _ size: CGFloat) -> HostBaselineCalibrator.TypefaceMatchRecord {
        HostBaselineCalibrator.TypefaceMatchRecord(fontName: fontName, pointSize: size, score: 0.9, textLength: 20, attempts: 1)
    }

    /// Measured 2026-09-11 in a ProseMirror-style page at 110%: a paragraph's box read 24 for a 23.1pt
    /// line where two lines had measured 23.5, and every first wrap after the first sat a point low.
    /// A remembered pitch within the box's rounding wins; one further off belongs to another
    /// line-height and does not; with none remembered the box stands.
    func testAParagraphsBoxGivesWayToARememberedPitchWithinItsRounding() {
        XCTAssertEqual(HostTypefaceResolver.pitch(fromParagraphBox: 24, remembered: 23.5), 23.5)
        XCTAssertEqual(HostTypefaceResolver.pitch(fromParagraphBox: 33, remembered: 23.5), 33)
        XCTAssertEqual(HostTypefaceResolver.pitch(fromParagraphBox: 24, remembered: nil), 24)
    }

    /// A system-font Chrome field (2026-09-11): the reported 15.0, then three presentations of the
    /// system face scaled to a dozen-character sample (15.06), then the pixel match's 15.0. A scaled
    /// size within a percent of the host's zoom step is that step; a stand-in further off keeps the
    /// size its sample gives.
    func testAScaledSystemFaceTakesTheHostsZoomStep() throws {
        let text = "I was thinking that"
        var nearLadder = TypefaceEvidence()
        nearLadder.record(.init(text: text, width: GhostFontResolver.width(of: text, font: NSFont.systemFont(ofSize: 15.0621))), resolverFamily: nil)
        XCTAssertEqual(HostTypefaceResolver.scaledSystemFace(size: 15, evidence: nearLadder).font.pointSize, 15.0621, accuracy: 0.01)
        let snapped = HostTypefaceResolver.scaledSystemFace(size: 15, evidence: nearLadder, reportedSize: 15, zoomKind: .chromeBrowser)
        XCTAssertEqual(snapped.font.pointSize, 15.0, accuracy: 0.001)
        XCTAssertEqual(snapped.provenance, .hostSizeScaledSystem)

        var offLadder = TypefaceEvidence()
        offLadder.record(.init(text: text, width: GhostFontResolver.width(of: text, font: NSFont.systemFont(ofSize: 15.45))), resolverFamily: nil)
        let standIn = HostTypefaceResolver.scaledSystemFace(size: 15, evidence: offLadder, reportedSize: 15, zoomKind: .chromeBrowser)
        XCTAssertEqual(standIn.font.pointSize, 15.45, accuracy: 0.01, "a stand-in three percent off the ladder keeps its sample's size")
    }

    /// Claude's composer at a 60% ghost size (2026-10-29): the system face scaled to the host's
    /// 15.7 width rendered and was remembered at 15.7, not 9.4, and every later launch started there.
    /// The width sample sizes the host's face; the user's multiplier sizes the ghost.
    func testAScaledSystemFaceKeepsTheUsersSizeMultiplier() {
        let text = "I was thinking that"
        var evidence = TypefaceEvidence()
        evidence.record(.init(text: text, width: GhostFontResolver.width(of: text, font: NSFont.systemFont(ofSize: 15.7))), resolverFamily: nil)
        let ghost = HostTypefaceResolver.scaledSystemFace(size: 15, evidence: evidence, sizeMultiplier: 0.6)
        XCTAssertEqual(ghost.font.pointSize, 15.7 * 0.6, accuracy: 0.02)
        XCTAssertEqual(ghost.provenance, .hostSizeScaledSystem)

        // A sample within the ladder's tolerance of the reported 15 snaps to it, and the snapped
        // size is scaled too.
        var nearStep = TypefaceEvidence()
        nearStep.record(.init(text: text, width: GhostFontResolver.width(of: text, font: NSFont.systemFont(ofSize: 15.0621))), resolverFamily: nil)
        let snapped = HostTypefaceResolver.scaledSystemFace(
            size: 15, evidence: nearStep, reportedSize: 15, zoomKind: .chromeBrowser, sizeMultiplier: 0.6
        )
        XCTAssertEqual(snapped.font.pointSize, 15 * 0.6, accuracy: 0.001, "a zoom-step snap is the host's size, still scaled for the ghost")

        let undecided = HostTypefaceResolver.settledResolution(
            for: .undecidable,
            replacing: resolution(NSFont.systemFont(ofSize: 9), .hostSizeSystem),
            systemFamily: NSFont.systemFont(ofSize: 15).familyName ?? "",
            size: 15,
            evidence: evidence,
            sizeMultiplier: 0.6
        )
        XCTAssertEqual(undecided.font.pointSize, 15.7 * 0.6, accuracy: 0.02)
    }

    /// The same rule through a live resolver (`applyingTypefaceEvidence`): `GhostFontResolver`'s
    /// resolution arrives already scaled (12 for a host's 15 at 80%), so where the host reports no
    /// size its size is recovered by dividing the multiplier back out, and each face rebuilt from it
    /// is scaled exactly once.
    func testTypefaceEvidenceRecoversTheHostsSizeAndScalesTheGhostOnce() throws {
        let settings = SuggestionSettingsModel(configuration: .standard, userDefaults: IsolatedUserDefaults.make())
        settings.setGhostTextSizeMultiplier(0.8)
        XCTAssertEqual(settings.ghostTextSizeMultiplier, 0.8, accuracy: 0.0001)
        let typefaces = HostTypefaceResolver(suggestionSettings: settings)
        let resolved = resolution(NSFont.systemFont(ofSize: 12), .hostSizeSystem)

        // A host naming a face this Mac lacks, with no size and no sample yet: the system face at the
        // recovered host size 15, scaled to 12 (not 15, and not 12 scaled again to 9.6).
        let namedFace = SuggestionOverlayGeometry(
            caretRect: CGRect(x: 0, y: 0, width: 2, height: 18),
            inputFrameRect: nil,
            caretQuality: .exact,
            observedCharWidth: nil,
            isRightToLeft: false,
            focusedInputIdentityKey: 1,
            resolvedFieldStyle: ResolvedFieldStyle(fontName: "CotabbyMissingFace-Regular", fontPointSize: nil, colorHex: nil)
        )
        XCTAssertEqual(typefaces.applyingTypefaceEvidence(resolved, for: namedFace).font.pointSize, 12, accuracy: 0.01)

        // A size-only field whose adopted sample measures the host at 15.7: the ghost is 15.7 at 80%.
        let text = "I was thinking that"
        let sampled = SuggestionOverlayGeometry(
            caretRect: CGRect(x: 0, y: 0, width: 2, height: 18),
            inputFrameRect: nil,
            caretQuality: .exact,
            observedCharWidth: nil,
            isRightToLeft: false,
            focusedInputIdentityKey: 2,
            hostTextMetrics: HostTextMetrics(
                sampleText: text,
                sampleWidth: GhostFontResolver.width(of: text, font: NSFont.systemFont(ofSize: 15.7))
            )
        )
        let ghost = typefaces.applyingTypefaceEvidence(resolved, for: sampled)
        XCTAssertEqual(ghost.font.pointSize, 15.7 * 0.8, accuracy: 0.02)
        XCTAssertEqual(ghost.provenance, .hostSizeScaledSystem)
    }

    func testAMatchWhoseAdvanceDisagreesWithTheHostsSampleIsRefused() {
        // Claude's composer: the caret travelled the width of Georgia 15.4 over this text; the
        // system face at 16.15 scored well on the shapes but is five percent wider than that.
        let text = "the user writes, and then"
        let sample = TypefaceEvidence.Sample(text: text, width: GhostFontResolver.width(of: text, font: NSFont(name: "Georgia", size: 15.4)!))
        let standIn = resolution(NSFont.systemFont(ofSize: 15.4), .hostSizeScaledSystem)

        let wrongSize = HostTypefaceResolver.applyingMatchedTypeface(
            standIn, match: record("Georgia", 16.15), hostNamesFace: false, widthSample: sample, sizeMultiplier: 1
        )
        XCTAssertEqual(wrongSize.provenance, .hostSizeScaledSystem, "a face five percent off the measured advance is refused")

        let rightSize = HostTypefaceResolver.applyingMatchedTypeface(
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
        let matched = HostTypefaceResolver.applyingMatchedTypeface(
            standIn, match: record(".AppleSystemUIFont", 16), hostNamesFace: false, widthSample: sample, sizeMultiplier: 1
        )
        XCTAssertEqual(matched.provenance, .pixelMatched)
        XCTAssertEqual(GhostFontResolver.width(of: text, font: matched.font), hostWidth, accuracy: hostWidth * 0.004)
        XCTAssertLessThan(matched.font.pointSize, 16)
        XCTAssertGreaterThan(matched.font.pointSize, 15.6)
    }

    func testWithoutASampleTheMatchStandsOnItsShapes() {
        let standIn = resolution(NSFont.systemFont(ofSize: 15.4), .hostSizeSystem)
        let matched = HostTypefaceResolver.applyingMatchedTypeface(
            standIn, match: record("Georgia", 16.15), hostNamesFace: false, widthSample: nil, sizeMultiplier: 1
        )
        XCTAssertEqual(matched.provenance, .pixelMatched)
    }

    func testTheUsersSizeMultiplierScalesTheMatchedFaceAfterTheCheck() {
        let text = "the user writes, and then"
        let sample = TypefaceEvidence.Sample(text: text, width: GhostFontResolver.width(of: text, font: NSFont(name: "Georgia", size: 15.4)!))
        let standIn = resolution(NSFont.systemFont(ofSize: 15.4), .hostSizeScaledSystem)
        let matched = HostTypefaceResolver.applyingMatchedTypeface(
            standIn, match: record("Georgia", 15.4), hostNamesFace: false, widthSample: sample, sizeMultiplier: 1.5
        )
        XCTAssertEqual(matched.provenance, .pixelMatched, "the multiplier is the user's request, not a disagreement with the host")
        XCTAssertEqual(matched.font.pointSize, 15.4 * 1.5, accuracy: 0.001)
    }

    /// Claude's composer reports 14px and paints at Electron's zoom level 0.5 (its config.json:
    /// `windowControlsZoomFactor` 1.0954451150103321); Obsidian's 16px system text matched at 16.10.
    func testAMatchedSizeTakesTheHostsZoomStep() {
        let standIn = resolution(NSFont.systemFont(ofSize: 14), .hostSizeScaledSystem)
        let claude = HostTypefaceResolver.applyingMatchedTypeface(
            standIn, match: record("Georgia", 15.4), hostNamesFace: false, sizeMultiplier: 1, reportedSize: 14, zoomKind: .electron
        )
        XCTAssertEqual(claude.font.pointSize, 14 * 1.0954451150103321, accuracy: 0.001)
        let obsidian = HostTypefaceResolver.applyingMatchedTypeface(
            standIn, match: record(".AppleSystemUIFont", 16.096), hostNamesFace: false, sizeMultiplier: 1,
            reportedSize: 16, zoomKind: .electron
        )
        XCTAssertEqual(obsidian.font.pointSize, 16, accuracy: 0.001)
        let noLadder = HostTypefaceResolver.applyingMatchedTypeface(
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
        let matched = HostTypefaceResolver.applyingMatchedTypeface(
            standIn, match: record(".AppleSystemUIFont", 16), hostNamesFace: false, widthSample: sample, sizeMultiplier: 1,
            reportedSize: 16, zoomKind: .electron
        )
        XCTAssertLessThan(matched.font.pointSize, 15.9)
    }

    func testTheUsersSizeMultiplierScalesTheSnappedSize() {
        let standIn = resolution(NSFont.systemFont(ofSize: 14), .hostSizeScaledSystem)
        let matched = HostTypefaceResolver.applyingMatchedTypeface(
            standIn, match: record("Georgia", 15.4), hostNamesFace: false, sizeMultiplier: 1.5, reportedSize: 14, zoomKind: .electron
        )
        XCTAssertEqual(matched.font.pointSize, 14 * 1.0954451150103321 * 1.5, accuracy: 0.002)
    }

    /// Chrome's address bar (2026-09-11) and Discord's composer (2026-11-22): no reported size, a
    /// stand-in face, and a pixel match that never names the host's; the caret-derived size ran 7%
    /// and 19% large. A web field's stand-in takes the size its caret's advance fits, single-line
    /// or paragraph; a field that reports its size does not, nor one outside web content.
    func testAWebFieldsStandInTakesItsCaretsAdvance() {
        func takes(_ provenance: GhostFontResolver.Provenance, web: Bool = true, reportsSize: Bool = false) -> Bool {
            HostTypefaceResolver.takesHostAdvance(provenance: provenance, isWebContentField: web, reportsSize: reportsSize)
        }
        XCTAssertTrue(takes(.caretDerived))
        XCTAssertTrue(takes(.hostAdvanceFitted), "a fitted face keeps refining")
        XCTAssertTrue(takes(.pixelMatched))
        XCTAssertFalse(takes(.caretDerived, reportsSize: true))
        XCTAssertFalse(takes(.caretDerived, web: false))
        XCTAssertFalse(takes(.hostFace), "a face the host named is its own")
    }

    func testOnlyACaretDerivedSizeIsACaretBoxGuess() {
        XCTAssertTrue(GhostFontResolver.Provenance.caretDerived.sizeIsCaretBoxGuess)
        XCTAssertTrue(GhostFontResolver.Provenance.caretDerivedCalibrated.sizeIsCaretBoxGuess)
        XCTAssertFalse(GhostFontResolver.Provenance.hostAdvanceFitted.sizeIsCaretBoxGuess, "a fitted size is measured")
        XCTAssertFalse(GhostFontResolver.Provenance.hostRemembered.sizeIsCaretBoxGuess)
        XCTAssertFalse(GhostFontResolver.Provenance.hostSizeSystem.sizeIsCaretBoxGuess)
    }
}
