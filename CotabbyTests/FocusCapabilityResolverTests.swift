import XCTest
@testable import Cotabby

/// Tests for choosing the best Accessibility candidate around the focused element.
///
/// These tests stay below real AX APIs. The resolver's job is to score already-observed candidate
/// facts, so pure value tests give us deterministic coverage of the heuristic policy.
final class FocusCapabilityResolverTests: XCTestCase {
    func test_resolve_selectsFirstCandidateWithFullCapabilities() {
        let partial = CotabbyTestFixtures.focusCapabilityCandidate(
            elementIdentifier: "partial",
            hasCaretBounds: false
        )
        let full = CotabbyTestFixtures.focusCapabilityCandidate(
            elementIdentifier: "full",
            editableHintScore: 20
        )

        let resolution = FocusCapabilityResolver.resolve(candidates: [partial, full])

        XCTAssertEqual(resolution.resolvedCandidate?.elementIdentifier, "full")
        XCTAssertEqual(resolution.inspectedCandidateCount, 2)
        XCTAssertTrue(resolution.missingCapabilities.isEmpty)
    }

    func test_resolve_stopsAtFirstFullCandidateBecauseSearchOrderCarriesMeaning() {
        let firstFull = CotabbyTestFixtures.focusCapabilityCandidate(
            elementIdentifier: "first",
            editableHintScore: 0
        )
        let laterFull = CotabbyTestFixtures.focusCapabilityCandidate(
            elementIdentifier: "later",
            editableHintScore: 50
        )

        let resolution = FocusCapabilityResolver.resolve(candidates: [firstFull, laterFull])

        XCTAssertEqual(resolution.resolvedCandidate?.elementIdentifier, "first")
        XCTAssertEqual(resolution.inspectedCandidateCount, 1)
    }

    func test_evaluate_reportsMissingCapabilitiesInStableRequirementOrder() {
        let candidate = CotabbyTestFixtures.focusCapabilityCandidate(
            hasStrongEditabilitySignal: false,
            isKnownReadOnlyRole: true,
            hasTextValue: false,
            hasSelectionRange: true,
            hasCaretBounds: false
        )

        let evaluation = FocusCapabilityResolver.evaluate(candidate)

        XCTAssertEqual(
            evaluation.missingCapabilities,
            [.textValue, .caretBounds, .editableTarget]
        )
        XCTAssertFalse(evaluation.hasFullCapabilities)
    }

    func test_evaluate_scoresAvailableCapabilitiesBeforeEditableHint() {
        let candidate = CotabbyTestFixtures.focusCapabilityCandidate(
            editableHintScore: 7,
            hasStrongEditabilitySignal: true,
            hasTextValue: true,
            hasSelectionRange: true,
            hasCaretBounds: false
        )

        let evaluation = FocusCapabilityResolver.evaluate(candidate)

        XCTAssertEqual(evaluation.score, 307)
    }

    func test_resolve_returnsBestPartialCandidateForDiagnostics() {
        let weakerPartial = CotabbyTestFixtures.focusCapabilityCandidate(
            elementIdentifier: "weaker",
            hasSelectionRange: false,
            hasCaretBounds: false
        )
        let strongerPartial = CotabbyTestFixtures.focusCapabilityCandidate(
            elementIdentifier: "stronger",
            hasStrongEditabilitySignal: false
        )

        let resolution = FocusCapabilityResolver.resolve(
            candidates: [weakerPartial, strongerPartial]
        )

        XCTAssertNil(resolution.resolvedCandidate)
        XCTAssertEqual(resolution.bestDiagnosticCandidate?.elementIdentifier, "stronger")
        XCTAssertEqual(resolution.unsupportedReason, "Missing editable target.")
    }

    func test_resolve_emptyCandidateListReportsGenericUnsupportedReason() {
        let resolution = FocusCapabilityResolver.resolve(candidates: [])

        XCTAssertNil(resolution.resolvedCandidate)
        XCTAssertNil(resolution.bestDiagnosticCandidate)
        XCTAssertEqual(resolution.missingCapabilities, FocusCapabilityRequirement.allCases)
        XCTAssertEqual(
            resolution.unsupportedReason,
            "No nearby text target exposed the required Accessibility capabilities."
        )
    }

    func test_evaluate_readOnlyRoleCannotBecomeEditableTarget() {
        let candidate = CotabbyTestFixtures.focusCapabilityCandidate(
            role: "AXStaticText",
            hasStrongEditabilitySignal: true,
            isKnownReadOnlyRole: true,
            hasTextValue: true,
            hasSelectionRange: true,
            hasCaretBounds: true
        )

        let evaluation = FocusCapabilityResolver.evaluate(candidate)

        XCTAssertEqual(evaluation.missingCapabilities, [.editableTarget])
        XCTAssertFalse(evaluation.hasFullCapabilities)
    }
}
