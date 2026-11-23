import XCTest
@testable import Cotabby

/// Verifies the two conditional transitions of the pipeline phase: availability ends only
/// `disabled`, and dropping a cycle never ends it.
@MainActor
final class SuggestionPipelinePhaseTests: XCTestCase {
    private let workingPhases: [SuggestionPipelinePhase] = [.debouncing, .generating, .ready, .failed]

    func test_onlyIdleAndDisabledAreSettled() {
        XCTAssertTrue(SuggestionPipelinePhase.idle.isSettled)
        XCTAssertTrue(SuggestionPipelinePhase.disabled("off").isSettled)
        for phase in workingPhases {
            XCTAssertFalse(phase.isSettled, "\(phase) still has work or a suggestion to clear")
        }
    }

    func test_reenableLeavesDisabledAndKeepsEveryOtherPhase() {
        var disabled = SuggestionPipelinePhase.disabled("Cotabby is turned off.")
        disabled.reenable()
        XCTAssertEqual(disabled, .idle)

        for phase in workingPhases + [.idle] {
            var reenabled = phase
            reenabled.reenable()
            XCTAssertEqual(reenabled, phase, "An availability change must not end \(phase)")
        }
    }

    func test_settleReturnsToIdleUnlessDisabled() {
        for phase in workingPhases + [.idle] {
            var settled = phase
            settled.settle()
            XCTAssertEqual(settled, .idle)
        }

        var disabled = SuggestionPipelinePhase.disabled("Text is currently selected.")
        disabled.settle()
        XCTAssertEqual(disabled, .disabled("Text is currently selected."), "Dropping a cycle never re-enables")
    }
}
