import XCTest
@testable import Cotabby

/// Tests for choosing the best Accessibility candidate around the focused element.
///
/// These tests stay below real AX APIs. The resolver's job is to score already-observed candidate
/// facts, so pure value tests give us deterministic coverage of the heuristic policy.
final class FocusCapabilityResolverTests: XCTestCase {
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

    func test_resolution_usesTheFirstMissingCapabilityAsItsUnsupportedReason() {
        let candidate = CotabbyTestFixtures.focusCapabilityCandidate(
            hasStrongEditabilitySignal: false
        )
        let evaluation = FocusCapabilityResolver.evaluate(candidate)
        let resolution = FocusCapabilityResolution(selectedEvaluation: evaluation)

        XCTAssertEqual(resolution.unsupportedReason, "Missing editable target.")
    }

    func test_resolution_withoutACandidateReportsGenericUnsupportedReason() {
        let resolution = FocusCapabilityResolution(selectedEvaluation: nil)

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
