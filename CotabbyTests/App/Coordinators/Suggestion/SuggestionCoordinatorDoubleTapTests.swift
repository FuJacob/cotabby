import CoreGraphics
import Foundation
import XCTest
@testable import Cotabby

/// Drives real Accept Word key events through the coordinator to pin the double-tap contract: the
/// first press always takes one word, a quick second press on the same suggestion takes the rest,
/// and anything else (setting off, a slow press, an intervening key, a held key, an app with its own
/// Accept Entire Suggestion binding) keeps word-by-word acceptance.
///
/// The rig's host never publishes inserted text, so every accept reconciles against the original
/// "Hello " and drops the chunk's leading space; the expected chunks below reflect that. Press
/// timing comes from a manual clock, so no assertion depends on how fast the runner executes.
@MainActor
final class SuggestionCoordinatorDoubleTapTests: XCTestCase {
    /// Reference box, so the coordinator's clock closure reads whatever time the test sets.
    private final class ManualClock {
        var now: TimeInterval = 1_000
    }

    private let clock = ManualClock()
    private let appBundleIdentifier = "com.example.TestApp"
    private let tab = CapturedInputEvent(kind: .acceptance, keyCode: 48, characters: "\t", flags: [])
    private let heldTab = CapturedInputEvent(kind: .acceptance, keyCode: 48, characters: "\t", flags: [], isAutorepeat: true)

    func testQuickSecondPressAcceptsTheRestOfTheSuggestion() async {
        let rig = await makeReadyRig(doubleTapEnabled: true)
        defer { rig.coordinator.stop() }

        XCTAssertTrue(rig.coordinator.handleInputEvent(tab))
        XCTAssertEqual(rig.inserter.insertedChunks, ["world"])

        clock.now += 0.1
        XCTAssertTrue(rig.coordinator.handleInputEvent(tab))
        XCTAssertEqual(rig.inserter.insertedChunks, ["world", "again tomorrow"])
        XCTAssertNil(rig.interactionState.activeSession, "The pair must exhaust the suggestion")
    }

    func testSettingOffKeepsWordByWordAcceptance() async {
        let rig = await makeReadyRig(doubleTapEnabled: false)
        defer { rig.coordinator.stop() }

        XCTAssertTrue(rig.coordinator.handleInputEvent(tab))
        clock.now += 0.1
        XCTAssertTrue(rig.coordinator.handleInputEvent(tab))

        XCTAssertEqual(rig.inserter.insertedChunks, ["world", "again"])
        XCTAssertEqual(rig.interactionState.activeSession?.remainingText, " tomorrow")
    }

    func testSecondPressAfterTheWindowAcceptsOnlyTheNextWord() async {
        let rig = await makeReadyRig(doubleTapEnabled: true)
        defer { rig.coordinator.stop() }

        XCTAssertTrue(rig.coordinator.handleInputEvent(tab))
        clock.now += DoubleTapAcceptanceState.window + 0.05
        XCTAssertTrue(rig.coordinator.handleInputEvent(tab))

        XCTAssertEqual(rig.inserter.insertedChunks, ["world", "again"])
    }

    func testInterveningKeyCancelsThePendingDoubleTap() async {
        let rig = await makeReadyRig(doubleTapEnabled: true)
        defer { rig.coordinator.stop() }

        XCTAssertTrue(rig.coordinator.handleInputEvent(tab))
        // Shift-Tab matches neither accept binding, so it arrives as `.other`: the suggestion stays
        // on screen, but the Tabs on either side of it are no longer one double tap.
        XCTAssertFalse(rig.coordinator.handleInputEvent(
            CapturedInputEvent(kind: .other, keyCode: 48, characters: "", flags: .maskShift)
        ))
        clock.now += 0.1
        XCTAssertTrue(rig.coordinator.handleInputEvent(tab))

        XCTAssertEqual(rig.inserter.insertedChunks, ["world", "again"])
    }

    func testHeldKeyRepeatsAcceptWordByWordWithoutDoubleTapping() async {
        let rig = await makeReadyRig(doubleTapEnabled: true, completion: "world again tomorrow morning")
        defer { rig.coordinator.stop() }

        XCTAssertTrue(rig.coordinator.handleInputEvent(tab))
        // Key repeat lands well inside the window, but holding the key is one long press: the
        // repeat takes one more word, as holding Tab always has, and does not finish the pair.
        clock.now += 0.05
        XCTAssertTrue(rig.coordinator.handleInputEvent(heldTab))
        XCTAssertEqual(rig.inserter.insertedChunks, ["world", "again"])

        // Nor does the first press stay armed behind the repeat, so the next real press, still
        // inside the window of that first press, is a first press again.
        clock.now += 0.05
        XCTAssertTrue(rig.coordinator.handleInputEvent(tab))
        XCTAssertEqual(rig.inserter.insertedChunks, ["world", "again", "tomorrow"])
    }

    func testAppWithItsOwnFullAcceptBindingKeepsWordByWordAcceptance() async {
        // An app's own Accept Entire Suggestion binding (a key, or Disable) replaces the global
        // slot that holds the double tap, so in that app the pair stays two single-word accepts.
        let rig = await makeReadyRig(doubleTapEnabled: true, fullAcceptanceOverrides: [appBundleIdentifier])
        defer { rig.coordinator.stop() }

        XCTAssertTrue(rig.coordinator.handleInputEvent(tab))
        clock.now += 0.1
        XCTAssertTrue(rig.coordinator.handleInputEvent(tab))

        XCTAssertEqual(rig.inserter.insertedChunks, ["world", "again"])
    }

    func testOtherAppsFullAcceptBindingsLeaveThisAppsDoubleTapAlone() async {
        let rig = await makeReadyRig(doubleTapEnabled: true, fullAcceptanceOverrides: ["com.apple.Terminal"])
        defer { rig.coordinator.stop() }

        XCTAssertTrue(rig.coordinator.handleInputEvent(tab))
        clock.now += 0.1
        XCTAssertTrue(rig.coordinator.handleInputEvent(tab))

        XCTAssertEqual(rig.inserter.insertedChunks, ["world", "again tomorrow"])
    }

    private func makeReadyRig(
        doubleTapEnabled: Bool,
        completion: String = "world again tomorrow",
        fullAcceptanceOverrides: Set<String> = []
    ) async -> CoordinatorRig {
        let rig = makeCoordinatorRig(
            snapshot: CotabbyTestFixtures.focusedInputSnapshot(
                bundleIdentifier: appBundleIdentifier,
                precedingText: "Hello "
            ),
            settingsSnapshot: CotabbyTestFixtures.settingsSnapshot(
                debounceMilliseconds: 1,
                doubleTapAcceptsEntireSuggestion: doubleTapEnabled,
                fullAcceptanceOverrideBundleIdentifiers: fullAcceptanceOverrides
            )
        )
        let clock = clock
        rig.coordinator.doubleTapUptimeProvider = { clock.now }
        rig.engine.resultProvider = { request in
            SuggestionResult(generation: request.generation, rawText: completion, text: completion, latency: 0.01)
        }
        rig.coordinator.schedulePrediction()
        await waitUntil { rig.interactionState.activeSession != nil }
        return rig
    }
}
