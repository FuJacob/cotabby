import XCTest
@testable import Cotabby

/// Pins the Settings window's navigation state machine: search reveals land on the item's own pane
/// with a transient highlight, plain pane navigation cancels that highlight so a stale pulse cannot
/// replay, and Cmd-F routes to Home and leaves a one-shot focus request. The timed auto-clear of the
/// highlight is deliberately not waited on here; only the synchronous transitions are asserted.
@MainActor
final class SettingsNavigationModelTests: XCTestCase {
    /// Models live as long as the test case instance rather than dying at the end of each test body:
    /// freeing a `@MainActor` model inside the body crashes the CI test host (macOS 15 runtime) with
    /// "pointer being freed was not allocated", the same reason other suites hold their subjects in
    /// stored properties.
    private var models: [SettingsNavigationModel] = []

    private func makeModel() -> SettingsNavigationModel {
        let model = SettingsNavigationModel()
        models.append(model)
        return model
    }

    func test_startsOnHomeWithNothingPending() {
        let model = makeModel()

        XCTAssertEqual(model.selection, .home)
        XCTAssertNil(model.highlightedItem)
        XCTAssertFalse(model.pendingSearchFocus)
    }

    func test_revealSelectsTheItemsPaneAndHighlightsIt() {
        let model = makeModel()

        model.reveal(.batteryModel)

        XCTAssertEqual(model.selection, .engineAndModel)
        XCTAssertEqual(model.highlightedItem, .batteryModel)
    }

    func test_secondRevealReplacesTheHighlightAndPane() {
        let model = makeModel()
        model.reveal(.batteryModel)

        model.reveal(.ghostTextSize)

        XCTAssertEqual(model.selection, .appearance)
        XCTAssertEqual(model.highlightedItem, .ghostTextSize)
    }

    func test_openingAPaneCancelsAnActiveHighlight() {
        let model = makeModel()
        model.reveal(.batteryModel)

        model.open(.about)

        XCTAssertEqual(model.selection, .about)
        XCTAssertNil(model.highlightedItem, "A manual pane switch must drop the search pulse immediately")
    }

    func test_searchFocusRequestFromAnotherPaneGoesHomeAndClearsHighlight() {
        let model = makeModel()
        model.reveal(.batteryModel)

        model.requestSearchFocus()

        XCTAssertEqual(model.selection, .home)
        XCTAssertNil(model.highlightedItem)
        XCTAssertTrue(model.pendingSearchFocus)
    }

    func test_searchFocusRequestIsOneShot() {
        let model = makeModel()

        model.requestSearchFocus()
        XCTAssertEqual(model.selection, .home)
        XCTAssertTrue(model.pendingSearchFocus)

        model.consumeSearchFocusRequest()
        XCTAssertFalse(model.pendingSearchFocus, "Home clears the request so a later visit does not steal focus")
    }
}
