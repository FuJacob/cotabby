import AppKit
import XCTest
@testable import Cotabby

/// The fit is exercised on carets generated the way a host lays out text: the line's start plus
/// the face's advance at the host's size, whole-pixel noise on every read, and the reads that catch
/// the host a glyph late, as captures of Claude's composer did (2026-09-11: five of 23 were 3pt off).
final class HostAdvanceFitTests: XCTestCase {
    private let sentence = "There are still a lot of problems, a LOT of problems with positioning, size, etc. Keep on going"
    private let lineStart: CGFloat = 339.3

    /// Carets for every prefix ending in a letter, from `from` characters on, as the host at
    /// `hostSize` places them; every `outlierEvery`-th read lands `outlier` points off.
    private func captures(hostSize: CGFloat, from: Int = 20, to: Int? = nil, outlierEvery: Int = 5, outlier: CGFloat = 3) -> [HostAdvanceFit.Capture] {
        let host = NSFont(name: "Helvetica", size: hostSize)!
        let characters = Array(sentence)
        var result: [HostAdvanceFit.Capture] = []
        for count in from...(to ?? characters.count) where characters[count - 1].isLetter {
            let text = String(characters[0..<count])
            let noise = CGFloat((count * 37) % 5 - 2) * 0.1   // within a quarter point either way
            let late = result.count % outlierEvery == outlierEvery - 1 ? outlier : 0
            result.append(.init(text: text, caretX: lineStart + GhostFontResolver.width(of: text, font: host) + noise + late))
        }
        return result
    }

    func testTheCaretsSlopeIsTheHostsSize() throws {
        let face = try XCTUnwrap(NSFont(name: "Helvetica", size: 15.1585))
        let fit = try XCTUnwrap(HostAdvanceFit.fit(captures(hostSize: 15.336), face: face))
        XCTAssertEqual(fit.pointSize, 15.336, accuracy: 0.02, "the size the host paints, not the face's")
        XCTAssertGreaterThan(fit.span, 400)
    }

    /// A least-squares line through the same reads is pulled by the late ones; the median slope is not.
    func testReadsOffByAGlyphDoNotBendTheFit() throws {
        let face = try XCTUnwrap(NSFont(name: "Helvetica", size: 15.336))
        let fit = try XCTUnwrap(HostAdvanceFit.fit(captures(hostSize: 15.336, outlierEvery: 4, outlier: 6), face: face))
        XCTAssertEqual(fit.pointSize, 15.336, accuracy: 0.03)
    }

    func testTooShortALineGivesNoFit() throws {
        let face = try XCTUnwrap(NSFont(name: "Helvetica", size: 15.336))
        // Up to "a lot of": about 60pt of advance.
        XCTAssertNil(HostAdvanceFit.fit(captures(hostSize: 15.336, from: 5, to: 24), face: face))
    }

    /// The first fit long enough is adopted and held; one twice as long refines it, and the number
    /// of refinements is bounded, so the ghost is not resized on every capture.
    func testAdoptionHoldsUntilTheSpanDoubles() throws {
        let face = try XCTUnwrap(NSFont(name: "Helvetica", size: 15.1585))
        var fit = HostAdvanceFit()
        var adoptions: [HostAdvanceFit.Fit] = []
        for capture in captures(hostSize: 15.336, from: 4) {
            if let adopted = fit.record(text: capture.text, caretX: capture.caretX, lineKey: "line", face: face) {
                adoptions.append(adopted)
            }
        }
        XCTAssertFalse(adoptions.isEmpty)
        XCTAssertLessThanOrEqual(adoptions.count, 1 + HostAdvanceFit.maximumRefinements)
        for (earlier, later) in zip(adoptions, adoptions.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later.span, earlier.span * HostAdvanceFit.refinementFactor)
        }
        XCTAssertEqual(try XCTUnwrap(fit.adopted).pointSize, 15.336, accuracy: 0.03)
    }

    /// A new line keeps what was adopted but collects its own captures (its start is its own); a new
    /// face starts the field over.
    func testANewLineKeepsTheFitAndANewFaceDropsIt() throws {
        let face = try XCTUnwrap(NSFont(name: "Helvetica", size: 15.1585))
        var fit = HostAdvanceFit()
        for capture in captures(hostSize: 15.336) {
            _ = fit.record(text: capture.text, caretX: capture.caretX, lineKey: "first", face: face)
        }
        let adopted = try XCTUnwrap(fit.adopted)
        _ = fit.record(text: "Second", caretX: 400, lineKey: "second", face: face)
        XCTAssertEqual(fit.adopted, adopted)
        XCTAssertEqual(fit.captures.count, 1)
        let other = try XCTUnwrap(NSFont(name: "Georgia", size: 15.1585))
        _ = fit.record(text: "Second", caretX: 400, lineKey: "second", face: other)
        XCTAssertNil(fit.adopted)
    }

    /// Captures that do not describe this face at anything near its size (another line's, a
    /// different face's) are refused rather than adopted.
    func testAFitFarFromTheFacesSizeIsRefused() throws {
        let face = try XCTUnwrap(NSFont(name: "Helvetica", size: 12))
        var fit = HostAdvanceFit()
        for capture in captures(hostSize: 15.336) {
            _ = fit.record(text: capture.text, caretX: capture.caretX, lineKey: "line", face: face)
        }
        XCTAssertNil(fit.adopted)
    }

    /// Chrome's address bar (2026-09-11): its queries are short, and its caret-derived ghost at 15.5
    /// ran 7% large where the caret's advance along each of five queries fitted 14.48 to 14.58.
    /// Captures along a query of about 80pt fit nothing at a paragraph line's span, and the host's
    /// size at a single-line field's.
    func testASingleLineFieldFitsFromAShorterSpan() throws {
        let face = NSFont.systemFont(ofSize: 15.5)
        let host = NSFont.systemFont(ofSize: 14.51)
        let query = "nothing ear 3 find"
        let captures = stride(from: 8, through: query.count, by: 2).map { count -> HostAdvanceFit.Capture in
            let text = String(query.prefix(count))
            return HostAdvanceFit.Capture(text: text, caretX: 279 + GhostFontResolver.width(of: text, font: host))
        }
        XCTAssertNil(HostAdvanceFit.fit(captures, face: face), "the query spans less than a paragraph line's fit needs")
        let fit = try XCTUnwrap(HostAdvanceFit.fit(captures, face: face, minimumSpan: HostAdvanceFit.singleLineMinimumSpan))
        XCTAssertEqual(fit.pointSize, 14.51, accuracy: 0.15)
    }
}
