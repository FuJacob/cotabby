import XCTest
@testable import Cotabby

/// Replace may only type over the very text the user selected; anything else copies the result to
/// the clipboard instead of guessing where it belongs.
final class SelectionReplaceValidatorTests: XCTestCase {
    private let draft = "Please let me know if te dates are ok"

    private func field(selected: String, element: String = "composer", selection: NSRange? = nil) -> FocusedInputSnapshot {
        CotabbyTestFixtures.focusedInputSnapshot(
            bundleIdentifier: "net.whatsapp.WhatsApp", elementIdentifier: element, precedingText: "Dear Charlie, ",
            selection: selection ?? NSRange(location: 14, length: (selected as NSString).length),
            selectedText: selected, hostSelection: NSRange(location: 14, length: (draft as NSString).length)
        )
    }

    func test_unchangedSelectionReplaces() {
        let target = SelectionRewriteTarget(snapshot: field(selected: draft))
        XCTAssertEqual(SelectionReplaceValidator.outcome(target: target, current: field(selected: draft)), .replace)
    }

    func test_lostSelectionInSameFieldIsRestoredFirst() {
        let target = SelectionRewriteTarget(snapshot: field(selected: draft))
        let caretOnly = field(selected: "", selection: NSRange(location: 20, length: 0))
        XCTAssertEqual(SelectionReplaceValidator.outcome(target: target, current: caretOnly), .restoreSelectionThenReplace)
    }

    func test_differentSelectionCopiesInstead() {
        let target = SelectionRewriteTarget(snapshot: field(selected: draft))
        guard case .copyInstead = SelectionReplaceValidator.outcome(target: target, current: field(selected: "something else entirely")) else {
            return XCTFail("A different selection must never be replaced")
        }
    }

    func test_otherFieldOrNoFieldCopiesInstead() {
        let target = SelectionRewriteTarget(snapshot: field(selected: draft))
        guard case .copyInstead = SelectionReplaceValidator.outcome(target: target, current: field(selected: draft, element: "search")) else {
            return XCTFail("Another field must never receive the rewrite")
        }
        guard case .copyInstead = SelectionReplaceValidator.outcome(target: target, current: nil) else {
            return XCTFail("No field must never receive the rewrite")
        }
    }

    func test_sameTextAtAnotherPlaceCopiesInstead() {
        let target = SelectionRewriteTarget(snapshot: field(selected: draft))
        let elsewhere = CotabbyTestFixtures.focusedInputSnapshot(
            bundleIdentifier: "net.whatsapp.WhatsApp", elementIdentifier: "composer", precedingText: "Dear Charlie, ",
            selection: NSRange(location: 60, length: (draft as NSString).length),
            selectedText: draft, hostSelection: NSRange(location: 60, length: (draft as NSString).length)
        )
        guard case .copyInstead = SelectionReplaceValidator.outcome(target: target, current: elsewhere) else {
            return XCTFail("The same text at another place must never be replaced")
        }
    }

    /// Without a host range (Chromium), the text around the selection tells two copies apart.
    func test_withoutAHostRangeTheSurroundingTextDecides() {
        func chromium(preceding: String, trailing: String) -> FocusedInputSnapshot {
            CotabbyTestFixtures.focusedInputSnapshot(
                bundleIdentifier: "com.google.Chrome", elementIdentifier: "composer", precedingText: preceding,
                trailingText: trailing, selection: NSRange(location: (preceding as NSString).length, length: 6),
                selectedText: "thanks", hostSelection: nil
            )
        }
        let first = chromium(preceding: "Hi Sam, thanks", trailing: " for the notes. See you, thanks again.")
        let second = chromium(preceding: "Hi Sam, thanks for the notes. See you, ", trailing: " again.")
        let target = SelectionRewriteTarget(snapshot: first)
        XCTAssertEqual(SelectionReplaceValidator.outcome(target: target, current: first), .replace)
        guard case .copyInstead = SelectionReplaceValidator.outcome(target: target, current: second) else {
            return XCTFail("Another copy of the same phrase must never be replaced")
        }
        XCTAssertNotEqual(SelectionRewriteTarget(snapshot: second), target, "selecting the other copy re-arms the rewrite")
    }
}
