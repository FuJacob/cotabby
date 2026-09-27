import XCTest
@testable import Cotabby

/// Tests for the render-mode diagnostics vocabulary: the log/debug-overlay label, which embeds the
/// mirror reason's raw value, and the `isMirror` convenience the overlay controller branches on.
final class CompletionRenderModeTests: XCTestCase {
    func test_label_namesInlineOrMirrorWithItsReason() {
        XCTAssertEqual(CompletionRenderMode.inline.label, "inline")
        XCTAssertEqual(CompletionRenderMode.mirror(reason: .caretMidLine).label, "mirror(caretMidLine)")
        XCTAssertEqual(
            CompletionRenderMode.mirror(reason: .caretGeometryEstimated).label,
            "mirror(caretGeometryEstimated)"
        )
    }

    func test_isMirror_isTrueForEveryMirrorReasonOnly() {
        XCTAssertFalse(CompletionRenderMode.inline.isMirror)

        let reasons: [CompletionRenderMode.MirrorReason] = [
            .caretGeometryEstimated,
            .caretLayoutEstimated,
            .caretMidLine,
            .userPreference,
            .perAppOverride
        ]
        for reason in reasons {
            XCTAssertTrue(CompletionRenderMode.mirror(reason: reason).isMirror, "\(reason)")
        }
    }
}
