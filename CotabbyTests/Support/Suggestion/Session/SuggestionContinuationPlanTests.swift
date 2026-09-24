import XCTest
@testable import Cotabby

/// These cases distinguish what the writer committed from the virtual boundary the model sees.
/// They also lock down the identity check that keeps prefetched text out of a different editor.
final class SuggestionContinuationPlanTests: XCTestCase {
    func testWordEndingKeepsActualEditSeparateFromVirtualPredictionBoundary() throws {
        let source = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Please schedu", isWebContentField: true)
        let plan = try XCTUnwrap(SuggestionContinuationPlan.completing("le", in: source))
        XCTAssertEqual(plan.sourceSnapshot, source)
        XCTAssertEqual(plan.targetSnapshot.precedingText, "Please schedule")
        XCTAssertEqual(plan.requestSnapshot.precedingText, "Please schedule ")
        XCTAssertEqual(plan.targetSnapshot.selection.location, "Please schedule".utf16.count)
        XCTAssertEqual(plan.requestSnapshot.selection.location, "Please schedule ".utf16.count)
        XCTAssertTrue(plan.requestSnapshot.isWebContentField)
        XCTAssertEqual(plan.joiningSeparator, " ")
        XCTAssertEqual(plan.continuation(from: "a meeting"), " a meeting")
        XCTAssertEqual(plan.continuation(from: " a meeting"), " a meeting")
    }

    func testCorrectionPreservesExistingDelimiterWithoutDoublingSpace() throws {
        let source = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Please recieve ", trailingText: "today.")
        let replacement = try XCTUnwrap(TypoCorrectionReplacementPlanner.plan(
            precedingText: source.precedingText, expectedTypo: "recieve", correctedWord: "receive", requiresTrailingSpace: true
        ))
        let plan = try XCTUnwrap(SuggestionContinuationPlan.correcting(replacement, in: source))
        XCTAssertEqual(plan.targetSnapshot.precedingText, "Please receive ")
        XCTAssertEqual(plan.targetSnapshot.trailingText, "today.")
        XCTAssertEqual(plan.requestSnapshot, plan.targetSnapshot)
        XCTAssertEqual(plan.joiningSeparator, "")
        XCTAssertEqual(plan.continuation(from: " the package"), "the package")
        XCTAssertEqual(plan.continuation(from: "the package"), "the package")
    }

    func testVirtualBoundaryPreservesMultilineAndRejectsEmptyContinuation() throws {
        let source = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Please schedu")
        let plan = try XCTUnwrap(SuggestionContinuationPlan.completing("le", in: source))
        XCTAssertEqual(plan.continuation(from: "\n  - Review"), "\n  - Review")
        XCTAssertEqual(plan.continuation(from: "  \n"), "")
        let linePlan = try XCTUnwrap(SuggestionContinuationPlan.completing("le\n", in: source))
        XCTAssertEqual(linePlan.joiningSeparator, "")
        XCTAssertEqual(linePlan.continuation(from: "  - Review"), "  - Review")
    }

    func testReplacementUsesUTF16RatherThanCharacterCount() throws {
        let source = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "A 🐈 teh ", selection: NSRange(location: 108, length: 0))
        let replacement = TypoCorrectionReplacement(deletingUTF16Count: 4, replacementText: "the ")
        let plan = try XCTUnwrap(SuggestionContinuationPlan.correcting(replacement, in: source))
        XCTAssertEqual(plan.targetSnapshot.precedingText, "A 🐈 the ")
        XCTAssertEqual(plan.targetSnapshot.selection.location, 108, "AX location can include text outside the captured window.")
        let emojiSource = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "A 🐈")
        let emojiPlan = try XCTUnwrap(SuggestionContinuationPlan.correcting(
            .init(deletingUTF16Count: 2, replacementText: "cat"), in: emojiSource
        ))
        XCTAssertEqual(emojiPlan.targetSnapshot.precedingText, "A cat")
        XCTAssertEqual(emojiPlan.targetSnapshot.selection.location, 5)
    }

    func testInvalidReplacementAndUnsafeContextsFailClosed() {
        let source = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "A 🐈")
        for length in [-1, 0, 1, 5] {
            XCTAssertNil(SuggestionContinuationPlan.correcting(.init(deletingUTF16Count: length, replacementText: "cat"), in: source))
        }
        let combining = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Cafe\u{301}")
        XCTAssertNil(SuggestionContinuationPlan.correcting(.init(deletingUTF16Count: 1, replacementText: "e"), in: combining))
        XCTAssertNil(SuggestionContinuationPlan.completing(" ", in: source))
        XCTAssertNil(SuggestionContinuationPlan.completing("tail", in: CotabbyTestFixtures.focusedInputSnapshot(isSecure: true)))
        XCTAssertNil(SuggestionContinuationPlan.completing("tail", in: CotabbyTestFixtures.focusedInputSnapshot(selection: NSRange(location: 0, length: 2))))
    }

    func testMatchingRequiresTheSameFieldProcessFocusSequenceAndContent() throws {
        let source = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Please schedu", trailingText: " today")
        let plan = try XCTUnwrap(SuggestionContinuationPlan.completing("le", in: source))
        XCTAssertTrue(plan.matchesSource(source))
        XCTAssertTrue(plan.matchesTarget(CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Please schedule", trailingText: " today")))
        XCTAssertFalse(plan.matchesTarget(source))
        for changed in [
            CotabbyTestFixtures.focusedInputSnapshot(processIdentifier: 456, precedingText: "Please schedule", trailingText: " today"),
            CotabbyTestFixtures.focusedInputSnapshot(elementIdentifier: "other-field", precedingText: "Please schedule", trailingText: " today"),
            CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Please schedule", trailingText: " today", focusChangeSequence: 2),
            CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Please schedule", trailingText: " tomorrow"),
            CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Please schedule ", trailingText: " today"),
            CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Please schedule", trailingText: " today", selection: NSRange(location: 14, length: 1))
        ] {
            XCTAssertFalse(plan.matchesTarget(changed))
        }
    }

    func testWebAXTokenChurnPreservesTheSameObservedFieldAndTarget() throws {
        let source = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Please schedu", isWebContentField: true)
        let plan = try XCTUnwrap(SuggestionContinuationPlan.completing("le", in: source))
        let refreshedSource = CotabbyTestFixtures.focusedInputSnapshot(
            elementIdentifier: "refreshed-ax-token", precedingText: source.precedingText, isWebContentField: true
        )
        let publishedTarget = CotabbyTestFixtures.focusedInputSnapshot(
            elementIdentifier: "another-ax-token", precedingText: "Please schedule", isWebContentField: true
        )
        let spacedTarget = CotabbyTestFixtures.focusedInputSnapshot(
            elementIdentifier: "third-ax-token", precedingText: "Please schedule ", isWebContentField: true
        )
        XCTAssertTrue(plan.matchesSource(refreshedSource))
        XCTAssertTrue(plan.matchesTarget(publishedTarget))
        XCTAssertFalse(plan.matchesTarget(spacedTarget))
        XCTAssertTrue(plan.matchesTargetWithJoiningSeparator(spacedTarget))
        XCTAssertFalse(plan.matchesTargetWithJoiningSeparator(publishedTarget))
    }

    func testWebAXChurnCannotExcuseAnotherFieldOrUntrackedFocus() throws {
        let source = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Please schedu", isWebContentField: true)
        let plan = try XCTUnwrap(SuggestionContinuationPlan.completing("le", in: source))
        for changed in [
            CotabbyTestFixtures.focusedInputSnapshot(elementIdentifier: "other", inputFrameRect: nil,
                precedingText: "Please schedule", isWebContentField: true),
            CotabbyTestFixtures.focusedInputSnapshot(elementIdentifier: "other", inputFrameRect: CGRect(x: 0, y: 80, width: 240, height: 32),
                precedingText: "Please schedule", isWebContentField: true),
            CotabbyTestFixtures.focusedInputSnapshot(elementIdentifier: "other", role: "AXTextArea",
                precedingText: "Please schedule", isWebContentField: true),
            CotabbyTestFixtures.focusedInputSnapshot(elementIdentifier: "other", precedingText: "Please schedule", isWebContentField: false),
            CotabbyTestFixtures.focusedInputSnapshot(elementIdentifier: "other", precedingText: "Please schedule", isWebContentField: true,
                focusChangeSequence: 2)
        ] {
            XCTAssertFalse(plan.matchesTarget(changed))
        }
        let legacySource = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Please schedu", isWebContentField: true,
            focusChangeSequence: 0)
        let legacyPlan = try XCTUnwrap(SuggestionContinuationPlan.completing("le", in: legacySource))
        XCTAssertFalse(legacyPlan.matchesTarget(CotabbyTestFixtures.focusedInputSnapshot(
            elementIdentifier: "other", precedingText: "Please schedule", isWebContentField: true, focusChangeSequence: 0
        )))
    }
}
