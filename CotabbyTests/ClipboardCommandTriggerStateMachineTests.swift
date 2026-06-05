import XCTest
@testable import Cotabby

/// Tests for the pure `/cb` clipboard command trigger machine.
///
/// These lock down the two-stage flow (a boundary `/cb` opens the hint; the accept key escalates to
/// the list), the passivity rule (the machine does not count as capturing until `/cb` is fully
/// matched, so the macro feature owns ambiguous `/c…` prefixes), and the consumption policy
/// (navigation/commit are consumed only when there are rows; typing in the list closes it).
final class ClipboardCommandTriggerStateMachineTests: XCTestCase {
    private func openHint(_ machine: inout ClipboardCommandTriggerStateMachine) {
        _ = machine.reduce(.character("/"), selectableCount: 0)
        _ = machine.reduce(.character("c"), selectableCount: 0)
        _ = machine.reduce(.character("b"), selectableCount: 0)
    }

    func test_slashCBAtBoundary_opensHint() {
        var sut = ClipboardCommandTriggerStateMachine()
        XCTAssertEqual(sut.reduce(.character("/"), selectableCount: 0), .ignored)
        XCTAssertFalse(sut.isCapturing)   // still ambiguous; macro owns it
        XCTAssertEqual(sut.reduce(.character("c"), selectableCount: 0), .ignored)
        XCTAssertFalse(sut.isCapturing)
        let output = sut.reduce(.character("b"), selectableCount: 0)
        XCTAssertEqual(output.actions, [.openHint])
        XCTAssertFalse(output.consumesKey)   // the "b" still reaches the field
        XCTAssertTrue(sut.isCapturing)
    }

    func test_slashCBAfterWhitespace_opensHint() {
        var sut = ClipboardCommandTriggerStateMachine()
        _ = sut.reduce(.character("a"), selectableCount: 0)
        _ = sut.reduce(.character(" "), selectableCount: 0)
        openHint(&sut)
        XCTAssertTrue(sut.isCapturing)
    }

    func test_slashCBNotAtBoundary_neverOpens() {
        var sut = ClipboardCommandTriggerStateMachine()
        _ = sut.reduce(.character("x"), selectableCount: 0)
        openHint(&sut)
        XCTAssertFalse(sut.isCapturing)
    }

    func test_prefixDivergesToMacro_withoutOpening() {
        var sut = ClipboardCommandTriggerStateMachine()
        _ = sut.reduce(.character("/"), selectableCount: 0)
        let output = sut.reduce(.character("o"), selectableCount: 0)   // "/o…" is not "/cb"
        XCTAssertEqual(output.actions, [])
        XCTAssertFalse(sut.isCapturing)
    }

    func test_hintCommit_opensList_andConsumes() {
        var sut = ClipboardCommandTriggerStateMachine()
        openHint(&sut)
        let output = sut.reduce(.commitKey, selectableCount: 0)
        XCTAssertEqual(output.actions, [.openList])
        XCTAssertTrue(output.consumesKey)
        XCTAssertTrue(sut.isCapturing)
        guard case .list = sut.state else { return XCTFail("expected list state") }
    }

    func test_hintEscape_cancelsAndConsumes() {
        var sut = ClipboardCommandTriggerStateMachine()
        openHint(&sut)
        let output = sut.reduce(.escape, selectableCount: 0)
        XCTAssertEqual(output.actions, [.cancel])
        XCTAssertTrue(output.consumesKey)
        XCTAssertFalse(sut.isCapturing)
    }

    func test_hintCharacter_cancelsAndPassesThrough() {
        var sut = ClipboardCommandTriggerStateMachine()
        openHint(&sut)
        let output = sut.reduce(.character("x"), selectableCount: 0)   // "/cbx" is not the command
        XCTAssertEqual(output.actions, [.cancel])
        XCTAssertFalse(output.consumesKey)
        XCTAssertFalse(sut.isCapturing)
    }

    func test_listNavigate_withRows_movesAndConsumes() {
        var sut = ClipboardCommandTriggerStateMachine()
        openHint(&sut)
        _ = sut.reduce(.commitKey, selectableCount: 0)   // -> list
        let output = sut.reduce(.navigate(.down), selectableCount: 3)
        XCTAssertEqual(output.actions, [.moveSelection(.down)])
        XCTAssertTrue(output.consumesKey)
        XCTAssertTrue(sut.isCapturing)
    }

    func test_listCommit_withRows_commitsAndConsumes() {
        var sut = ClipboardCommandTriggerStateMachine()
        openHint(&sut)
        _ = sut.reduce(.commitKey, selectableCount: 0)   // -> list
        let output = sut.reduce(.commitKey, selectableCount: 3)
        XCTAssertEqual(output.actions, [.commit])
        XCTAssertTrue(output.consumesKey)
        XCTAssertFalse(sut.isCapturing)
    }

    func test_listCommit_withoutRows_cancelsWithoutConsuming() {
        var sut = ClipboardCommandTriggerStateMachine()
        openHint(&sut)
        _ = sut.reduce(.commitKey, selectableCount: 0)   // -> list
        let output = sut.reduce(.commitKey, selectableCount: 0)
        XCTAssertEqual(output.actions, [.cancel])
        XCTAssertFalse(output.consumesKey)
    }

    func test_listEscape_cancelsAndConsumes() {
        var sut = ClipboardCommandTriggerStateMachine()
        openHint(&sut)
        _ = sut.reduce(.commitKey, selectableCount: 0)   // -> list
        let output = sut.reduce(.escape, selectableCount: 3)
        XCTAssertEqual(output.actions, [.cancel])
        XCTAssertTrue(output.consumesKey)
    }

    func test_listCharacter_closesWithoutConsuming() {
        var sut = ClipboardCommandTriggerStateMachine()
        openHint(&sut)
        _ = sut.reduce(.commitKey, selectableCount: 0)   // -> list
        let output = sut.reduce(.character("a"), selectableCount: 3)
        XCTAssertEqual(output.actions, [.cancel])
        XCTAssertFalse(output.consumesKey)
        XCTAssertFalse(sut.isCapturing)
    }

    func test_uppercaseCommand_opensHint() {
        var sut = ClipboardCommandTriggerStateMachine()
        _ = sut.reduce(.character("/"), selectableCount: 0)
        _ = sut.reduce(.character("C"), selectableCount: 0)
        let output = sut.reduce(.character("B"), selectableCount: 0)
        XCTAssertEqual(output.actions, [.openHint])
        XCTAssertTrue(sut.isCapturing)
    }
}
