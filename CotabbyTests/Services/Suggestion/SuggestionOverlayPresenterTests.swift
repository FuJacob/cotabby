import CoreGraphics
import XCTest
@testable import Cotabby

/// Tests for the small adapter between coordinator intent and overlay-controller calls.
final class SuggestionOverlayPresenterTests: XCTestCase {
    func test_presentEmptyTextHidesOverlay() {
        runOnMainActor {
            let overlayController = FakeOverlayController()
            let presenter = SuggestionOverlayPresenter(overlayController: overlayController)

            let changed = presenter.present(
                text: "   ",
                geometry: CotabbyTestFixtures.overlayGeometry(caretRect: .zero),
                previousState: overlayController.state
            )

            XCTAssertTrue(changed)
            XCTAssertEqual(overlayController.hideReasons, ["Overlay hidden because the suggestion text was empty."])
            XCTAssertEqual(overlayController.showCallCount, 0)
        }
    }

    func test_presentNewTextShowsOverlay() {
        runOnMainActor {
            let overlayController = FakeOverlayController()
            let presenter = SuggestionOverlayPresenter(overlayController: overlayController)
            let caretRect = CGRect(x: 10, y: 20, width: 2, height: 18)

            let changed = presenter.present(
                text: " world",
                geometry: CotabbyTestFixtures.overlayGeometry(caretRect: caretRect),
                previousState: overlayController.state
            )

            XCTAssertTrue(changed)
            XCTAssertEqual(overlayController.lastShownText, " world")
            XCTAssertEqual(overlayController.lastShownCaretRect, caretRect)
            XCTAssertEqual(overlayController.showCallCount, 1)
        }
    }

    func test_presentIdenticalVisibleStateDoesNotCallOverlayAgain() {
        runOnMainActor {
            let caretRect = CGRect(x: 10, y: 20, width: 2, height: 18)
            let geometry = CotabbyTestFixtures.overlayGeometry(caretRect: caretRect)
            let overlayController = FakeOverlayController(
                initialState: .visible(text: " world", geometry: geometry, mode: .inline)
            )
            let presenter = SuggestionOverlayPresenter(overlayController: overlayController)

            let changed = presenter.present(
                text: " world",
                geometry: geometry,
                previousState: overlayController.state
            )

            XCTAssertFalse(changed)
            XCTAssertEqual(overlayController.showCallCount, 0)
        }
    }

    func test_presentSameTextAtNewCaretShowsAgain() {
        runOnMainActor {
            let previousRect = CGRect(x: 10, y: 20, width: 2, height: 18)
            let nextRect = CGRect(x: 30, y: 20, width: 2, height: 18)
            let overlayController = FakeOverlayController()
            let presenter = SuggestionOverlayPresenter(overlayController: overlayController)

            let changed = presenter.present(
                text: " world",
                geometry: CotabbyTestFixtures.overlayGeometry(caretRect: nextRect),
                previousState: .visible(
                    text: " world",
                    geometry: CotabbyTestFixtures.overlayGeometry(caretRect: previousRect),
                    mode: .inline
                )
            )

            XCTAssertTrue(changed)
            XCTAssertEqual(overlayController.lastShownCaretRect, nextRect)
            XCTAssertEqual(overlayController.showCallCount, 1)
        }
    }

    func test_presentSameTextAndCaretWithNewQualityShowsAgain() {
        runOnMainActor {
            let caretRect = CGRect(x: 10, y: 20, width: 2, height: 18)
            let overlayController = FakeOverlayController()
            let presenter = SuggestionOverlayPresenter(overlayController: overlayController)

            let changed = presenter.present(
                text: " world",
                geometry: CotabbyTestFixtures.overlayGeometry(
                    caretRect: caretRect,
                    caretQuality: .derived
                ),
                previousState: .visible(
                    text: " world",
                    geometry: CotabbyTestFixtures.overlayGeometry(caretRect: caretRect),
                    mode: .inline
                )
            )

            XCTAssertTrue(changed)
            XCTAssertEqual(overlayController.showCallCount, 1)
        }
    }

    func test_hideForwardsReasonToOverlayController() {
        runOnMainActor {
            let overlayController = FakeOverlayController()
            let presenter = SuggestionOverlayPresenter(overlayController: overlayController)

            presenter.hide(reason: "Overlay hidden for test.")

            XCTAssertEqual(overlayController.hideReasons, ["Overlay hidden for test."])
        }
    }
}

@MainActor
private final class FakeOverlayController: SuggestionOverlayControlling {
    var state: OverlayState
    var onStateChange: ((OverlayState) -> Void)?

    private(set) var showCallCount = 0
    private(set) var lastShownText: String?
    private(set) var lastShownCaretRect: CGRect?
    private(set) var hideReasons: [String] = []

    init(initialState: OverlayState = .hidden(reason: "Overlay idle.")) {
        state = initialState
    }

    func showSuggestion(
        _ text: String,
        geometry: SuggestionOverlayGeometry
    ) {
        showCallCount += 1
        lastShownText = text
        lastShownCaretRect = geometry.caretRect
        // The fake does not run the production render policy; it records the call and reports an
        // inline panel. Tests that need a specific prior state inject it via `initialState:`.
        state = .visible(text: text, geometry: geometry, mode: .inline)
        onStateChange?(state)
    }

    func hide(reason: String) {
        hideReasons.append(reason)
        state = .hidden(reason: reason)
        onStateChange?(state)
    }
}
