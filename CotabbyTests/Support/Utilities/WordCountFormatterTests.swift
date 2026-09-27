import XCTest
@testable import Cotabby

/// Locks the compact menu-bar word-count badge: hidden at zero, raw below 1K, one decimal below
/// 10K and 10M, whole units above, with each tier boundary pinned exactly.
final class WordCountFormatterTests: XCTestCase {
    func test_nonPositiveCountsHideTheBadge() {
        for count in [0, -5, Int.min] {
            XCTAssertNil(WordCountFormatter.compactLabel(for: count), "count \(count)")
        }
    }

    func test_compactLabelTiers() {
        let cases: [(count: Int, label: String)] = [
            // Raw number.
            (1, "1"),
            (9, "9"),
            (42, "42"),
            (999, "999"),
            // One-decimal thousands, rounded half-up, so the top of the tier reads "10.0K".
            (1_000, "1.0K"),
            (1_250, "1.3K"),
            (1_500, "1.5K"),
            (9_900, "9.9K"),
            (9_949, "9.9K"),
            (9_950, "10.0K"),
            (9_951, "10.0K"),
            (9_999, "10.0K"),
            // Whole thousands truncate rather than round.
            (10_000, "10K"),
            (10_999, "10K"),
            (50_000, "50K"),
            (999_999, "999K"),
            // One-decimal millions.
            (1_000_000, "1.0M"),
            (5_500_000, "5.5M"),
            (9_949_999, "9.9M"),
            (9_950_000, "10.0M"),
            (9_999_999, "10.0M"),
            // Whole millions truncate.
            (10_000_000, "10M"),
            (42_000_000, "42M"),
            (999_999_999, "999M"),
            (Int.max, "9223372036854M")
        ]
        for testCase in cases {
            XCTAssertEqual(WordCountFormatter.compactLabel(for: testCase.count), testCase.label, "count \(testCase.count)")
        }
    }
}
