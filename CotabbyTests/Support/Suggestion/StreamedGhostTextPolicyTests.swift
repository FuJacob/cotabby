import XCTest
@testable import Cotabby

/// Tests for the streamed-render monotonicity policy: out-of-order or normalizer-shrunk partials
/// must never replace longer ghost text already on screen.
final class StreamedGhostTextPolicyTests: XCTestCase {
    func test_firstNonEmptyPartialRenders() {
        XCTAssertTrue(StreamedGhostTextPolicy.isRenderableExtension(candidate: " wor", currentlyRendered: nil))
        XCTAssertTrue(StreamedGhostTextPolicy.isRenderableExtension(candidate: " wor", currentlyRendered: ""))
    }

    func test_emptyCandidateNeverRenders() {
        XCTAssertFalse(StreamedGhostTextPolicy.isRenderableExtension(candidate: "", currentlyRendered: nil))
        XCTAssertFalse(StreamedGhostTextPolicy.isRenderableExtension(candidate: "", currentlyRendered: " wor"))
    }

    func test_strictExtensionRenders() {
        XCTAssertTrue(
            StreamedGhostTextPolicy.isRenderableExtension(candidate: " world", currentlyRendered: " wor")
        )
    }

    func test_staleShorterPartialIsDropped() {
        XCTAssertFalse(
            StreamedGhostTextPolicy.isRenderableExtension(candidate: " wor", currentlyRendered: " world")
        )
    }

    func test_equalTextIsDroppedAsRedundant() {
        XCTAssertFalse(
            StreamedGhostTextPolicy.isRenderableExtension(candidate: " world", currentlyRendered: " world")
        )
    }

    func test_divergentRewriteIsDropped() {
        // A normalizer can legally rewrite a fragment rather than extend it; the render must wait
        // for the authoritative final result instead of flickering through rewrites.
        XCTAssertFalse(
            StreamedGhostTextPolicy.isRenderableExtension(candidate: " worse idea", currentlyRendered: " world")
        )
    }
}
