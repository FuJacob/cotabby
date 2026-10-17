import XCTest
@testable import Cotabby

/// Pure-function tests for deciding when a refreshed screen excerpt should replace the one in the
/// prompt. The cases mirror what a refresh actually sees while someone types: OCR misreads, the
/// user's own text growing inside the captured field, and genuine screen updates.
final class VisualContextChangePolicyTests: XCTestCase {
    private let chat = """
    Alex Morgan 10:42
    Can you send the updated proposal before Friday?
    The pricing section still lists last quarter's numbers.
    Sam Lee 10:44
    I will check with finance and get back to you today.
    """

    func test_firstExcerptIsAlwaysMaterial() {
        XCTAssertTrue(VisualContextChangePolicy.isMaterialChange(previous: nil, next: chat, fieldText: ""))
    }

    func test_identicalExcerptIsNotMaterial() {
        XCTAssertFalse(VisualContextChangePolicy.isMaterialChange(previous: chat, next: chat, fieldText: ""))
    }

    func test_ocrMisreadsAreNotMaterial() {
        let jittered = chat
            .replacingOccurrences(of: "updated proposal", with: "updatcd proposal")
            .replacingOccurrences(of: "quarter's", with: "quarters")
            .replacingOccurrences(of: "10:44", with: "10.44")
        XCTAssertFalse(VisualContextChangePolicy.isMaterialChange(previous: chat, next: jittered, fieldText: ""))
    }

    /// The capture usually includes the field being typed into. Its growing text must not count
    /// as new screen content: the prompt already carries it as the caret prefix.
    func test_userTypingInsideCapturedFieldIsNotMaterial() {
        let typed = "Thanks Alex, I will update the pricing section and send the proposal"
        let previous = chat + "\nThanks Alex, I will update"
        let next = chat + "\n" + typed
        XCTAssertFalse(VisualContextChangePolicy.isMaterialChange(previous: previous, next: next, fieldText: typed))
    }

    func test_newIncomingMessageIsMaterial() {
        let next = chat + "\nAlex Morgan 10:47\nAlso please include the revised delivery timeline."
        XCTAssertTrue(VisualContextChangePolicy.isMaterialChange(previous: chat, next: next, fieldText: ""))
    }

    func test_navigationToAnotherConversationIsMaterial() {
        let other = """
        Priya Shah 09:15
        The staging cluster is down again after the last deploy.
        Could someone from platform take a look this morning?
        """
        XCTAssertTrue(VisualContextChangePolicy.isMaterialChange(previous: chat, next: other, fieldText: ""))
    }

    func test_shortChromeChangesAreNotMaterial() {
        let next = chat.replacingOccurrences(of: "Alex Morgan 10:42", with: "Alex Morgan 10:42 Edited")
        XCTAssertFalse(VisualContextChangePolicy.isMaterialChange(previous: chat, next: next, fieldText: ""))
    }

    func test_contentDisappearingIsMaterialOnlyPastThreshold() {
        let lines = chat.split(separator: "\n").map(String.init)
        let oneGone = lines.dropFirst(2).joined(separator: "\n")
        XCTAssertFalse(VisualContextChangePolicy.isMaterialChange(previous: chat, next: oneGone, fieldText: ""))
        XCTAssertTrue(VisualContextChangePolicy.isMaterialChange(previous: chat, next: "", fieldText: ""))
    }
}
