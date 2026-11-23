import CoreGraphics
import XCTest
@testable import Cotabby

/// Tests for the key classification shared by the emoji picker and the macro preview. The rules
/// here decide which keys end a capture and which one commits, so a regression would show up in
/// both features at once.
@MainActor
final class InlineCommandKeyClassifierTests: XCTestCase {
    private static let tab: CGKeyCode = 48

    private func classify(
        keyCode: CGKeyCode,
        characters: String = "",
        flags: CGEventFlags = [],
        wordAcceptKeyCode: CGKeyCode? = InlineCommandKeyClassifierTests.tab
    ) -> InlineCommandKey {
        InlineCommandKeyClassifier.classify(
            CapturedInputEvent(kind: .textMutation, keyCode: keyCode, characters: characters, flags: flags),
            isWordAcceptKey: { $0.keyCode == wordAcceptKeyCode }
        )
    }

    func test_singlePrintableCharacter_isACharacter() {
        XCTAssertEqual(classify(keyCode: 41, characters: ":"), .character(":"))
        XCTAssertEqual(classify(keyCode: 0, characters: "a"), .character("a"))
    }

    func test_emptyMultiCharacterAndNewlineKeyDowns_dismiss() {
        // Dead keys report no characters, IME composition can report several, and a newline that
        // arrives as text must never extend a query.
        XCTAssertEqual(classify(keyCode: 41, characters: ""), .dismissExternally)
        XCTAssertEqual(classify(keyCode: 41, characters: "ab"), .dismissExternally)
        XCTAssertEqual(classify(keyCode: 41, characters: "\n"), .dismissExternally)
    }

    func test_commandOrControlChords_dismissBeforeAnythingElse() {
        // Even the accept key and Escape are shortcuts once Command or Control is held.
        for flags in [CGEventFlags.maskCommand, .maskControl] {
            XCTAssertEqual(classify(keyCode: Self.tab, flags: flags), .dismissExternally)
            XCTAssertEqual(classify(keyCode: 53, flags: flags), .dismissExternally)
            XCTAssertEqual(classify(keyCode: 0, characters: "a", flags: flags), .dismissExternally)
        }
    }

    func test_wordAcceptKey_commitsAndWinsOverTheKeyCodeTable() {
        XCTAssertEqual(classify(keyCode: Self.tab), .commitKey)
        // A user who rebinds accept-word to Return or an arrow gets a commit, not the default meaning.
        XCTAssertEqual(classify(keyCode: 36, wordAcceptKeyCode: 36), .commitKey)
        XCTAssertEqual(classify(keyCode: 124, wordAcceptKeyCode: 124), .commitKey)
    }

    func test_wordAcceptCheck_seesTheEventsKeyCodeAndFlags() {
        var seen: [(CGKeyCode, CGEventFlags)] = []
        _ = InlineCommandKeyClassifier.classify(
            CapturedInputEvent(kind: .textMutation, keyCode: 48, characters: "", flags: .maskShift),
            isWordAcceptKey: { keyEvent in
                seen.append((keyEvent.keyCode, keyEvent.flags))
                return false
            }
        )
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen.first?.0, 48)
        XCTAssertEqual(seen.first?.1, .maskShift)
    }

    func test_tabWithoutAnAcceptBinding_isNotACommit() {
        XCTAssertEqual(classify(keyCode: Self.tab, characters: "\t", wordAcceptKeyCode: nil), .character("\t"))
    }

    func test_escapeReturnAndForwardDelete() {
        XCTAssertEqual(classify(keyCode: 53), .escape)
        XCTAssertEqual(classify(keyCode: 36, characters: "\r"), .dismissExternally)
        XCTAssertEqual(classify(keyCode: 76, characters: "\r"), .dismissExternally)
        XCTAssertEqual(classify(keyCode: 117), .dismissExternally)
    }

    func test_arrowsKeepTheirDirection() {
        XCTAssertEqual(classify(keyCode: 126), .arrow(.up))
        XCTAssertEqual(classify(keyCode: 125), .arrow(.down))
        XCTAssertEqual(classify(keyCode: 123), .arrow(.left))
        XCTAssertEqual(classify(keyCode: 124), .arrow(.right))
    }

    func test_backspace_isOneCharacterUnlessOptionDeletesAWord() {
        XCTAssertEqual(classify(keyCode: 51), .backspace)
        XCTAssertEqual(classify(keyCode: 51, flags: .maskShift), .backspace)
        XCTAssertEqual(classify(keyCode: 51, flags: .maskAlternate), .dismissExternally)
    }
}
