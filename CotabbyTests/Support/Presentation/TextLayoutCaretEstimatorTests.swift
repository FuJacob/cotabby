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
        prefixMayBeTruncated: Bool = false,
        observedLineHeight: CGFloat? = nil,
        observedCharWidth: CGFloat? = nil,
        observedContentEdges: ObservedContentEdges? = nil
    ) -> TextLayoutCaretEstimator.Input {
        TextLayoutCaretEstimator.Input(
            precedingText: prefix,
            fieldFrame: frame,
            fieldStyle: style,
            isRightToLeft: isRightToLeft,
            prefixMayBeTruncated: prefixMayBeTruncated,
            observedLineHeight: observedLineHeight,
            observedCharWidth: observedCharWidth,
            observedContentEdges: observedContentEdges
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

    // MARK: - Host-measured calibrations

    func test_estimate_observedLineHeightDrivesPerLineSpacing() throws {
        // Web hosts render with CSS line-height well above font metrics; per-line error compounds
        // into whole-line drift, so a measured line box must pin the layout's vertical rhythm.
        let frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        let observed: CGFloat = 24
        let estimate = try XCTUnwrap(
            acceptedEstimate(for: makeInput(prefix: "hello\nworld", frame: frame, observedLineHeight: observed))
        )

        XCTAssertTrue(estimate.usedObservedLineHeight)
        XCTAssertEqual(estimate.lineHeight, observed)
        XCTAssertEqual(estimate.lineIndex, 1)
        XCTAssertEqual(estimate.caretRect.height, observed, accuracy: 0.01)
        // Caret line sits exactly one observed line box below the top line.
        XCTAssertEqual(estimate.caretRect.maxY, frame.maxY - topInset - observed, accuracy: 0.6)
    }

    func test_estimate_junkObservedLineHeightFallsBackToFontMetrics() throws {
        // A whole-field rect height (the `.estimated` AXFrame shape) must not be mistaken for a
        // line box.
        let frame = CGRect(x: 0, y: 0, width: 300, height: 200)
        let estimate = try XCTUnwrap(
            acceptedEstimate(for: makeInput(prefix: "hello", frame: frame, observedLineHeight: 200))
        )

        XCTAssertFalse(estimate.usedObservedLineHeight)
        XCTAssertEqual(estimate.lineHeight, systemLineHeight, accuracy: 0.01)
    }

    func test_estimate_observedCharWidthRescalesLayoutFont() throws {
        // The host's measured average character width calibrates wrap fidelity: a wider host font
        // must widen the layout font (larger x for the same prefix), a narrower one must shrink it.
        let frame = CGRect(x: 0, y: 0, width: 400, height: 24)
        let baseline = try XCTUnwrap(acceptedEstimate(for: makeInput(prefix: "Hello", frame: frame)))
        let wide = try XCTUnwrap(
            acceptedEstimate(for: makeInput(prefix: "Hello", frame: frame, observedCharWidth: 20))
        )
        let narrow = try XCTUnwrap(
            acceptedEstimate(for: makeInput(prefix: "Hello", frame: frame, observedCharWidth: 1))
        )

        XCTAssertGreaterThan(wide.layoutFontPointSize, baseline.layoutFontPointSize)
        XCTAssertGreaterThan(wide.caretRect.minX, baseline.caretRect.minX)
        XCTAssertLessThan(narrow.layoutFontPointSize, baseline.layoutFontPointSize)
        XCTAssertLessThan(narrow.caretRect.minX, baseline.caretRect.minX)
    }

    func test_estimate_observedContentEdgesReplaceGuessedInsets() throws {
        // Measured run edges reveal the field's real padding, which AXFrame hides.
        let frame = CGRect(x: 100, y: 100, width: 300, height: 100)
        let edges = ObservedContentEdges(leftX: 112, topY: 190)
        let estimate = try XCTUnwrap(
            acceptedEstimate(for: makeInput(prefix: "", frame: frame, observedContentEdges: edges))
        )

        XCTAssertTrue(estimate.usedObservedContentEdges)
        XCTAssertEqual(estimate.caretRect.minX, 112, accuracy: 0.01)
        XCTAssertEqual(estimate.caretRect.maxY, 190, accuracy: 0.01)
    }

    func test_estimate_absurdContentEdgesFallBackToDefaultInsets() throws {
        // A heavily indented first run (quote, list) or an offscreen top edge is not padding.
        let frame = CGRect(x: 100, y: 100, width: 300, height: 100)
        let edges = ObservedContentEdges(leftX: 100 + 200, topY: 110)
        let estimate = try XCTUnwrap(
            acceptedEstimate(for: makeInput(prefix: "", frame: frame, observedContentEdges: edges))
        )

        XCTAssertFalse(estimate.usedObservedContentEdges)
        XCTAssertEqual(estimate.caretRect.minX, frame.minX + horizontalInset, accuracy: 0.01)
        XCTAssertEqual(estimate.caretRect.maxY, frame.maxY - topInset, accuracy: 0.01)
    }

    func test_estimate_observedCharWidthWithinTwoPercentDoesNotRescaleFont() throws {
        // The width calibration has a 2% dead band: an observed average that close to the layout
        // font's own average is measurement noise, and rescaling on it would jitter the font size
        // every present. Mirrors the estimator's width-sample constant on purpose so this breaks
        // loudly if the calibration sample changes.
        let sample = "the quick brown fox jumps over the lazy dog, The Quick 0123456789. " as NSString
        let menlo = try XCTUnwrap(NSFont(name: "Menlo-Regular", size: 16))
        let sampleAverage = sample.size(withAttributes: [.font: menlo]).width / CGFloat(sample.length)

        let estimate = try XCTUnwrap(
            acceptedEstimate(for: makeInput(
                prefix: "Hello",
                frame: CGRect(x: 0, y: 0, width: 400, height: 24),
                style: ResolvedFieldStyle(fontName: "Menlo-Regular", fontPointSize: 16, colorHex: nil),
                observedCharWidth: sampleAverage * 1.015
            ))
        )

        // Without the dead band the layout font would become 16 * 1.015 = 16.24pt.
        XCTAssertEqual(estimate.layoutFontPointSize, 16)
    }

    func test_estimate_rightToLeftTrailingNewlineAnchorsCaretAtTrailingEdge() throws {
        // After a hard line break in an RTL editor the insertion point sits at the line's leading
        // edge, which is the field's right side; the empty new line must not snap the caret to the
        // left edge the way LTR does.
        let frame = CGRect(x: 100, y: 100, width: 300, height: 200)
        let estimate = try XCTUnwrap(
            acceptedEstimate(for: makeInput(prefix: "שלום\n", frame: frame, isRightToLeft: true))
        )

        XCTAssertEqual(estimate.lineIndex, 1)
        XCTAssertEqual(estimate.caretRect.minX, frame.maxX - horizontalInset, accuracy: 0.01)
    }

    // MARK: - Memoization

    func test_estimate_repeatedIdenticalInputReturnsIdenticalOutcome() {
        // Reconcile ticks re-present byte-identical inputs several times per second; the memo must
        // return the exact same outcome for them (and the second call exercises the cached path).
        let input = makeInput(
            prefix: "memo probe text",
            frame: CGRect(x: 0, y: 0, width: 300, height: 24)
        )

        let first = TextLayoutCaretEstimator.estimate(for: input)
        let second = TextLayoutCaretEstimator.estimate(for: input)

        XCTAssertEqual(first, second)
        guard case .estimate = first else {
            XCTFail("Expected the probe input to produce an accepted estimate")
            return
        }
    }

    func test_estimate_measuredTopIgnoredWhenPrefixStartsWithLineBreak() throws {
        // The topmost run is the first *rendered* text; leading blank lines sit above it, so the
        // measured top edge would anchor the layout one line too high per blank.
        let frame = CGRect(x: 100, y: 100, width: 300, height: 100)
        let edges = ObservedContentEdges(leftX: 112, topY: 190)
        let estimate = try XCTUnwrap(
            acceptedEstimate(for: makeInput(prefix: "\nhi", frame: frame, observedContentEdges: edges))
        )

        // Left calibration still applies; top falls back to the default inset.
        XCTAssertEqual(estimate.lineIndex, 1)
        XCTAssertEqual(
            estimate.caretRect.maxY,
            frame.maxY - topInset - estimate.caretRect.height,
            accuracy: 0.6
        )
    }
}
