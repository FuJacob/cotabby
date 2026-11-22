import CoreGraphics
import XCTest
@testable import Cotabby

/// Tests which caret rects can place the field-edge icon. The regression guarded here is the empty
/// WhatsApp composer: its caret arrives zero-width (`w:0 h:16.5`), which `CGRect.isEmpty` treats as
/// empty, so the icon was hidden in exactly the field where nothing had been typed yet.
@MainActor
final class ActivationIndicatorCaretTests: XCTestCase {
    func testZeroWidthCaretWithHeightPlacesTheIcon() {
        XCTAssertTrue(ActivationIndicatorController.isUsableCaret(CGRect(x: 1332, y: 1119.5, width: 0, height: 16.5)))
    }

    func testOrdinaryCaretPlacesTheIcon() {
        XCTAssertTrue(ActivationIndicatorController.isUsableCaret(CGRect(x: 10, y: 20, width: 2, height: 16)))
    }

    func testCaretWithoutHeightOrPositionDoesNot() {
        XCTAssertFalse(ActivationIndicatorController.isUsableCaret(.zero))
        XCTAssertFalse(ActivationIndicatorController.isUsableCaret(CGRect(x: 10, y: 20, width: 2, height: 0)))
        XCTAssertFalse(ActivationIndicatorController.isUsableCaret(.null))
        XCTAssertFalse(ActivationIndicatorController.isUsableCaret(CGRect(x: CGFloat.infinity, y: 0, width: 0, height: 16)))
    }
}
