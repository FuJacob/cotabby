import XCTest
@testable import Cotabby

/// Tests for the pure `:emoji:` trigger state machine.
///
/// These lock down the capture lifecycle and, critically, the consumption policy: query characters
/// always pass through to the field, while navigation, commit, and Escape are consumed only when
/// doing so will not surprise the user (there must be matches to act on). The boundary rules keep
/// the picker from opening inside tokens like `http://` or `foo::bar`.
final class EmojiTriggerStateMachineTests: XCTestCase {

    private func open(_ machine: inout EmojiTriggerStateMachine) {
        _ = machine.reduce(.character(":"), selectableMatchCount: 0)
    }

    private func type(_ text: String, into machine: inout EmojiTriggerStateMachine, matchCount: Int = 0) {
        for character in text {
            _ = machine.reduce(.character(character), selectableMatchCount: matchCount)
        }
    }

    // MARK: - Trigger boundary

    func test_trigger_atStartOfField_opens() {
        var sut = EmojiTriggerStateMachine()

        let output = sut.reduce(.character(":"), selectableMatchCount: 0)

        XCTAssertEqual(output.actions, [.open(query: "")])
        XCTAssertFalse(output.consumesKey)
        XCTAssertEqual(sut.state, .capturing(query: ""))
    }

    func test_trigger_afterWhitespace_opens() {
        var sut = EmojiTriggerStateMachine()
        type("hi ", into: &sut)

        let output = sut.reduce(.character(":"), selectableMatchCount: 0)

        XCTAssertEqual(output.actions, [.open(query: "")])
        XCTAssertTrue(sut.isCapturing)
    }

    func test_trigger_afterLetter_doesNotOpen() {
        var sut = EmojiTriggerStateMachine()
        type("a", into: &sut)

        let output = sut.reduce(.character(":"), selectableMatchCount: 0)

        XCTAssertEqual(output, .ignored)
        XCTAssertFalse(sut.isCapturing)
    }

    func test_doubleColon_doesNotOpen() {
        var sut = EmojiTriggerStateMachine()
        type("a", into: &sut)

        XCTAssertEqual(sut.reduce(.character(":"), selectableMatchCount: 0), .ignored)
        XCTAssertEqual(sut.reduce(.character(":"), selectableMatchCount: 0), .ignored)
        XCTAssertFalse(sut.isCapturing)
    }

    // MARK: - Query editing (never consumed)

    func test_nameCharacters_extendQueryWithoutConsuming() {
        var sut = EmojiTriggerStateMachine()
        open(&sut)

        let first = sut.reduce(.character("s"), selectableMatchCount: 0)
        XCTAssertEqual(first.actions, [.updateQuery("s")])
        XCTAssertFalse(first.consumesKey)

        let second = sut.reduce(.character("m"), selectableMatchCount: 0)
        XCTAssertEqual(second.actions, [.updateQuery("sm")])
        XCTAssertFalse(second.consumesKey)
        XCTAssertEqual(sut.state, .capturing(query: "sm"))
    }

    func test_aliasPunctuationExtendsQuery() {
        var sut = EmojiTriggerStateMachine()
        open(&sut)

        let plus = sut.reduce(.character("+"), selectableMatchCount: 0)
        XCTAssertEqual(plus.actions, [.updateQuery("+")])
        let one = sut.reduce(.character("1"), selectableMatchCount: 0)
        XCTAssertEqual(one.actions, [.updateQuery("+1")])
    }

    func test_backspace_shortensQuery() {
        var sut = EmojiTriggerStateMachine()
        open(&sut)
        type("sm", into: &sut)

        let output = sut.reduce(.backspace, selectableMatchCount: 5)

        XCTAssertEqual(output.actions, [.updateQuery("s")])
        XCTAssertFalse(output.consumesKey)
    }

    func test_backspaceOnEmptyQuery_cancels() {
        var sut = EmojiTriggerStateMachine()
        open(&sut)

        let output = sut.reduce(.backspace, selectableMatchCount: 0)

        XCTAssertEqual(output.actions, [.cancel])
        XCTAssertFalse(output.consumesKey)
        XCTAssertFalse(sut.isCapturing)
    }

    func test_whitespace_cancelsCapture() {
        var sut = EmojiTriggerStateMachine()
        open(&sut)
        type("smi", into: &sut)

        let output = sut.reduce(.character(" "), selectableMatchCount: 4)

        XCTAssertEqual(output.actions, [.cancel])
        XCTAssertFalse(output.consumesKey)
        XCTAssertFalse(sut.isCapturing)
    }

    // MARK: - Navigation

    func test_navigate_withMatches_consumesAndMoves() {
        var sut = EmojiTriggerStateMachine()
        open(&sut)
        type("s", into: &sut, matchCount: 3)

        let output = sut.reduce(.navigate(.down), selectableMatchCount: 3)

        XCTAssertEqual(output.actions, [.moveSelection(.down)])
        XCTAssertTrue(output.consumesKey)
        XCTAssertTrue(sut.isCapturing)
    }

    func test_navigate_withoutMatches_cancelsAndPassesThrough() {
        var sut = EmojiTriggerStateMachine()
        open(&sut)
        type("zz", into: &sut)

        let output = sut.reduce(.navigate(.down), selectableMatchCount: 0)

        XCTAssertEqual(output.actions, [.cancel])
        XCTAssertFalse(output.consumesKey)
        XCTAssertFalse(sut.isCapturing)
    }

    // MARK: - Commit

    func test_commit_withMatches_consumesAndCommitsModeA() {
        var sut = EmojiTriggerStateMachine()
        open(&sut)
        type("smile", into: &sut, matchCount: 4)

        let output = sut.reduce(.commitKey, selectableMatchCount: 4)

        XCTAssertEqual(output.actions, [.commit(.key)])
        XCTAssertTrue(output.consumesKey)
        XCTAssertFalse(sut.isCapturing)
    }

    func test_commit_withoutMatches_passesThrough() {
        var sut = EmojiTriggerStateMachine()
        open(&sut)
        type("zz", into: &sut)

        let output = sut.reduce(.commitKey, selectableMatchCount: 0)

        XCTAssertEqual(output.actions, [.cancel])
        XCTAssertFalse(output.consumesKey)
    }

    func test_closingColon_commitsModeB_andIsNotConsumed() {
        var sut = EmojiTriggerStateMachine()
        open(&sut)
        type("smile", into: &sut, matchCount: 4)

        let output = sut.reduce(.character(":"), selectableMatchCount: 4)

        XCTAssertEqual(output.actions, [.commit(.closingColon)])
        XCTAssertFalse(output.consumesKey)
        XCTAssertFalse(sut.isCapturing)
    }

    // MARK: - Cancellation

    func test_escape_consumesAndCancels() {
        var sut = EmojiTriggerStateMachine()
        open(&sut)
        type("s", into: &sut, matchCount: 3)

        let output = sut.reduce(.escape, selectableMatchCount: 3)

        XCTAssertEqual(output.actions, [.cancel])
        XCTAssertTrue(output.consumesKey)
        XCTAssertFalse(sut.isCapturing)
    }

    func test_focusChange_cancelsWithoutConsuming() {
        var sut = EmojiTriggerStateMachine()
        open(&sut)
        type("s", into: &sut, matchCount: 3)

        let output = sut.reduce(.focusChanged, selectableMatchCount: 3)

        XCTAssertEqual(output.actions, [.cancel])
        XCTAssertFalse(output.consumesKey)
        XCTAssertFalse(sut.isCapturing)
    }

    func test_dismissExternally_cancels() {
        var sut = EmojiTriggerStateMachine()
        open(&sut)
        type("s", into: &sut, matchCount: 3)

        let output = sut.reduce(.dismissExternally, selectableMatchCount: 3)

        XCTAssertEqual(output.actions, [.cancel])
        XCTAssertFalse(sut.isCapturing)
    }
}
