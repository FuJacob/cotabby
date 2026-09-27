import XCTest
@testable import Cotabby

/// Tests for clipboard distillation: compact clipboards pass through, longer ones keep only lines
/// sharing a 3+ character token with the caret prefix, with a bounded head fallback.
final class ClipboardContentDistillerTests: XCTestCase {

    // MARK: - Short clipboard passes through

    func test_shortClipboard_returnedAsIs() {
        let clipboard = "line one\nline two\nline three"
        let result = ClipboardContentDistiller.distill(
            clipboard: clipboard,
            prefixText: "completely unrelated text"
        )
        XCTAssertEqual(result, clipboard)
    }

    // MARK: - Long clipboard with partial overlap

    func test_longClipboard_keepsOnlyMatchingLines() {
        let clipboard = [
            "import Foundation",
            "import UIKit",
            "func deploy() {",
            "    print(\"starting deploy\")",
            "}"
        ].joined(separator: "\n")

        let result = ClipboardContentDistiller.distill(
            clipboard: clipboard,
            prefixText: "the deploy is running"
        )
        XCTAssertEqual(result, [
            "func deploy() {",
            "    print(\"starting deploy\")"
        ].joined(separator: "\n"))
    }

    // MARK: - No per-line overlap falls back to head

    /// With no overlapping line the distiller falls back to the first 300 characters, so a large
    /// unrelated clipboard is bounded rather than dropped or passed through whole.
    func test_longClipboard_noPerLineOverlap_returnsFirst300Characters() {
        let clipboard = (0..<40).map { "alpha bravo charlie line \($0)" }.joined(separator: "\n")
        XCTAssertGreaterThan(clipboard.count, 300)

        let result = ClipboardContentDistiller.distill(
            clipboard: clipboard,
            prefixText: "completely different words"
        )
        XCTAssertEqual(result, String(clipboard.prefix(300)))
    }

    // MARK: - Case insensitive

    func test_caseInsensitiveMatching() {
        let clipboard = [
            "The DEPLOYMENT pipeline",
            "Some unrelated header",
            "Another random line",
            "Check deployment status"
        ].joined(separator: "\n")

        let result = ClipboardContentDistiller.distill(
            clipboard: clipboard,
            prefixText: "our deployment is slow"
        )
        XCTAssertEqual(result, [
            "The DEPLOYMENT pipeline",
            "Check deployment status"
        ].joined(separator: "\n"))
    }

    // MARK: - Prefix without significant tokens

    /// An empty prefix, or one made only of sub-3-character tokens, gives nothing to match against,
    /// so the clipboard passes through whole (not the 300-character head fallback).
    func test_prefixWithoutSignificantTokens_returnsClipboardAsIs() {
        let clipboard = (0..<40).map { "line \($0) content" }.joined(separator: "\n")
        XCTAssertGreaterThan(clipboard.count, 300)

        for prefix in ["", "a b c x y z", "  \n "] {
            XCTAssertEqual(
                ClipboardContentDistiller.distill(clipboard: clipboard, prefixText: prefix),
                clipboard,
                "prefix \(prefix.debugDescription)"
            )
        }
    }
}
