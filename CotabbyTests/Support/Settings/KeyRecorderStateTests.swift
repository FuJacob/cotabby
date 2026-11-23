import CoreGraphics
import XCTest
@testable import Cotabby

/// Pins what a shortcut recorder does with each key event: commit, cancel, refuse and keep
/// listening, or wait for the second half of a double tap. These rules used to live inside the
/// view's `NSEvent` handler, where nothing could exercise them.
@MainActor
final class KeyRecorderStateTests: XCTestCase {
    private let tab = DoubleTapRecordingKey(keyCode: 48, modifiers: [], label: "Tab")
    private let window = DoubleTapAcceptanceState.window

    private func press(
        _ keyCode: CGKeyCode,
        modifiers: ShortcutModifierMask = [],
        isRepeat: Bool = false,
        at timestamp: TimeInterval = 10
    ) -> KeyRecorderState.Input {
        .keyDown(.init(keyCode: keyCode, modifiers: modifiers, isRepeat: isRepeat, timestamp: timestamp))
    }

    /// Mirrors a recorder for Accept Entire Suggestion: Tab (Accept Word) is taken, everything else is free.
    private func send(
        _ input: KeyRecorderState.Input,
        to state: inout KeyRecorderState,
        doubleTapKey: DoubleTapRecordingKey? = nil
    ) -> KeyRecorderState.Effect? {
        state.handle(input, doubleTapKey: doubleTapKey) { keyCode, modifiers in
            keyCode == 48 && modifiers.isEmpty ? "Accept Word" : nil
        }
    }

    func test_freeKeyCommitsWithItsModifiers() {
        var state = KeyRecorderState()

        XCTAssertEqual(send(press(36, modifiers: [.command]), to: &state), .commit(keyCode: 36, modifiers: [.command]))
    }

    func test_conflictIsRefusedAndTheRecorderKeepsListening() {
        var state = KeyRecorderState()

        XCTAssertNil(send(press(48), to: &state))
        XCTAssertTrue(state.isRejected)
        XCTAssertEqual(state.prompt(doubleTapKey: nil), "Already used by Accept Word. Try another key.")

        // The next free key still records, so the user never has to restart the recorder.
        XCTAssertEqual(send(press(36), to: &state), .commit(keyCode: 36, modifiers: []))
        XCTAssertFalse(state.isRejected)
    }

    func test_plainEscapeCancelsButModifiedEscapeIsBindable() {
        var state = KeyRecorderState()

        XCTAssertEqual(send(press(KeyRecorderState.escapeKeyCode), to: &state), .cancel)
        XCTAssertEqual(
            send(press(KeyRecorderState.escapeKeyCode, modifiers: [.command]), to: &state),
            .commit(keyCode: KeyRecorderState.escapeKeyCode, modifiers: [.command])
        )
    }

    func test_heldModifiersArePreviewedInThePrompt() {
        var state = KeyRecorderState()
        XCTAssertEqual(state.prompt(doubleTapKey: nil), "Press a key…")

        XCTAssertNil(send(.modifiersChanged([.command, .shift]), to: &state))

        XCTAssertEqual(state.liveModifiers, [.command, .shift])
        XCTAssertEqual(state.prompt(doubleTapKey: nil), "\(KeyCodeLabels.modifierGlyphs([.command, .shift])) + key…")
    }

    func test_secondPressInsideTheWindowCommitsTheDoubleTap() {
        var state = KeyRecorderState()

        XCTAssertEqual(
            send(press(48, at: 10), to: &state, doubleTapKey: tab),
            .scheduleSecondTapTimeout(firstTapTimestamp: 10)
        )
        XCTAssertEqual(state.phase, .awaitingSecondTap(firstTapTimestamp: 10))
        XCTAssertEqual(state.prompt(doubleTapKey: tab), "Press Tab again…")

        XCTAssertEqual(send(press(48, at: 10 + window / 2), to: &state, doubleTapKey: tab), .commitDoubleTap)
    }

    func test_autoRepeatOfTheDoubleTapKeyIsNotASecondPress() {
        var state = KeyRecorderState()
        _ = send(press(48, at: 10), to: &state, doubleTapKey: tab)

        XCTAssertNil(send(press(48, isRepeat: true, at: 10.05), to: &state, doubleTapKey: tab))

        XCTAssertEqual(state.phase, .awaitingSecondTap(firstTapTimestamp: 10), "a held key must not complete or restart the pair")
    }

    func test_timeoutTurnsALoneFirstPressIntoAConflictThatPointsAtTheDoubleTap() {
        var state = KeyRecorderState()
        _ = send(press(48, at: 10), to: &state, doubleTapKey: tab)

        XCTAssertNil(send(.secondTapTimedOut(firstTapTimestamp: 10), to: &state, doubleTapKey: tab))

        XCTAssertEqual(
            state.prompt(doubleTapKey: tab),
            "Already used by Accept Word. Press it twice quickly for a double tap."
        )
    }

    func test_staleTimeoutIsIgnored() {
        var state = KeyRecorderState()
        _ = send(press(48, at: 10), to: &state, doubleTapKey: tab)
        // Too slow to pair with the first press, so this press starts its own wait.
        XCTAssertEqual(
            send(press(48, at: 10 + window + 0.2), to: &state, doubleTapKey: tab),
            .scheduleSecondTapTimeout(firstTapTimestamp: 10 + window + 0.2)
        )

        XCTAssertNil(send(.secondTapTimedOut(firstTapTimestamp: 10), to: &state, doubleTapKey: tab))

        XCTAssertEqual(state.phase, .awaitingSecondTap(firstTapTimestamp: 10 + window + 0.2))
        XCTAssertFalse(state.isRejected)
    }

    func test_anotherKeyAbandonsThePendingDoubleTap() {
        var state = KeyRecorderState()
        _ = send(press(48, at: 10), to: &state, doubleTapKey: tab)

        XCTAssertEqual(send(press(36, at: 10.1), to: &state, doubleTapKey: tab), .commit(keyCode: 36, modifiers: []))
        XCTAssertNil(send(.secondTapTimedOut(firstTapTimestamp: 10), to: &state, doubleTapKey: tab))
        XCTAssertFalse(state.isRejected, "the abandoned press's timeout must not surface an error")
    }

    func test_withoutADoubleTapKeyASinglePressOfATakenKeyIsJustAConflict() {
        var state = KeyRecorderState()

        XCTAssertNil(send(press(48), to: &state, doubleTapKey: nil))

        XCTAssertEqual(state.phase, .rejected(message: "Already used by Accept Word. Try another key."))
    }
}
