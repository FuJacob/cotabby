import XCTest
@testable import Cotabby

/// Tests for the pure `::macro` trigger state machine.
///
/// These lock down deferred resolution (a single boundary `:` only pends; the second opens the
/// macro), the consumption policy (query characters always pass through; commit and Escape are
/// consumed only when there is something to act on), and the boundary rules.
final class MacroTriggerStateMachineTests: XCTestCase {

    private func openCapture(_ machine: inout MacroTriggerStateMachine) {
        _ = machine.reduce(.character(":"), hasInsertableResult: false)
        _ = machine.reduce(.character(":"), hasInsertableResult: false)
    }

    func test_doubleColonAtBoundary_opensCapture() {
        var sut = MacroTriggerStateMachine()
        let first = sut.reduce(.character(":"), hasInsertableResult: false)
        XCTAssertEqual(first.actions, [])
        XCTAssertFalse(sut.isCapturing)

        let second = sut.reduce(.character(":"), hasInsertableResult: false)
        XCTAssertEqual(second.actions, [.open])
        XCTAssertFalse(second.consumesKey)
        XCTAssertTrue(sut.isCapturing)
    }

    func test_singleColonThenLetter_doesNotOpen() {
        var sut = MacroTriggerStateMachine()
        _ = sut.reduce(.character(":"), hasInsertableResult: false)   // pending
        let output = sut.reduce(.character("a"), hasInsertableResult: false)
        XCTAssertEqual(output.actions, [])
        XCTAssertFalse(sut.isCapturing)
    }

    func test_colonNotAtBoundary_neverOpens() {
        var sut = MacroTriggerStateMachine()
        _ = sut.reduce(.character("x"), hasInsertableResult: false)
        _ = sut.reduce(.character(":"), hasInsertableResult: false)
        _ = sut.reduce(.character(":"), hasInsertableResult: false)
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
}
