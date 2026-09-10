import AppKit
import XCTest
@testable import Cotabby

/// Strips are rendered here the way a browser paints them (dark text on a light field, or light on
/// dark, at 2x) and the matcher must name the face they were drawn in.
final class TypefaceMatcherTests: XCTestCase {
    private let scale: CGFloat = 2
    private let stripSize = CGSize(width: 240, height: 24)

    private func strip(_ text: String, font: NSFont, baselineFromTop: CGFloat, dark: Bool = false) -> (RGBABitmap, CGFloat) {
        let width = Int(stripSize.width * scale)
        let height = Int(stripSize.height * scale)
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(dark ? CGColor(gray: 0.1, alpha: 1) : CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: stripSize))
        let attributed = NSAttributedString(
            string: text, attributes: [.font: font, .foregroundColor: dark ? NSColor(white: 0.92, alpha: 1) : NSColor.black]
        )
        let line = CTLineCreateWithAttributedString(attributed)
        let advance = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let caretX = stripSize.width - 6
        context.textPosition = CGPoint(x: caretX - advance, y: stripSize.height - baselineFromTop)
        CTLineDraw(line, context)
        return (RGBABitmap(context.makeImage()!)!, caretX * scale)
    }

    /// Matches a strip drawn in `font`, telling the matcher the size was `asking` (the host's own
    /// claim, right or wrong) and the letter-body height the baseline analyzer reads off the strip,
    /// exactly as the calibrator does.
    private func match(_ text: String, font: NSFont, dark: Bool = false, asking: CGFloat? = nil) -> TypefaceMatcher.Match? {
        let baseline: CGFloat = 17
        let (bitmap, caretColumn) = strip(text, font: font, baselineFromTop: baseline, dark: dark)
        let asked = asking ?? font.pointSize
        let bodies = InkBaselineAnalyzer.measure(bitmap).map { $0.baselineRow - $0.bodyTopRow }
        return TypefaceMatcher.match(
            TypefaceMatcher.Input(
                strip: bitmap, scale: scale, caretColumn: caretColumn, baselineRow: baseline * scale,
                text: text, pointSize: asked, bodyRows: bodies, candidates: TypefaceMatcher.defaultCandidates(pointSize: asked)
            )
        )
    }

    private var systemFamily: String { NSFont.systemFont(ofSize: 16).familyName ?? "" }

    /// Measured 2026-09-10: Obsidian's 16px system-face body reached the matcher as 17 and 20,
    /// ChatGPT's as 19 and (from a two-line caret box) 41.5, and at 20 the old size-blind match
    /// named Times New Roman with 0.92. The face and the size must both come back right.
    func testRecoversTheSystemFaceAndItsSizeWhateverSizeWasClaimed() {
        for asked in [16.0, 17.0, 19.0, 20.0, 41.5] as [CGFloat] {
            let match = match("notes and I was wondering about the", font: NSFont.systemFont(ofSize: 16), dark: asked > 18, asking: asked)
            XCTAssertEqual(match?.familyName, systemFamily, "asked \(asked): \(String(describing: match))")
            XCTAssertEqual(match?.pointSize ?? 0, 16, accuracy: 0.35, "asked \(asked)")
        }
    }

    func testHelveticaAtAFractionallyWrongSizeIsHelveticaOrItsMetricTwin() {
        // Chrome's `<input>` at 16px Helvetica reached the matcher as 15.87 and 15.49.
        for asked in [15.49, 15.87, 20.0] as [CGFloat] {
            let match = match("Hi Sarah, thanks for sending over", font: NSFont(name: "Helvetica", size: 16)!, asking: asked)
            XCTAssertTrue(["Helvetica", "Arial"].contains(match?.familyName ?? ""), "asked \(asked): \(String(describing: match))")
            XCTAssertEqual(match?.pointSize ?? 0, 16, accuracy: 0.35, "asked \(asked)")
        }
    }

    /// A zoomed web page paints its face at a size no grid point lands on. Measured 2026-09-10 on
    /// Claude's composer (Anthropic Sans at 15.4 under 110% zoom): the true face scored 0.66 at
    /// the grid's 15.25 and 0.95 at 15.40, while a wrong face reached 0.87 at a size of its own;
    /// refining only the coarse leaders left the true face unrefined in fifth place. Every
    /// candidate must be carried to its exact size.
    func testAFaceAtAnOffGridSizeIsRecoveredToWithinAFewHundredths() {
        for (font, family) in [(NSFont(name: "Georgia", size: 15.4)!, "Georgia"), (NSFont.systemFont(ofSize: 15.4), systemFamily)] {
            let match = match("notes and I was wondering about the", font: font, dark: family != "Georgia", asking: 14)
            XCTAssertEqual(match?.familyName, family, "\(String(describing: match))")
            XCTAssertEqual(match?.pointSize ?? 0, 15.4, accuracy: 0.06, "\(String(describing: match))")
            XCTAssertGreaterThan(match?.score ?? 0, 0.9)
        }
    }

    func testASerifFaceIsRecoveredFromAnUndersizedClaim() {
        let match = match("and the second section needs more", font: NSFont(name: "TimesNewRomanPSMT", size: 16)!, asking: 13)
        XCTAssertEqual(match?.familyName, "Times New Roman", "\(String(describing: match))")
        XCTAssertEqual(match?.pointSize ?? 0, 16, accuracy: 0.35)
    }

    /// Measured in Chrome's Georgia 18px contenteditable: with the wide grid, Times New Roman at
    /// 19.5 reproduced the strip's advances and letter bodies. A size the host reported is not up
    /// for that kind of debate.
    func testAReportedSizeKeepsTheSearchNarrow() {
        let input = TypefaceMatcher.Input(
            strip: RGBABitmap(width: 4, height: 4, bytes: [UInt8](repeating: 255, count: 64)), scale: 2, caretColumn: 3,
            baselineRow: 2, text: "abc", pointSize: 18, bodyRows: 30, sizeIsReported: true, candidates: []
        )
        let sizes = TypefaceMatcher.searchSizes(input)
        XCTAssertTrue(sizes.allSatisfy { $0 >= 16.9 && $0 <= 19.1 }, "\(sizes)")
        XCTAssertFalse(sizes.contains { abs($0 - 19.5) < 0.2 })
    }

    func testGeorgiaAtItsReportedSizeIsNotTimesNewRoman() {
        let (bitmap, caretColumn) = strip("Field three alpha bravo charlie x", font: NSFont(name: "Georgia", size: 18)!, baselineFromTop: 17)
        let bodies = InkBaselineAnalyzer.measure(bitmap).map { $0.baselineRow - $0.bodyTopRow }
        let match = TypefaceMatcher.match(
            TypefaceMatcher.Input(
                strip: bitmap, scale: scale, caretColumn: caretColumn, baselineRow: 34, text: "Field three alpha bravo charlie x",
                pointSize: 18, bodyRows: bodies, sizeIsReported: true, candidates: TypefaceMatcher.defaultCandidates(pointSize: 18)
            )
        )
        XCTAssertEqual(match?.familyName, "Georgia", "\(String(describing: match))")
        XCTAssertEqual(match?.pointSize ?? 0, 18, accuracy: 0.3)
    }

    /// Obsidian's caret line after a soft wrap holds a few words while the paragraph tail the
    /// caller knows runs back into the previous line; the rendering must be trimmed to the line.
    func testAWrappedLineIsMatchedFromTheWordsActuallyOnIt() {
        let font = NSFont.systemFont(ofSize: 16)
        let onScreen = "ound to a second visual line"
        let (bitmap, caretColumn) = strip(onScreen, font: font, baselineFromTop: 17, dark: true)
        let inkWidth = GhostFontResolver.width(of: onScreen, font: font)
        let bodies = InkBaselineAnalyzer.measure(bitmap).map { $0.baselineRow - $0.bodyTopRow }
        let match = TypefaceMatcher.match(
            TypefaceMatcher.Input(
                strip: bitmap, scale: scale, caretColumn: caretColumn, baselineRow: 34,
                text: "the ghost text is placed when a paragraph wraps around to a second visual line",
                pointSize: 17, bodyRows: bodies, lineInkWidth: inkWidth, candidates: TypefaceMatcher.defaultCandidates(pointSize: 17)
            )
        )
        XCTAssertEqual(match?.familyName, systemFamily, "\(String(describing: match))")
        XCTAssertEqual(match?.pointSize ?? 0, 16, accuracy: 0.35)
        XCTAssertEqual(TypefaceMatcher.fitted("alpha bravo charlie delta", font: font, lineInkWidth: GhostFontResolver.width(of: "charlie delta", font: font)), "charlie delta")
        XCTAssertEqual(TypefaceMatcher.fitted("alpha", font: font, lineInkWidth: 4), "alpha", "the last word always stays")
    }

    /// A capture that reached under Cotabby's own panel carries black columns at its caret end;
    /// they are not glyphs and must not enter the comparison.
    func testBlackedOutColumnsAtTheCaretEndAreIgnored() throws {
        let font = NSFont.systemFont(ofSize: 15)
        let (clean, caretColumn) = strip("Field four alpha bravo charlie", font: font, baselineFromTop: 17)
        var bytes = clean.bytes
        let blackFrom = clean.width - 19
        for row in 0..<clean.height {
            for column in blackFrom..<clean.width {
                let offset = (row * clean.width + column) * 4
                bytes[offset] = 0; bytes[offset + 1] = 0; bytes[offset + 2] = 0; bytes[offset + 3] = 255
            }
        }
        let blacked = RGBABitmap(width: clean.width, height: clean.height, bytes: bytes)
        XCTAssertEqual(InkProfile.trailingOpaqueColumns(of: blacked), 19)
        XCTAssertEqual(InkProfile.trailingOpaqueColumns(of: clean), 0)
        let bodies = InkBaselineAnalyzer.measure(blacked).map { $0.baselineRow - $0.bodyTopRow }
        let match = TypefaceMatcher.match(
            TypefaceMatcher.Input(
                strip: blacked, scale: scale, caretColumn: caretColumn, baselineRow: 34, text: "Field four alpha bravo charlie",
                pointSize: 15, bodyRows: bodies, candidates: TypefaceMatcher.defaultCandidates(pointSize: 15)
            )
        )
        XCTAssertEqual(match?.familyName, systemFamily, "\(String(describing: match))")
    }

    func testTheSizeSearchCoversBothCentres() {
        // The caller's size and the size the letter bodies imply each seed a grid; a hopeless
        // caller size (41.5 for 16px text) still leaves the bodies' grid to find 16.
        let input = TypefaceMatcher.Input(
            strip: RGBABitmap(width: 4, height: 4, bytes: [UInt8](repeating: 255, count: 64)), scale: 2, caretColumn: 3,
            baselineRow: 2, text: "abc", pointSize: 41.5, bodyRows: 24, candidates: []
        )
        let sizes = TypefaceMatcher.searchSizes(input)
        XCTAssertTrue(sizes.contains { abs($0 - 16) < 0.5 }, "\(sizes)")
        XCTAssertTrue(sizes.contains { abs($0 - 41.5) < 0.5 }, "\(sizes)")
        XCTAssertEqual(sizes, sizes.sorted())
    }

    func testAMeasuredSizeKeepsTheSearchToItsNeighbourhoodAndSeedsNoBodyCentre() {
        // The caret's own advance scaled the size to 15.4; a page size 5% away is not this text.
        let input = TypefaceMatcher.Input(
            strip: RGBABitmap(width: 4, height: 4, bytes: [UInt8](repeating: 255, count: 64)), scale: 2, caretColumn: 3,
            baselineRow: 2, text: "abc", pointSize: 15.4, bodyRows: 60, sizeIsMeasured: true, candidates: []
        )
        let sizes = TypefaceMatcher.searchSizes(input)
        XCTAssertTrue(sizes.allSatisfy { $0 >= 14.9 && $0 <= 15.9 }, "\(sizes)")
        XCTAssertFalse(sizes.contains { $0 > 20 }, "the letter bodies seed nothing against a measured size: \(sizes)")
    }

    func testAFaceTheHostShipsIsNotOutrankedByTheSystemFaceOnANearTie() {
        // Claude's composer, 2026-09-10: Anthropic Sans 0.914 against the system face at 0.894.
        let scores = [
            TypefaceMatcher.Score(fontName: "AnthropicSansVariable-TextRegular", familyName: "Anthropic Sans", pointSize: 15.4, score: 0.914),
            TypefaceMatcher.Score(fontName: ".AppleSystemUIFont", familyName: systemFamily, pointSize: 16.15, score: 0.894)
        ]
        XCTAssertEqual(TypefaceMatcher.match(from: scores)?.familyName, systemFamily, "an installed candidate still yields the near tie")
        let hosted = TypefaceMatcher.match(from: scores, hostFontNames: ["AnthropicSansVariable-TextRegular"])
        XCTAssertEqual(hosted?.fontName, "AnthropicSansVariable-TextRegular")
        XCTAssertEqual(hosted?.pointSize, 15.4)
    }

    func testTheSystemFaceWinsANearTie() {
        // Measured in Obsidian (system face host): Arial 0.980, Helvetica 0.975, system 0.969.
        let scores = [
            TypefaceMatcher.Score(fontName: "ArialMT", familyName: "Arial", pointSize: 16.75, score: 0.980),
            TypefaceMatcher.Score(fontName: "Helvetica", familyName: "Helvetica", pointSize: 16.75, score: 0.975),
            TypefaceMatcher.Score(fontName: ".AppleSystemUIFont", familyName: systemFamily, pointSize: 16, score: 0.969)
        ]
        let match = TypefaceMatcher.match(from: scores)
        XCTAssertEqual(match?.familyName, systemFamily)
        XCTAssertEqual(match?.pointSize, 16)

        // A real lead over the system face stands.
        let clear = [
            TypefaceMatcher.Score(fontName: "Georgia", familyName: "Georgia", pointSize: 18, score: 0.99),
            TypefaceMatcher.Score(fontName: ".AppleSystemUIFont", familyName: systemFamily, pointSize: 18, score: 0.60)
        ]
        XCTAssertEqual(TypefaceMatcher.match(from: clear)?.familyName, "Georgia")
    }

    func testTooLittleInkDeclinesRatherThanGuessing() {
        // "Hi th" spans about 35pt at 16pt: whichever face fits it best, that is not evidence.
        XCTAssertNil(match("Hi th", font: NSFont.systemFont(ofSize: 16), dark: true))
    }

    func testLetterBodyDisagreementMarksACandidateDown() {
        XCTAssertEqual(TypefaceMatcher.bodyAgreement(hostRows: 24, candidateRows: 24), 1)
        XCTAssertEqual(TypefaceMatcher.bodyAgreement(hostRows: 24, candidateRows: 25), 1)
        XCTAssertEqual(TypefaceMatcher.bodyAgreement(hostRows: 24, candidateRows: 27), 0.92, accuracy: 0.001)
        XCTAssertEqual(TypefaceMatcher.bodyAgreement(hostRows: 24, candidateRows: 60), TypefaceMatcher.bodyMismatchFloor)
    }

    func testIdentifiesGeorgia() {
        let match = match("Field three alpha bravo charlie x", font: NSFont(name: "Georgia", size: 18)!)
        XCTAssertEqual(match?.familyName, "Georgia", "\(String(describing: match))")
    }

    func testIdentifiesMenloOnADarkField() {
        let match = match("The quick brown fox jumps", font: NSFont(name: "Menlo-Regular", size: 13)!, dark: true)
        XCTAssertEqual(match?.familyName, "Menlo", "\(String(describing: match))")
    }

    func testIdentifiesTheSystemFace() {
        let match = match("Field four alpha bravo charlie", font: NSFont.systemFont(ofSize: 15))
        XCTAssertEqual(match?.familyName, NSFont.systemFont(ofSize: 15).familyName, "\(String(describing: match))")
    }

    func testDoesNotConfuseHelveticaWithGeorgia() {
        let match = match("Field two alpha bravo charlie x", font: NSFont(name: "Helvetica", size: 16)!)
        XCTAssertNotEqual(match?.familyName, "Georgia")
        XCTAssertNotEqual(match?.familyName, "Menlo")
    }

    func testOnlyTheLineTailOnScreenStillMatchesOrDeclines() {
        // The caret sits shortly after a soft wrap: the strip shows only "charlie x" although the
        // paragraph text before the caret is longer. A wrong face is worse than no answer.
        let (bitmap, caretColumn) = strip("charlie x", font: NSFont(name: "Georgia", size: 18)!, baselineFromTop: 17)
        let match = TypefaceMatcher.match(
            TypefaceMatcher.Input(
                strip: bitmap, scale: scale, caretColumn: caretColumn, baselineRow: 34,
                text: "Field three alpha bravo charlie x", pointSize: 18,
                candidates: TypefaceMatcher.defaultCandidates(pointSize: 18)
            )
        )
        if let match {
            XCTAssertEqual(match.familyName, "Georgia")
        }
    }

    /// The production strip stops two points short of the caret, so the caret column lies beyond the
    /// bitmap's right edge. This crashed the app once (index out of range); it must simply work.
    func testCaretColumnBeyondTheStripIsHandled() {
        let font = NSFont(name: "Georgia", size: 18)!
        let (bitmap, _) = strip("Field three alpha bravo charlie x", font: font, baselineFromTop: 17)
        let match = TypefaceMatcher.match(
            TypefaceMatcher.Input(
                strip: bitmap, scale: scale, caretColumn: CGFloat(bitmap.width) + 4, baselineRow: 34,
                text: "Field three alpha bravo charlie x", pointSize: 18,
                candidates: TypefaceMatcher.defaultCandidates(pointSize: 18)
            )
        )
        // The rendering is 6pt further right than the strip's text, so the face may or may not be
        // recovered; only a wrong answer would be a failure.
        if let match {
            XCTAssertEqual(match.familyName, "Georgia")
        }
    }

    func testLineTailStopsAtHardBreaksAndIsBounded() {
        XCTAssertEqual(HostLineText.tail(of: "first line\nsecond line here"), "second line here")
        XCTAssertEqual(HostLineText.tail(of: String(repeating: "a", count: 100)).count, HostLineText.maximumLength)
    }
}
