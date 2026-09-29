import CoreGraphics
import Foundation
import XCTest
@testable import Cotabby

/// Tests for the pure focus value models: diagnostic labels, capability summaries, content-edge
/// provenance, snapshot identity and truncation signals, resolved field style emptiness, and the
/// polling-event change label.
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

    func test_focusCapabilityRequirement_unsupportedReasonLowercasesTheSummary() {
        XCTAssertEqual(
            FocusCapabilityRequirement.allCases.map(\.unsupportedReason),
            [
                "Missing text value.",
                "Missing selection range.",
                "Missing caret bounds.",
                "Missing editable target."
            ]
        )
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
        let base = CotabbyTestFixtures.focusedInputSnapshot(
            focusedURLString: "https://chat.example/one", windowTitle: "Chat one", fieldPlaceholder: "Message"
        ).sessionIdentity

        let unreadable: [(String, FocusedInputSnapshot)] = [
            ("title timed out", CotabbyTestFixtures.focusedInputSnapshot(
                focusedURLString: "https://chat.example/one", windowTitle: nil, fieldPlaceholder: "Message")),
            ("url timed out", CotabbyTestFixtures.focusedInputSnapshot(
                focusedURLString: nil, windowTitle: "Chat one", fieldPlaceholder: "Message")),
            ("every fact timed out", CotabbyTestFixtures.focusedInputSnapshot())
        ]
        for (label, live) in unreadable {
            XCTAssertTrue(live.sessionIdentity.continues(base), label)
            XCTAssertNotEqual(live.sessionIdentity, base, "\(label): equality is deliberately stricter")
        }
        // A base captured during an unreadable poll must also accept the later known value.
        XCTAssertTrue(base.continues(CotabbyTestFixtures.focusedInputSnapshot().sessionIdentity))

        let navigated: [(String, FocusedInputSnapshot)] = [
            ("new title", CotabbyTestFixtures.focusedInputSnapshot(
                focusedURLString: "https://chat.example/one", windowTitle: "Chat two", fieldPlaceholder: "Message")),
            ("new url", CotabbyTestFixtures.focusedInputSnapshot(
                focusedURLString: "https://chat.example/two", windowTitle: "Chat one", fieldPlaceholder: "Message")),
            ("new placeholder", CotabbyTestFixtures.focusedInputSnapshot(
                focusedURLString: "https://chat.example/one", windowTitle: "Chat one", fieldPlaceholder: "Reply")),
            ("new focus sequence", CotabbyTestFixtures.focusedInputSnapshot(
                focusChangeSequence: 2, focusedURLString: "https://chat.example/one",
                windowTitle: "Chat one", fieldPlaceholder: "Message")),
            ("other process", CotabbyTestFixtures.focusedInputSnapshot(
                processIdentifier: 456, focusedURLString: "https://chat.example/one",
                windowTitle: "Chat one", fieldPlaceholder: "Message"))
        ]
        for (label, live) in navigated {
            XCTAssertFalse(live.sessionIdentity.continues(base), label)
        }
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
    }

    func test_focusPollingEvent_changeSummaryLabelsReflectFocusChange() {
        XCTAssertEqual(makePollingEvent(didChange: true).changeSummary, "changed")
        XCTAssertEqual(makePollingEvent(didChange: false).changeSummary, "unchanged")
    }

    private func makePollingEvent(didChange: Bool) -> FocusPollingEvent {
        FocusPollingEvent(
            sequence: 1,
            focusChangeSequence: 2,
            didChangeFocusedInput: didChange,
            applicationName: "Notes",
            capabilitySummary: "Supported",
            occurredAt: Date(timeIntervalSinceReferenceDate: 0)
        )
    }
}
