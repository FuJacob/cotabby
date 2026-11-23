import CoreGraphics
import XCTest
@testable import Cotabby

/// Tests for the small adapter between coordinator intent and overlay-controller calls.
@MainActor
final class SuggestionOverlayPresenterTests: XCTestCase {
    func test_presentEmptyTextHidesOverlay() {
        let overlayController = RigOverlayController()
        let presenter = SuggestionOverlayPresenter(overlayController: overlayController)

        let changed = presenter.present(
            text: "   ",
            geometry: CotabbyTestFixtures.overlayGeometry(caretRect: .zero),
            previousState: overlayController.state
        )

        XCTAssertTrue(changed)
        XCTAssertEqual(overlayController.hideReasons, ["Overlay hidden because the suggestion text was empty."])
        XCTAssertEqual(overlayController.shownTexts, [])
    }

    func test_presentNewTextShowsOverlay() {
        let overlayController = RigOverlayController()
        let presenter = SuggestionOverlayPresenter(overlayController: overlayController)
        let geometry = CotabbyTestFixtures.overlayGeometry(caretRect: CGRect(x: 10, y: 20, width: 2, height: 18))

        let changed = presenter.present(text: " world", geometry: geometry, previousState: overlayController.state)

        XCTAssertTrue(changed)
        XCTAssertEqual(overlayController.shownTexts, [" world"])
        XCTAssertEqual(overlayController.state, .visible(text: " world", geometry: geometry, mode: .inline))
    }

    func test_presentIdenticalVisibleStateDoesNotCallOverlayAgain() {
        let geometry = CotabbyTestFixtures.overlayGeometry(caretRect: CGRect(x: 10, y: 20, width: 2, height: 18))
        let overlayController = RigOverlayController(state: .visible(text: " world", geometry: geometry, mode: .inline))
        let presenter = SuggestionOverlayPresenter(overlayController: overlayController)

        let changed = presenter.present(text: " world", geometry: geometry, previousState: overlayController.state)

        XCTAssertFalse(changed)
        XCTAssertEqual(overlayController.shownTexts, [])
    }

    func test_presentSameTextAtNewCaretShowsAgain() {
        let overlayController = RigOverlayController()
        let presenter = SuggestionOverlayPresenter(overlayController: overlayController)
        let nextGeometry = CotabbyTestFixtures.overlayGeometry(caretRect: CGRect(x: 30, y: 20, width: 2, height: 18))

        let changed = presenter.present(
            text: " world",
            geometry: nextGeometry,
            previousState: .visible(
                text: " world",
                geometry: CotabbyTestFixtures.overlayGeometry(caretRect: CGRect(x: 10, y: 20, width: 2, height: 18)),
                mode: .inline
            )
        )

        XCTAssertTrue(changed)
        XCTAssertEqual(overlayController.shownTexts, [" world"])
        XCTAssertEqual(overlayController.state, .visible(text: " world", geometry: nextGeometry, mode: .inline))
    }

    func test_presentSameTextAndCaretWithNewQualityShowsAgain() {
        let caretRect = CGRect(x: 10, y: 20, width: 2, height: 18)
        let overlayController = RigOverlayController()
        let presenter = SuggestionOverlayPresenter(overlayController: overlayController)

        let changed = presenter.present(
            text: " world",
            geometry: CotabbyTestFixtures.overlayGeometry(caretRect: caretRect, caretQuality: .derived),
            previousState: .visible(
                text: " world",
                geometry: CotabbyTestFixtures.overlayGeometry(caretRect: caretRect),
                mode: .inline
            )
        )

        XCTAssertTrue(changed)
        XCTAssertEqual(overlayController.shownTexts, [" world"])
    }

    func test_hideForwardsReasonToOverlayController() {
        let overlayController = RigOverlayController()
        let presenter = SuggestionOverlayPresenter(overlayController: overlayController)

        presenter.hide(reason: "Overlay hidden for test.")

        XCTAssertEqual(overlayController.hideReasons, ["Overlay hidden for test."])
    }
}
