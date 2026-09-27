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

    func test_resolvedFieldStyle_pointSizeAloneIsNotARenderableStyle() {
        // A bare point size cannot style ghost text without a font or color, so it must still
        // count as empty and let the overlay fall back to defaults.
        let sizeOnly = ResolvedFieldStyle(fontName: nil, fontPointSize: 13, colorHex: nil)
        XCTAssertTrue(sizeOnly.isEmpty)
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
