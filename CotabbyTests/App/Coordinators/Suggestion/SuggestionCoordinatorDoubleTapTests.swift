import CoreGraphics
import Foundation
import XCTest
@testable import Cotabby

/// Drives real Accept Word key events through the coordinator to pin the double-tap contract: the
/// first press always takes one word, a quick second press on the same suggestion takes the rest,
/// and anything else (setting off, a slow press, an intervening key) keeps word-by-word acceptance.
///
/// The rig's host never publishes inserted text, so every accept reconciles against the original
/// "Hello " and drops the chunk's leading space; the expected chunks below reflect that.
@MainActor
final class SuggestionCoordinatorDoubleTapTests: XCTestCase {
    private let tab = CapturedInputEvent(kind: .acceptance, keyCode: 48, characters: "\t", flags: [])
    private let heldTab = CapturedInputEvent(kind: .acceptance, keyCode: 48, characters: "\t", flags: [], isAutorepeat: true)

    func testQuickSecondPressAcceptsTheRestOfTheSuggestion() async {
        let rig = await makeReadyRig(doubleTapEnabled: true)
        defer { rig.coordinator.stop() }

        XCTAssertTrue(rig.coordinator.handleInputEvent(tab))
        XCTAssertEqual(rig.inserter.insertedChunks, ["world"])

        XCTAssertTrue(rig.coordinator.handleInputEvent(tab))
        XCTAssertEqual(rig.inserter.insertedChunks, ["world", "again tomorrow"])
        XCTAssertNil(rig.interactionState.activeSession, "The pair must exhaust the suggestion")
    }

    func testSettingOffKeepsWordByWordAcceptance() async {
        let rig = await makeReadyRig(doubleTapEnabled: false)
        defer { rig.coordinator.stop() }

        XCTAssertTrue(rig.coordinator.handleInputEvent(tab))
        XCTAssertTrue(rig.coordinator.handleInputEvent(tab))

        XCTAssertEqual(rig.inserter.insertedChunks, ["world", "again"])
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, " tomorrow")
    }

    func testSecondPressAfterTheWindowAcceptsOnlyTheNextWord() async {
        let rig = await makeReadyRig(doubleTapEnabled: true)
        defer { rig.coordinator.stop() }

        XCTAssertTrue(rig.coordinator.handleInputEvent(tab))
        // Backdate the first press past the window instead of sleeping in the test.
        guard let session = rig.interactionState.activeSession else {
            return XCTFail("Expected the suggestion to remain active after one word")
        }
        rig.coordinator.doubleTapAcceptanceState.recordWordAccept(
            of: .init(session: session),
            at: ProcessInfo.processInfo.systemUptime - DoubleTapAcceptanceState.window - 1
        )

        XCTAssertTrue(rig.coordinator.handleInputEvent(tab))
        XCTAssertEqual(rig.inserter.insertedChunks, ["world", "again"])
    }

    func testInterveningKeyCancelsThePendingDoubleTap() async {
        let rig = await makeReadyRig(doubleTapEnabled: true)
        defer { rig.coordinator.stop() }

        XCTAssertTrue(rig.coordinator.handleInputEvent(tab))
        // A modifier-only or unmapped key leaves the suggestion alone but still breaks the pair.
        _ = rig.coordinator.handleInputEvent(
            CapturedInputEvent(kind: .other, keyCode: 56, characters: "", flags: .maskShift)
        )

        XCTAssertFalse(rig.coordinator.doubleTapAcceptanceState.hasPendingPress)
    }

    func testHeldKeyRepeatsAcceptWordByWordWithoutDoubleTapping() async {
        let rig = await makeReadyRig(doubleTapEnabled: true, completion: "world again tomorrow morning")
        defer { rig.coordinator.stop() }

        XCTAssertTrue(rig.coordinator.handleInputEvent(tab))
        // Key repeat lands well inside the window, but holding the key is one long press: the
        // repeat takes one more word, as holding Tab always has, and does not finish the pair.
        XCTAssertTrue(rig.coordinator.handleInputEvent(heldTab))
        XCTAssertEqual(rig.inserter.insertedChunks, ["world", "again"])
        XCTAssertFalse(rig.coordinator.doubleTapAcceptanceState.hasPendingPress)

        // Nor does the repeat arm a pair, so the next real press is a first press again.
        XCTAssertTrue(rig.coordinator.handleInputEvent(tab))
        XCTAssertEqual(rig.inserter.insertedChunks, ["world", "again", "tomorrow"])
    }

    private func makeReadyRig(
        doubleTapEnabled: Bool,
        completion: String = "world again tomorrow"
    ) async -> CoordinatorRig {
        let rig = makeCoordinatorRig(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello "),
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(
                debounceMilliseconds: 1,
                doubleTapAcceptsEntireSuggestion: doubleTapEnabled
            )
        )
        rig.engine.resultProvider = { request in
            SuggestionResult(generation: request.generation, rawText: completion, text: completion, latency: 0.01)
        }
        rig.coordinator.schedulePrediction()
        await waitUntil { rig.interactionState.activeSession != nil }
        return rig
    }
}
