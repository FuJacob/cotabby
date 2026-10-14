import XCTest
@testable import Cotabby

/// The field-edge icon is click-through, as it always was, except while selection rewrite has turned
/// it into the wand. A click-capturing plain icon would swallow clicks meant for the host field.
@MainActor
final class ActivationIndicatorRewriteTests: XCTestCase {
    private static var retained: [AnyObject] = []

    private func makeController() -> ActivationIndicatorController {
        let controller = ActivationIndicatorController()
        Self.retained.append(controller)
        return controller
    }

    private let caret = CGRect(x: 200, y: 300, width: 1, height: 16)
    private let field = CGRect(x: 180, y: 290, width: 300, height: 36)

    func test_plainIconIgnoresClicks() {
        let controller = makeController()
        controller.show(enabled: true, caretRect: caret, inputFrameRect: field)
        XCTAssertFalse(controller.acceptsClicks)
        controller.hide(reason: "test")
    }

    func test_wandTakesClicksUntilRewriteEnds() {
        let controller = makeController()
        var ended = 0
        controller.onRewriteEnded = { ended += 1 }
        controller.showRewrite(caretRect: caret, inputFrameRect: field, onPress: {})
        XCTAssertTrue(controller.acceptsClicks)
        controller.endRewrite()
        XCTAssertFalse(controller.acceptsClicks)
        XCTAssertEqual(ended, 1)
        XCTAssertNil(controller.rewriteIconFrame)
    }

    func test_wandWithoutACaretStaysClickThrough() {
        let controller = makeController()
        controller.showRewrite(caretRect: .zero, inputFrameRect: field, onPress: {})
        XCTAssertFalse(controller.acceptsClicks)
        controller.endRewrite()
    }

    /// Focus updates arrive while rewrite owns the icon; they must not redraw the plain icon over the
    /// wand or turn its clicks off.
    func test_focusUpdatesLeaveTheWandAlone() {
        let controller = makeController()
        controller.showRewrite(caretRect: caret, inputFrameRect: field, onPress: {})
        controller.hide(reason: "selection makes the field unsupported")
        controller.show(enabled: true, caretRect: caret, inputFrameRect: field)
        XCTAssertTrue(controller.acceptsClicks)
        controller.endRewrite()
    }
}
