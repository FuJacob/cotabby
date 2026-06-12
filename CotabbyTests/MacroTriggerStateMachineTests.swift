import XCTest
@testable import Cotabby

/// Tests for the pure `/macro` trigger state machine.
///
/// These lock down the single-keystroke trigger (a boundary `/` opens capture immediately, a
/// non-boundary `/` never does), the consumption policy (query characters always pass through;
/// commit and Escape are consumed only when there is something to act on), and the rule that a `/`
/// typed while already capturing is an ordinary query character (division), not a re-trigger.
final class MacroTriggerStateMachineTests: XCTestCase {
    private func openCapture(_ machine: inout MacroTriggerStateMachine) {
        _ = machine.reduce(.character("/"), hasInsertableResult: false)
    }

    func test_slashAtBoundary_opensCapture() {
        var sut = MacroTriggerStateMachine()
        let output = sut.reduce(.character("/"), hasInsertableResult: false)
        XCTAssertEqual(output.actions, [.open])
        XCTAssertFalse(output.consumesKey)
        XCTAssertTrue(sut.isCapturing)
    }

    func test_slashAfterWhitespace_opensCapture() {
        var sut = MacroTriggerStateMachine()
        _ = sut.reduce(.character("a"), hasInsertableResult: false)
        _ = sut.reduce(.character(" "), hasInsertableResult: false)
        let output = sut.reduce(.character("/"), hasInsertableResult: false)
        XCTAssertEqual(output.actions, [.open])
        XCTAssertTrue(sut.isCapturing)
    }

    func test_slashNotAtBoundary_neverOpens() {
        var sut = MacroTriggerStateMachine()
        _ = sut.reduce(.character("x"), hasInsertableResult: false)
        let output = sut.reduce(.character("/"), hasInsertableResult: false)
        XCTAssertEqual(output.actions, [])
        XCTAssertFalse(sut.isCapturing)
    }

    func test_queryCharactersExtendWithoutConsuming() {
        var sut = MacroTriggerStateMachine()
        openCapture(&sut)
        for character in "5+5" {
            let output = sut.reduce(.character(character), hasInsertableResult: false)
            XCTAssertFalse(output.consumesKey)
        }
        guard case let .capturing(query) = sut.state else {
            return XCTFail("expected capturing state")
        }
        XCTAssertEqual(query, "5+5")
    }

    func test_slashWhileCapturingExtendsQuery_asDivision() {
        var sut = MacroTriggerStateMachine()
        openCapture(&sut)
        for character in "10/2" {
            _ = sut.reduce(.character(character), hasInsertableResult: false)
        }
        guard case let .capturing(query) = sut.state else {
            return XCTFail("expected capturing state")
        }
        XCTAssertEqual(query, "10/2")
    }

    func test_spaceTerminatesCapture_withoutConsuming() {
        var sut = MacroTriggerStateMachine()
        openCapture(&sut)
        _ = sut.reduce(.character("5"), hasInsertableResult: false)
        let output = sut.reduce(.character(" "), hasInsertableResult: false)
        XCTAssertEqual(output.actions, [.cancel])
        XCTAssertFalse(output.consumesKey)
        XCTAssertFalse(sut.isCapturing)
    }

    func test_commitWithResult_consumesAndCommits() {
        var sut = MacroTriggerStateMachine()
        openCapture(&sut)
        _ = sut.reduce(.character("t"), hasInsertableResult: false)
        let output = sut.reduce(.commitKey, hasInsertableResult: true)
        XCTAssertEqual(output.actions, [.commit])
        XCTAssertTrue(output.consumesKey)
        XCTAssertFalse(sut.isCapturing)
    }

    func test_commitWithoutResult_passesThrough() {
        var sut = MacroTriggerStateMachine()
        openCapture(&sut)
        let output = sut.reduce(.commitKey, hasInsertableResult: false)
        XCTAssertEqual(output.actions, [.cancel])
        XCTAssertFalse(output.consumesKey)
    }

    func test_escape_consumesAndCancels() {
        var sut = MacroTriggerStateMachine()
        openCapture(&sut)
        let output = sut.reduce(.escape, hasInsertableResult: true)
        XCTAssertEqual(output.actions, [.cancel])
        XCTAssertTrue(output.consumesKey)
    }

    func test_backspaceOnEmptyQuery_cancelsWithoutConsuming() {
        var sut = MacroTriggerStateMachine()
        openCapture(&sut)
        let output = sut.reduce(.backspace, hasInsertableResult: false)
        XCTAssertEqual(output.actions, [.cancel])
        XCTAssertFalse(output.consumesKey)
        XCTAssertFalse(sut.isCapturing)
    }

    func test_backspaceShortensQuery() {
        var sut = MacroTriggerStateMachine()
        openCapture(&sut)
        _ = sut.reduce(.character("a"), hasInsertableResult: false)
        _ = sut.reduce(.character("b"), hasInsertableResult: false)
        let output = sut.reduce(.backspace, hasInsertableResult: false)
        XCTAssertEqual(output.actions, [.updateQuery("a")])
    }

    func test_reset_returnsToIdleAndRestoresBoundary() {
        var sut = MacroTriggerStateMachine()
        openCapture(&sut)
        _ = sut.reduce(.character("5"), hasInsertableResult: false)

        sut.reset()

        XCTAssertFalse(sut.isCapturing)
        XCTAssertEqual(sut.state, .idle(previousCharacter: nil))
        // A cleared machine has no boundary memory, so the next `/` opens as at the start of a field.
        let output = sut.reduce(.character("/"), hasInsertableResult: false)
        XCTAssertEqual(output.actions, [.open])
    }

    func test_nonCharacterInputsWhileIdle_areIgnoredAndClearBoundaryMemory() {
        let inputs: [MacroTriggerInput] = [.backspace, .commitKey, .escape, .navigate, .focusChanged, .dismissExternally]
        for input in inputs {
            var sut = MacroTriggerStateMachine()
            _ = sut.reduce(.character("x"), hasInsertableResult: false)

            let output = sut.reduce(input, hasInsertableResult: true)

            XCTAssertEqual(output, .ignored, "input \(input) should be ignored while idle")
            // The machine forgot the preceding "x", so the next `/` is evaluated as a fresh boundary.
            let reopened = sut.reduce(.character("/"), hasInsertableResult: false)
            XCTAssertEqual(reopened.actions, [.open], "input \(input) should clear boundary memory")
        }
    }

    func test_navigationAndFocusEventsWhileCapturing_cancelWithoutConsuming() {
        let inputs: [MacroTriggerInput] = [.navigate, .focusChanged, .dismissExternally]
        for input in inputs {
            var sut = MacroTriggerStateMachine()
            openCapture(&sut)
            _ = sut.reduce(.character("5"), hasInsertableResult: false)

            let output = sut.reduce(input, hasInsertableResult: true)

            XCTAssertEqual(output.actions, [.cancel], "input \(input) should cancel capture")
            XCTAssertFalse(output.consumesKey, "input \(input) must reach the focused app")
            XCTAssertFalse(sut.isCapturing)
        }
    }
}
