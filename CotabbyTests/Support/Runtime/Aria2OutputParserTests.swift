import XCTest
@testable import Cotabby

/// Locks the translation of aria2c's console status line into the progress value the model views
/// render: percent to a clamped fraction, `DL:` units to display speeds, `ETA:` to spaced text.
final class Aria2OutputParserTests: XCTestCase {
    func test_parseFullProgressLine() {
        let progress = Aria2OutputParser.parse(line: "[#e54b67 1.2GiB/4.5GiB(26%) CN:8 DL:42.5MiB ETA:1m15s]")

        XCTAssertEqual(
            progress,
            Aria2Progress(progressFraction: 0.26, speedFormatted: "42.5 MB/s", etaFormatted: "1m 15s", connectionCount: 8)
        )
    }

    func test_parseProgressLineWithoutSpeedOrETA() {
        XCTAssertEqual(
            Aria2OutputParser.parse(line: "[#123456 0B/1.4GiB(0%) CN:1]"),
            Aria2Progress(progressFraction: 0.0, connectionCount: 1)
        )
    }

    func test_parseProgressLineCompleted() {
        XCTAssertEqual(
            Aria2OutputParser.parse(line: "[#abcdef 4.5GiB/4.5GiB(100%)]"),
            Aria2Progress(progressFraction: 1.0)
        )
    }

    func test_parse_skippedOptionalFieldsDoNotShiftLaterOnes() {
        // No CN or DL, but ETA must still land in the ETA slot rather than being dropped.
        XCTAssertEqual(
            Aria2OutputParser.parse(line: "[#a1 1MiB/2MiB(50%) ETA:5s]"),
            Aria2Progress(progressFraction: 0.5, etaFormatted: "5s")
        )
    }

    func test_parse_clampsPercentAboveOneHundred() {
        XCTAssertEqual(Aria2OutputParser.parse(line: "[#a1 5MiB/4MiB(150%)]")?.progressFraction, 1.0)
    }

    func test_parse_trimsSurroundingWhitespaceAndNewlines() {
        XCTAssertEqual(
            Aria2OutputParser.parse(line: "  [#a1 1MiB/4MiB(25%)]\n")?.progressFraction,
            0.25
        )
    }

    func test_parse_formatsEverySpeedUnit() {
        let cases: [(raw: String, expected: String)] = [
            ("1.1GiB", "1.1 GB/s"),
            ("42.5MiB", "42.5 MB/s"),
            ("512KiB", "512 KB/s"),
            ("0B", "0 B/s"),
            // An unrecognized unit is kept verbatim rather than guessed at.
            ("3Xyz", "3Xyz/s")
        ]
        for testCase in cases {
            let progress = Aria2OutputParser.parse(line: "[#a1 1MiB/4MiB(25%) CN:2 DL:\(testCase.raw)]")
            XCTAssertEqual(progress?.speedFormatted, testCase.expected, "DL:\(testCase.raw)")
        }
    }

    func test_parse_spacesETAUnits() {
        let cases: [(raw: String, expected: String)] = [
            ("1h2m3s", "1h 2m 3s"),
            ("2h", "2h"),
            ("45s", "45s")
        ]
        for testCase in cases {
            let progress = Aria2OutputParser.parse(line: "[#a1 1MiB/4MiB(25%) ETA:\(testCase.raw)]")
            XCTAssertEqual(progress?.etaFormatted, testCase.expected, "ETA:\(testCase.raw)")
        }
    }

    func test_parseNonProgressLineReturnsNil() {
        let lines = [
            "Download Results:",
            "08/17 12:00:00 [NOTICE] Connecting to https://huggingface.co",
            "",
            // Starts like a status line but carries no percentage.
            "[#a1 1MiB/4MiB CN:2]"
        ]
        for line in lines {
            XCTAssertNil(Aria2OutputParser.parse(line: line), "\"\(line)\"")
        }
    }
}
