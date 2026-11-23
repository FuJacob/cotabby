import CoreGraphics
import Foundation
import XCTest
@testable import Cotabby

/// Tests for the pure focus value models: diagnostic labels, capability summaries, content-edge
/// provenance, snapshot identity and truncation signals, and resolved field style emptiness.
final class FocusModelsTests: XCTestCase {
    func test_resolvedFieldStyle_isEmptyWhenNoRenderableAttributeIsPresent() {
        let empty = ResolvedFieldStyle(fontName: nil, fontPointSize: nil, colorHex: nil)
        XCTAssertTrue(empty.isEmpty)

        let fontOnly = ResolvedFieldStyle(fontName: "Helvetica", fontPointSize: nil, colorHex: nil)
        XCTAssertFalse(fontOnly.isEmpty)

        let colorOnly = ResolvedFieldStyle(fontName: nil, fontPointSize: nil, colorHex: "336699")
        XCTAssertFalse(colorOnly.isEmpty)
    }

    func test_resolvedFieldStyle_pointSizeAloneIsARenderableStyle() {
        // Chromium reports only the size. That is the single most important fact for matching the
        // host's rendering, so a size-only style must survive to the font resolver.
        let style = ResolvedFieldStyle(fontName: nil, fontPointSize: 13, colorHex: nil)
        XCTAssertFalse(style.isEmpty)
        XCTAssertTrue(ResolvedFieldStyle(fontName: nil, fontPointSize: nil, colorHex: nil).isEmpty)
        XCTAssertFalse(ResolvedFieldStyle(fontName: nil, fontFamily: "Georgia", fontPointSize: nil, colorHex: nil).isEmpty)
    }

    func test_caretGeometryQuality_labelsAreStableLogIdentifiers() {
        let expectations: [(quality: CaretGeometryQuality, label: String)] = [
            (.exact, "exact"),
            (.derived, "derived"),
            (.estimated, "estimated"),
            (.layoutEstimated, "layout-estimated")
        ]

        for expectation in expectations {
            XCTAssertEqual(expectation.quality.label, expectation.label)
        }
    }

    func test_focusCapability_shortLabelIsCompactWhileSummaryCarriesTheReason() {
        XCTAssertEqual(FocusCapability.supported.shortLabel, "Supported")
        XCTAssertEqual(FocusCapability.supported.summary, "Supported")
        XCTAssertEqual(FocusCapability.blocked("Secure field").shortLabel, "Blocked")
        XCTAssertEqual(FocusCapability.blocked("Secure field").summary, "Secure field")
        XCTAssertEqual(FocusCapability.unsupported("Missing caret bounds.").shortLabel, "Unsupported")
        XCTAssertEqual(FocusCapability.unsupported("Missing caret bounds.").summary, "Missing caret bounds.")
    }

    func test_observedContentEdges_defaultToUntrustedAndLineQueryMarginCarriesNoTop() {
        // Run-measured trust must be opted into; a new edge source must not inherit it by default.
        XCTAssertFalse(ObservedContentEdges(leftX: 10, topY: 40).isRunMeasured)

        let margin = ObservedContentEdges.lineQueryMargin(leftX: 72)
        XCTAssertEqual(margin, ObservedContentEdges(leftX: 72, topY: nil, isRunMeasured: false))
    }

    func test_lineContentEdgesOutcome_publishesEdgesOnlyWhenMeasured() {
        let edges = ObservedContentEdges.lineQueryMargin(leftX: 72)
        let measured = LineContentEdgesOutcome.measured(
            LineContentEdgesMeasurement(
                edges: edges,
                lineRect: CGRect(x: 72, y: 100, width: 400, height: 18),
                isParagraphFirstLine: false,
                caretLocation: 12
            )
        )

        XCTAssertEqual(measured.edges, edges)
        XCTAssertNil(LineContentEdgesOutcome.emptyLine(caretLocation: 12).edges)
        XCTAssertNil(LineContentEdgesOutcome.unavailable.edges)
    }

    func test_focusedInputSnapshot_identityPairsElementWithFocusSequence() {
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot(elementIdentifier: "field-a", focusChangeSequence: 4)

        XCTAssertEqual(snapshot.identity, FocusedInputIdentity(elementIdentifier: "field-a", focusChangeSequence: 4))
    }

    /// The surface facts are re-read from the host on every poll under a short AX timeout, so a
    /// live identity can carry a nil where the session's base identity has a value. That is an
    /// unreadable fact, not a navigation; only two known, different values are.
    func test_sessionIdentity_continuesAcrossUnreadableSurfaceFactsButNotAcrossChangedOnes() {
        // The window title only identifies a session when no URL does (see `identifyingWindowTitle`),
        // so title cases use a URL-less native field and URL/placeholder cases a URL-bearing one.
        let titled = CotabbyTestFixtures.focusedInputSnapshot(windowTitle: "Chat one", fieldPlaceholder: "Message")
            .sessionIdentity
        let located = CotabbyTestFixtures.focusedInputSnapshot(
            focusedURLString: "https://chat.example/one", fieldPlaceholder: "Message"
        ).sessionIdentity

        let unreadable: [(String, FocusedInputSnapshot, FocusedInputSessionIdentity)] = [
            ("title timed out", CotabbyTestFixtures.focusedInputSnapshot(fieldPlaceholder: "Message"), titled),
            ("url timed out", CotabbyTestFixtures.focusedInputSnapshot(fieldPlaceholder: "Message"), located),
            ("every fact timed out", CotabbyTestFixtures.focusedInputSnapshot(), titled),
            ("every fact timed out", CotabbyTestFixtures.focusedInputSnapshot(), located)
        ]
        for (label, live, base) in unreadable {
            XCTAssertTrue(live.sessionIdentity.continues(base), label)
            XCTAssertNotEqual(live.sessionIdentity, base, "\(label): equality is deliberately stricter")
            // A base captured during an unreadable poll must also accept the later known value.
            XCTAssertTrue(base.continues(live.sessionIdentity), "\(label): the fact coming back")
        }

        let navigated: [(String, FocusedInputSnapshot, FocusedInputSessionIdentity)] = [
            ("new title", CotabbyTestFixtures.focusedInputSnapshot(
                windowTitle: "Chat two", fieldPlaceholder: "Message"), titled),
            ("new url", CotabbyTestFixtures.focusedInputSnapshot(
                focusedURLString: "https://chat.example/two", fieldPlaceholder: "Message"), located),
            ("new focus sequence", CotabbyTestFixtures.focusedInputSnapshot(
                focusChangeSequence: 2, focusedURLString: "https://chat.example/one", fieldPlaceholder: "Message"),
             located),
            ("other process", CotabbyTestFixtures.focusedInputSnapshot(
                processIdentifier: 456, focusedURLString: "https://chat.example/one", fieldPlaceholder: "Message"),
             located)
        ]
        for (label, live, base) in navigated {
            XCTAssertFalse(live.sessionIdentity.continues(base), label)
        }
        // The placeholder is not a session fact: hosts hide it while the field has text. A different
        // placeholder reaches consumers as a new focus sequence from the polling signature instead.
        XCTAssertEqual(
            CotabbyTestFixtures.focusedInputSnapshot(focusedURLString: "https://chat.example/one", fieldPlaceholder: "Reply")
                .sessionIdentity,
            located
        )
    }

    func test_focusedInputSnapshot_flagsPossibleTruncationAtTheCaptureWindow() {
        let window = FocusedInputSnapshot.textWindowUTF16
        let underWindow = String(repeating: "a", count: window - 1)
        let atWindow = String(repeating: "a", count: window)

        XCTAssertFalse(CotabbyTestFixtures.focusedInputSnapshot(precedingText: underWindow).precedingTextMayBeTruncated)
        XCTAssertTrue(CotabbyTestFixtures.focusedInputSnapshot(precedingText: atWindow).precedingTextMayBeTruncated)
        // The window is measured in UTF-16 units, so a surrogate-pair emoji counts twice.
        let emojiAtWindow = String(repeating: "\u{1F600}", count: window / 2)
        XCTAssertTrue(CotabbyTestFixtures.focusedInputSnapshot(precedingText: emojiAtWindow).precedingTextMayBeTruncated)

        XCTAssertFalse(CotabbyTestFixtures.focusedInputSnapshot(trailingText: underWindow).trailingTextMayBeTruncated)
        XCTAssertTrue(CotabbyTestFixtures.focusedInputSnapshot(trailingText: atWindow).trailingTextMayBeTruncated)
        XCTAssertFalse(CotabbyTestFixtures.focusedInputSnapshot(precedingText: atWindow).trailingTextMayBeTruncated)
        // An empty trailing text the host never delivered is unknown, not the end of the field.
        XCTAssertTrue(CotabbyTestFixtures.focusedInputSnapshot(trailingTextUnavailable: true).trailingTextMayBeTruncated)
        XCTAssertFalse(CotabbyTestFixtures.focusedInputSnapshot(trailingTextUnavailable: true).precedingTextMayBeTruncated)
    }
}
