import CoreGraphics
import XCTest
@testable import Cotabby

/// The transition table for the Accept Word key and the Accept Entire Suggestion slot, plus the
/// mapping between the slot and the two facts it is persisted as. The model-level behavior is
/// covered by `SuggestionSettingsModelDoubleTapTests`; these pin the pure rules it is built on.
@MainActor
final class AcceptanceShortcutsTests: XCTestCase {
    private typealias ShortcutBinding = SuggestionShortcutBindingSettings

    private let tab = ShortcutBinding(keyCode: 48, modifiers: [], label: "Tab")
    private let grave = ShortcutBinding(keyCode: 50, modifiers: [], label: "`")
    private let optionTab = ShortcutBinding(keyCode: 48, modifiers: [.option], label: "⌥ Tab")

    private func shortcuts(_ acceptEntireSuggestion: FullAcceptanceShortcut) -> AcceptanceShortcuts {
        AcceptanceShortcuts(acceptWord: tab, acceptEntireSuggestion: acceptEntireSuggestion)
    }

    // MARK: - Bindings

    func test_recordedUnboundKeyDropsItsModifiers() {
        let binding = ShortcutBinding(
            recordedKeyCode: SuggestionSettingsStore.disabledKeyCode,
            modifiers: [.command],
            label: SuggestionSettingsStore.disabledKeyLabel
        )

        XCTAssertEqual(binding, .unbound)
        XCTAssertFalse(binding.isBound)
        XCTAssertEqual(ShortcutBinding(recordedKeyCode: 48, modifiers: [.option], label: "⌥ Tab"), optionTab)
    }

    func test_matchesComparesKeyAndModifiersAndNeverMatchesWhenUnbound() {
        XCTAssertTrue(optionTab.matches(keyCode: 48, modifiers: [.option]))
        XCTAssertFalse(optionTab.matches(keyCode: 48, modifiers: []))
        XCTAssertFalse(ShortcutBinding.unbound.matches(keyCode: SuggestionSettingsStore.disabledKeyCode, modifiers: []))
    }

    // MARK: - Persisted shape

    func test_slotDecodesFromThePersistedKeyAndFlag() {
        XCTAssertEqual(FullAcceptanceShortcut(keyBinding: grave, doubleTap: false), .key(grave))
        XCTAssertEqual(FullAcceptanceShortcut(keyBinding: .unbound, doubleTap: false), .unbound)
        XCTAssertEqual(FullAcceptanceShortcut(keyBinding: .unbound, doubleTap: true), .doubleTapOfAcceptWord)
    }

    func test_slotEncodesBackToTheSamePersistedKeyAndFlag() {
        let cases: [(FullAcceptanceShortcut, ShortcutBinding, Bool)] = [
            (.unbound, .unbound, false),
            (.key(grave), grave, false),
            (.doubleTapOfAcceptWord, .unbound, true)
        ]
        for (slot, keyBinding, doubleTap) in cases {
            XCTAssertEqual(slot.keyBinding, keyBinding)
            XCTAssertEqual(slot.isDoubleTap, doubleTap)
            XCTAssertEqual(FullAcceptanceShortcut(keyBinding: slot.keyBinding, doubleTap: slot.isDoubleTap), slot)
        }
    }

    // MARK: - Transitions

    func test_recordingAOnePressKeyTakesTheSlotFromTheDoubleTap() {
        var state = shortcuts(.doubleTapOfAcceptWord)

        state.recordAcceptEntireSuggestion(optionTab)

        XCTAssertEqual(state.acceptEntireSuggestion, .key(optionTab))
        XCTAssertEqual(state.acceptWord, tab, "a different modifier set is a different shortcut")
    }

    func test_recordingTheAcceptWordKeyAsTheOnePressKeyUnbindsAcceptWord() {
        var state = shortcuts(.key(grave))

        state.recordAcceptEntireSuggestion(tab)

        XCTAssertEqual(state.acceptEntireSuggestion, .key(tab))
        XCTAssertEqual(state.acceptWord, .unbound)
    }

    func test_recordingNoKeyRemovesAOnePressKeyButLeavesTheDoubleTap() {
        var withKey = shortcuts(.key(grave))
        withKey.recordAcceptEntireSuggestion(.unbound)
        XCTAssertEqual(withKey.acceptEntireSuggestion, .unbound)

        var withDoubleTap = shortcuts(.doubleTapOfAcceptWord)
        withDoubleTap.recordAcceptEntireSuggestion(.unbound)
        XCTAssertEqual(withDoubleTap.acceptEntireSuggestion, .doubleTapOfAcceptWord)
    }

    func test_recordingTheOnePressKeyAsAcceptWordEmptiesTheSlot() {
        var state = shortcuts(.key(grave))

        state.recordAcceptWord(grave)

        XCTAssertEqual(state.acceptWord, grave)
        XCTAssertEqual(state.acceptEntireSuggestion, .unbound)
    }

    func test_changingAcceptWordKeepsTheDoubleTapAndItsLabelFollows() {
        var state = shortcuts(.doubleTapOfAcceptWord)

        state.recordAcceptWord(ShortcutBinding(keyCode: 36, modifiers: [], label: "Return"))

        XCTAssertEqual(state.acceptEntireSuggestion, .doubleTapOfAcceptWord)
        XCTAssertEqual(state.acceptEntireSuggestionDisplayLabel, "Return Return")
    }

    func test_doubleTapNeedsAnAcceptWordKey() {
        var state = AcceptanceShortcuts(acceptWord: .unbound, acceptEntireSuggestion: .key(grave))

        state.recordDoubleTap()

        XCTAssertEqual(state.acceptEntireSuggestion, .key(grave), "the one-press key must survive the refused bind")
    }

    func test_clearingAcceptWordTakesTheDoubleTapWithItButNotAOnePressKey() {
        var withDoubleTap = shortcuts(.doubleTapOfAcceptWord)
        withDoubleTap.clearAcceptWord()
        XCTAssertEqual(withDoubleTap, AcceptanceShortcuts(acceptWord: .unbound, acceptEntireSuggestion: .unbound))

        var withKey = shortcuts(.key(grave))
        withKey.clearAcceptWord()
        XCTAssertEqual(withKey, AcceptanceShortcuts(acceptWord: .unbound, acceptEntireSuggestion: .key(grave)))
    }

    func test_clearingTheSlotLeavesAcceptWordAlone() {
        var state = shortcuts(.doubleTapOfAcceptWord)

        state.clearAcceptEntireSuggestion()

        XCTAssertEqual(state, shortcuts(.unbound))
    }

    func test_resettingEachSideRestoresItsFactoryKey() {
        var state = AcceptanceShortcuts(acceptWord: optionTab, acceptEntireSuggestion: .doubleTapOfAcceptWord)

        state.resetAcceptWord()
        state.resetAcceptEntireSuggestion()

        XCTAssertEqual(state, AcceptanceShortcuts(acceptWord: tab, acceptEntireSuggestion: .key(grave)))
        XCTAssertTrue(state.isAcceptWordFactoryDefault)
        XCTAssertTrue(state.isAcceptEntireSuggestionFactoryDefault)
    }

    /// Reset is a recording of the factory key, so it obeys the same "no shared key" rule.
    func test_resettingAcceptWordTakesTabBackFromTheSlot() {
        var state = AcceptanceShortcuts(acceptWord: .unbound, acceptEntireSuggestion: .key(tab))

        state.resetAcceptWord()

        XCTAssertEqual(state, AcceptanceShortcuts(acceptWord: tab, acceptEntireSuggestion: .unbound))
    }

    // MARK: - Reading

    func test_doubleTapIsInertWhileAcceptWordIsUnbound() {
        let state = AcceptanceShortcuts(acceptWord: .unbound, acceptEntireSuggestion: .doubleTapOfAcceptWord)

        XCTAssertFalse(state.isDoubleTapActive)
        XCTAssertFalse(state.hasAcceptEntireSuggestionShortcut)
        XCTAssertEqual(state.acceptEntireSuggestionDisplayLabel, SuggestionSettingsStore.disabledKeyLabel)
    }

    func test_onlyTheFactoryOnePressKeyCountsAsDefault() {
        XCTAssertTrue(shortcuts(.key(grave)).isAcceptEntireSuggestionFactoryDefault)
        XCTAssertFalse(shortcuts(.key(optionTab)).isAcceptEntireSuggestionFactoryDefault)
        XCTAssertFalse(shortcuts(.doubleTapOfAcceptWord).isAcceptEntireSuggestionFactoryDefault)
        XCTAssertFalse(shortcuts(.unbound).isAcceptEntireSuggestionFactoryDefault)
    }

    /// The label is display-only: Tab recorded under another layout's name is still the factory key.
    func test_onlyPlainTabCountsAsTheFactoryAcceptWordKey() {
        let relabelledTab = ShortcutBinding(keyCode: 48, modifiers: [], label: "⇥")
        XCTAssertTrue(AcceptanceShortcuts(acceptWord: relabelledTab, acceptEntireSuggestion: .unbound).isAcceptWordFactoryDefault)
        XCTAssertFalse(AcceptanceShortcuts(acceptWord: optionTab, acceptEntireSuggestion: .unbound).isAcceptWordFactoryDefault)
        XCTAssertFalse(AcceptanceShortcuts(acceptWord: .unbound, acceptEntireSuggestion: .unbound).isAcceptWordFactoryDefault)
    }

    func test_doubleTapRecordingKeyIsTheAcceptWordKeyOnlyWhileBound() {
        XCTAssertEqual(shortcuts(.key(grave)).doubleTapRecordingKey, tab)
        XCTAssertNil(AcceptanceShortcuts(acceptWord: .unbound, acceptEntireSuggestion: .key(grave)).doubleTapRecordingKey)
    }
}
