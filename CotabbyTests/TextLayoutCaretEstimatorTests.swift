import AppKit
import XCTest
@testable import Cotabby

/// Locks down the hidden-TextKit caret estimator: coordinate mapping for single- and multi-line
/// fields, soft-wrap behavior, and — most importantly — the conservative gates that must reject
/// any layout that could lie about the real field (scrolled content, truncated context window,
/// host-defined tab stops).
@MainActor
final class TextLayoutCaretEstimatorTests: XCTestCase {
    private let systemFont = NSFont.systemFont(ofSize: NSFont.systemFontSize)

    private var systemLineHeight: CGFloat {
        ceil(systemFont.ascender - systemFont.descender + systemFont.leading)
    }

    /// Mirrors the estimator's generalized content insets. Hardcoded on purpose: moving the
    /// production constant should be a deliberate, test-visible decision, not a silent drift.
    private let horizontalInset: CGFloat = 4
    private let topInset: CGFloat = 4

    private func makeInput(
        prefix: String = "",
        frame: CGRect? = CGRect(x: 100, y: 100, width: 300, height: 24),
        style: ResolvedFieldStyle? = nil,
        isRightToLeft: Bool = false,
        prefixMayBeTruncated: Bool = false
    ) -> TextLayoutCaretEstimator.Input {
        TextLayoutCaretEstimator.Input(
            precedingText: prefix,
            fieldFrame: frame,
            fieldStyle: style,
            isRightToLeft: isRightToLeft,
            prefixMayBeTruncated: prefixMayBeTruncated
        )
    }

    private func acceptedEstimate(
        for input: TextLayoutCaretEstimator.Input
    ) -> TextLayoutCaretEstimator.Estimate? {
        guard case .estimate(let estimate) = TextLayoutCaretEstimator.estimate(for: input) else {
            return nil
        }
        return estimate
    }

    private func measuredWidth(_ text: String, font: NSFont? = nil) -> CGFloat {
        (text as NSString).size(withAttributes: [.font: font ?? systemFont]).width
    }

    // MARK: - Anchoring

    func test_estimate_emptyPrefixAnchorsAtContentOriginOfSingleLineField() throws {
        let frame = CGRect(x: 100, y: 100, width: 300, height: 24)
        let estimate = try XCTUnwrap(acceptedEstimate(for: makeInput(prefix: "", frame: frame)))

        XCTAssertFalse(estimate.isMultiLineField)
        XCTAssertEqual(estimate.lineIndex, 0)
        XCTAssertEqual(estimate.caretRect.minX, frame.minX + horizontalInset, accuracy: 0.01)
        // Single-line fields center their one line vertically.
        XCTAssertEqual(estimate.caretRect.midY, frame.midY, accuracy: 0.5)
        XCTAssertEqual(estimate.lineHeight, systemLineHeight, accuracy: 0.01)
    }

    func test_estimate_singleLineCaretTracksMeasuredPrefixWidth() throws {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 24)
        let short = try XCTUnwrap(acceptedEstimate(for: makeInput(prefix: "Hello", frame: frame)))
        let long = try XCTUnwrap(acceptedEstimate(for: makeInput(prefix: "Hello world", frame: frame)))

        // TextKit advances and NSString sizing share the same text system; small kerning-level
        // differences are tolerated, line-level drift is not.
        XCTAssertEqual(
            short.caretRect.minX,
            frame.minX + horizontalInset + measuredWidth("Hello"),
            accuracy: 1.5
        )
        XCTAssertEqual(
            long.caretRect.minX,
            frame.minX + horizontalInset + measuredWidth("Hello world"),
            accuracy: 1.5
        )
        XCTAssertGreaterThan(long.caretRect.minX, short.caretRect.minX)
    }

    func test_estimate_multiLineWrapDescendsOneLinePerWrap() throws {
        let frame = CGRect(x: 50, y: 300, width: 150, height: 200)
        let topLine = try XCTUnwrap(acceptedEstimate(for: makeInput(prefix: "hi", frame: frame)))

        XCTAssertTrue(topLine.isMultiLineField)
        XCTAssertEqual(topLine.lineIndex, 0)
        // Multi-line content is top-aligned: the first line hangs from the field's top inset.
        XCTAssertEqual(topLine.caretRect.maxY, frame.maxY - topInset, accuracy: 0.01)

        let wrappedPrefix = String(repeating: "word ", count: 12)
        let wrapped = try XCTUnwrap(acceptedEstimate(for: makeInput(prefix: wrappedPrefix, frame: frame)))
        XCTAssertGreaterThanOrEqual(wrapped.lineIndex, 1)
        // Same font everywhere, so line fragments are uniform: the caret descends exactly one
        // fragment height per visual line.
        let fragmentHeight = topLine.caretRect.height
        XCTAssertEqual(
            wrapped.caretRect.maxY,
            frame.maxY - topInset - CGFloat(wrapped.lineIndex) * fragmentHeight,
            accuracy: 1.0
        )
    }

    func test_estimate_trailingNewlineMovesCaretToStartOfNextLine() throws {
        let frame = CGRect(x: 50, y: 300, width: 200, height: 120)
        let beforeBreak = try XCTUnwrap(acceptedEstimate(for: makeInput(prefix: "hello", frame: frame)))
        let afterBreak = try XCTUnwrap(acceptedEstimate(for: makeInput(prefix: "hello\n", frame: frame)))

        XCTAssertEqual(afterBreak.lineIndex, 1)
        XCTAssertEqual(afterBreak.caretRect.minX, frame.minX + horizontalInset, accuracy: 0.01)
        XCTAssertLessThan(afterBreak.caretRect.maxY, beforeBreak.caretRect.maxY)
    }

    func test_estimate_trailingHangingSpaceClampsInsteadOfRejecting() throws {
        // Field sized so the word fits but trailing spaces hang past the wrap boundary — the
        // single most common suggestion trigger position ("word ") must clamp, never bail.
        let core = "wwwwwwwwww"
        let frameWidth = measuredWidth(core) + 2 * horizontalInset + 6
        let frame = CGRect(x: 0, y: 0, width: frameWidth, height: 24)
        let estimate = try XCTUnwrap(acceptedEstimate(for: makeInput(prefix: core + "   ", frame: frame)))

        XCTAssertEqual(estimate.lineIndex, 0)
        XCTAssertLessThanOrEqual(estimate.caretRect.minX, frame.maxX - horizontalInset + 0.01)
    }

    func test_estimate_fieldHeightAtTwoLineHeightsSelectsMultiLineTopAlignment() throws {
        let lineHeight = systemLineHeight
        let shortFrame = CGRect(x: 100, y: 100, width: 300, height: 2 * lineHeight - 1)
        let tallFrame = CGRect(x: 100, y: 100, width: 300, height: 2 * lineHeight + 1)

        let centered = try XCTUnwrap(acceptedEstimate(for: makeInput(prefix: "hi", frame: shortFrame)))
        XCTAssertFalse(centered.isMultiLineField)
        XCTAssertEqual(centered.caretRect.midY, shortFrame.midY, accuracy: 0.5)

        let topAligned = try XCTUnwrap(acceptedEstimate(for: makeInput(prefix: "hi", frame: tallFrame)))
        XCTAssertTrue(topAligned.isMultiLineField)
        XCTAssertEqual(topAligned.caretRect.maxY, tallFrame.maxY - topInset, accuracy: 0.01)
    }

    // MARK: - Right-to-left

    func test_estimate_rightToLeftAnchorsAtTrailingEdgeAndAdvancesLeftward() throws {
        let frame = CGRect(x: 100, y: 100, width: 300, height: 24)
        let empty = try XCTUnwrap(
            acceptedEstimate(for: makeInput(prefix: "", frame: frame, isRightToLeft: true))
        )
        XCTAssertEqual(empty.caretRect.minX, frame.maxX - horizontalInset, accuracy: 0.01)

        let short = try XCTUnwrap(
            acceptedEstimate(for: makeInput(prefix: "שלום", frame: frame, isRightToLeft: true))
        )
        let long = try XCTUnwrap(
            acceptedEstimate(for: makeInput(prefix: "שלום עולם", frame: frame, isRightToLeft: true))
        )
        XCTAssertLessThan(short.caretRect.minX, frame.maxX - horizontalInset)
        XCTAssertLessThan(long.caretRect.minX, short.caretRect.minX)
    }

    // MARK: - Font approximation

    func test_estimate_usesResolvedFieldStyleFontForWidthAndLineHeight() throws {
        let frame = CGRect(x: 0, y: 0, width: 400, height: 60)
        let menloStyle = ResolvedFieldStyle(fontName: "Menlo-Regular", fontPointSize: 16, colorHex: nil)
        let styled = try XCTUnwrap(
            acceptedEstimate(for: makeInput(prefix: "Hello", frame: frame, style: menloStyle))
        )
        let fallback = try XCTUnwrap(acceptedEstimate(for: makeInput(prefix: "Hello", frame: frame)))

        let menloFont = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 16))
        XCTAssertEqual(
            styled.lineHeight,
            ceil(menloFont.ascender - menloFont.descender + menloFont.leading),
            accuracy: 0.01
        )
        XCTAssertEqual(
            styled.caretRect.minX,
            frame.minX + horizontalInset + measuredWidth("Hello", font: menloFont),
            accuracy: 1.5
        )
        XCTAssertNotEqual(styled.caretRect.minX, fallback.caretRect.minX)
    }

    func test_estimate_fallsBackToSystemFontWhenStyleFontUnresolvable() {
        let frame = CGRect(x: 0, y: 0, width: 300, height: 24)
        let bogusStyle = ResolvedFieldStyle(fontName: "NoSuchFont-Imaginary", fontPointSize: nil, colorHex: nil)
        let styled = TextLayoutCaretEstimator.estimate(for: makeInput(prefix: "Hello", frame: frame, style: bogusStyle))
        let plain = TextLayoutCaretEstimator.estimate(for: makeInput(prefix: "Hello", frame: frame))

        XCTAssertEqual(styled, plain)
    }

    // MARK: - Trust gates

    func test_estimate_rejectsWhenPrefixMayBeTruncated() {
        let outcome = TextLayoutCaretEstimator.estimate(
            for: makeInput(prefix: "hello", prefixMayBeTruncated: true)
        )
        XCTAssertEqual(outcome, .rejected(.prefixTruncated))
    }

    func test_estimate_rejectsWhenLaidOutTextOverflowsFieldHeight() {
        // Twelve hard lines cannot fit a 40pt field, so the field is scrolled by an amount we
        // cannot observe — the caret's on-screen Y would be a guess.
        let frame = CGRect(x: 0, y: 0, width: 200, height: 40)
        let prefix = Array(repeating: "line", count: 12).joined(separator: "\n")
        let outcome = TextLayoutCaretEstimator.estimate(for: makeInput(prefix: prefix, frame: frame))

        XCTAssertEqual(outcome, .rejected(.verticalOverflow))
    }

    func test_estimate_rejectsSingleLinePrefixWiderThanField() {
        // A single-line field never wraps for real; a prefix wider than the field means the host
        // scrolled horizontally and the visible caret offset is unknowable.
        let frame = CGRect(x: 0, y: 0, width: 120, height: 24)
        let outcome = TextLayoutCaretEstimator.estimate(
            for: makeInput(prefix: String(repeating: "m", count: 40), frame: frame)
        )

        XCTAssertEqual(outcome, .rejected(.horizontalOverflow))
    }

    func test_estimate_rejectsNewlinePrefixInSingleLineField() {
        let frame = CGRect(x: 0, y: 0, width: 200, height: 24)
        let outcome = TextLayoutCaretEstimator.estimate(for: makeInput(prefix: "a\nb", frame: frame))

        XCTAssertEqual(outcome, .rejected(.horizontalOverflow))
    }

    func test_estimate_rejectsTabCharacters() {
        let outcome = TextLayoutCaretEstimator.estimate(for: makeInput(prefix: "column\tvalue"))

        XCTAssertEqual(outcome, .rejected(.containsTab))
    }

    func test_estimate_rejectsMissingEmptyOrTinyFieldFrame() {
        XCTAssertEqual(
            TextLayoutCaretEstimator.estimate(for: makeInput(prefix: "hello", frame: nil)),
            .rejected(.fieldFrameUnusable)
        )
        XCTAssertEqual(
            TextLayoutCaretEstimator.estimate(for: makeInput(prefix: "hello", frame: .zero)),
            .rejected(.fieldFrameUnusable)
        )
        XCTAssertEqual(
            TextLayoutCaretEstimator.estimate(
                for: makeInput(prefix: "hello", frame: CGRect(x: 0, y: 0, width: 30, height: 24))
            ),
            .rejected(.fieldFrameUnusable)
        )
    }
}
