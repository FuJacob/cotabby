import XCTest
@testable import Cotabby

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

    func test_longClipboard_noPerLineOverlap_returnsHead() {
        let clipboard = [
            "alpha bravo charlie",
            "delta echo foxtrot",
            "golf hotel india",
            "juliet kilo lima"
        ].joined(separator: "\n")

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

    // MARK: - Short tokens ignored

    func test_shortTokensIgnored() {
        let clipboard = [
            "a b c d e",
            "x y z w v",
            "real content here",
            "more filler words"
        ].joined(separator: "\n")

        let result = ClipboardContentDistiller.distill(
            clipboard: clipboard,
            prefixText: "a b c x y z"
        )
        // No tokens >= 3 chars overlap, so head fallback.
        XCTAssertEqual(result, String(clipboard.prefix(300)))
    }

    // MARK: - Empty prefix returns clipboard as-is

    func test_emptyPrefixText_returnsClipboardAsIs() {
        let clipboard = [
            "line one content",
            "line two content",
            "line three content",
            "line four content"
        ].joined(separator: "\n")

        let result = ClipboardContentDistiller.distill(
            clipboard: clipboard,
            prefixText: ""
        )
        XCTAssertEqual(result, clipboard)
    }
}
