import CoreGraphics
import Foundation
import XCTest
@testable import Cotabby

/// Pins "Tab Moves to Next Field": with the setting on, a plain Tab bound to Accept Word is handed
/// back to the host in a single-line field, so form navigation works while a suggestion shows.
/// Everything else keeps accepting: the setting off, a multi-line field, a chat or Electron-editor
/// composer that reports a single-line role, the full-accept key, and a modified Tab binding.
@MainActor
final class SuggestionCoordinatorTabFormNavigationTests: XCTestCase {
    private let tab = CapturedInputEvent(kind: .acceptance, keyCode: 48, characters: "\t", flags: [])

    func testPlainTabPassesThroughInSingleLineFieldWhenEnabled() async {
        let rig = await makeReadyRig(role: "AXTextField", tabLeavesSingleLineFields: true)
        defer { rig.coordinator.stop() }

        XCTAssertFalse(rig.coordinator.handleInputEvent(tab), "Tab must reach the host to move focus")
        XCTAssertTrue(rig.inserter.insertedChunks.isEmpty)
        XCTAssertNil(rig.interactionState.activeSession, "The suggestion is dismissed, not left behind")
    }

    func testPlainTabStillAcceptsInSingleLineFieldWhenDisabled() async {
        let rig = await makeReadyRig(role: "AXTextField", tabLeavesSingleLineFields: false)
        defer { rig.coordinator.stop() }

        XCTAssertTrue(rig.coordinator.handleInputEvent(tab))
        XCTAssertEqual(rig.inserter.insertedChunks, ["world"])
    }

    func testPlainTabStillAcceptsInMultiLineFieldWhenEnabled() async {
        let rig = await makeReadyRig(role: "AXTextArea", tabLeavesSingleLineFields: true)
        defer { rig.coordinator.stop() }

        XCTAssertTrue(rig.coordinator.handleInputEvent(tab))
        XCTAssertEqual(rig.inserter.insertedChunks, ["world"])
    }

    func testPlainTabStillAcceptsInChatComposerReportedAsSingleLine() async {
        // Messages' composer reports AXTextField; passing Tab through there inserts a tab character.
        for bundleIdentifier in ["com.apple.MobileSMS", "org.whispersystems.signal-desktop"] {
            let rig = await makeReadyRig(role: "AXTextField", bundleIdentifier: bundleIdentifier, tabLeavesSingleLineFields: true)
            XCTAssertTrue(rig.coordinator.handleInputEvent(tab), bundleIdentifier)
            XCTAssertEqual(rig.inserter.insertedChunks, ["world"], bundleIdentifier)
            rig.coordinator.stop()
        }
    }

    func testPlainTabStillAcceptsInElectronEditorReportedAsSingleLine() async {
        // A one-line contenteditable composer in a named Electron editor reports AXTextField.
        let rig = await makeReadyRig(role: "AXTextField", bundleIdentifier: "md.obsidian", tabLeavesSingleLineFields: true)
        defer { rig.coordinator.stop() }

        XCTAssertTrue(rig.coordinator.handleInputEvent(tab))
        XCTAssertEqual(rig.inserter.insertedChunks, ["world"])
    }

    func testFullAcceptStillWorksInSingleLineFieldWhenEnabled() async {
        let rig = await makeReadyRig(role: "AXTextField", tabLeavesSingleLineFields: true)
        defer { rig.coordinator.stop() }

        let backtick = CapturedInputEvent(kind: .fullAcceptance, keyCode: 50, characters: "`", flags: [])
        XCTAssertTrue(rig.coordinator.handleInputEvent(backtick))
        XCTAssertEqual(rig.inserter.insertedChunks, ["world again tomorrow"])
    }

    func testModifiedTabBindingStillAcceptsInSingleLineFieldWhenEnabled() async {
        let rig = await makeReadyRig(role: "AXTextField", tabLeavesSingleLineFields: true)
        defer { rig.coordinator.stop() }

        // Accept Word rebound to Option-Tab: plain Tab is no longer the accept key, so the setting
        // has nothing to hand back and the binding keeps accepting.
        let optionTab = CapturedInputEvent(kind: .acceptance, keyCode: 48, characters: "\t", flags: .maskAlternate)
        XCTAssertTrue(rig.coordinator.handleInputEvent(optionTab))
        XCTAssertEqual(rig.inserter.insertedChunks, ["world"])
    }

    private func makeReadyRig(
        role: String,
        bundleIdentifier: String = "com.example.TestApp",
        tabLeavesSingleLineFields: Bool
    ) async -> CoordinatorRig {
        let rig = makeCoordinatorRig(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(
                bundleIdentifier: bundleIdentifier,
                role: role,
                precedingText: "Hello "
            ),
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(
                debounceMilliseconds: 1,
                tabLeavesSingleLineFields: tabLeavesSingleLineFields
            )
        )
        rig.engine.resultProvider = { request in
            SuggestionResult(
                generation: request.generation,
                rawText: "world again tomorrow",
                text: "world again tomorrow",
                latency: 0.01
            )
        }
        rig.coordinator.schedulePrediction()
        await waitUntil { rig.interactionState.activeSession != nil }
        return rig
    }
}
