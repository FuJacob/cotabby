import XCTest
@testable import Cotabby

/// Tests for telling OCR jitter from new screen content. The jitter cases are lines that flickered
/// between consecutive captures of an unchanged Claude window in a real dev-log run.
final class VisualContextExcerptStabilityTests: XCTestCase {
    private static let screen = """
        Investigate screen context session restarting per field v
        New
        Q Search
        Artifacts
        Customize
        Claude Desktop priming 88
        Investigate screen context sessi
        Stop screen refreshes resetting
        MacBook Pro t
        OpenAI t 1 Chromium
        The switch is currently set to an empty value which means the model is on so normal behavior
        Running a command 2m 36s
        Opus 5.5 Extra Auto
        """

    // MARK: - Jitter is absorbed

    func test_rereadingTheSameScreenIsNotMaterial() {
        let reread = """
            Investigate screen context session restarting per field v
            New
            Q Search
            Artifacts
            Ô Customize
            Claude Desktop priming 8
            Investigate screen context sessic
            Stop screen refreshes resetting t
            OpenAI tEN Chromium
            The switch is currently set to an empty value which means the model is on so normal behavior
            Running a command 2m 40s
            981 00 3126 2156497
            Opus 5.5 Extra
            Auto
            """
        // Icon glyph, spinner digits, truncation flicker, a misread word, a ticking timer, a digit
        // run appearing, a label vanishing, and a line split in two.
        XCTAssertFalse(isMaterial(Self.screen, reread))
    }

    func test_reorderedLinesAreNotMaterial() {
        let lines = Self.screen.components(separatedBy: "\n")
        XCTAssertFalse(isMaterial(Self.screen, lines.reversed().joined(separator: "\n")))
    }

    func test_identicalOrEmptyExcerptsAreNotMaterial() {
        XCTAssertFalse(isMaterial(Self.screen, Self.screen))
        XCTAssertFalse(isMaterial("", ""))
    }

    // MARK: - New content still counts

    func test_aNewMessageIsMaterial() {
        XCTAssertTrue(isMaterial(Self.screen, Self.screen + "\nCan you send me the final budget numbers by Friday"))
    }

    func test_aNewMessageWithoutSpacesIsMaterial() {
        // Chinese has no spaces: the whole message is one token, but nine ideographs are a sentence.
        XCTAssertTrue(isMaterial(Self.screen, Self.screen + "\n请把最终预算发给我"))
        // A two-character label appearing is still a fragment.
        XCTAssertFalse(isMaterial(Self.screen, Self.screen + "\n设置"))
    }

    func test_aDifferentConversationIsMaterial() {
        let other = """
            Quarterly planning with the finance team
            New
            Q Search
            Please review the attached budget spreadsheet before the meeting
            I moved the vendor call to Thursday afternoon
            """
        XCTAssertTrue(isMaterial(Self.screen, other))
    }

    func test_aFirstExcerptIsMaterial() {
        XCTAssertTrue(isMaterial("", Self.screen))
    }

    func test_manySmallEditsAddUpToAMaterialChange() {
        // Each line changes one word, which alone reads as a misread word; ten of them are a
        // different screen. Comparing against the excerpt in use keeps such drift from hiding.
        let words = ["roadmap", "invoice", "schedule", "contract", "hiring", "launch", "travel", "pricing", "support", "security"]
        let replacements = ["budget", "receipt", "calendar", "proposal", "staffing", "release", "lodging", "billing", "helpdesk", "privacy"]
        let current = words.map { "Review the quarterly \($0) draft today" }.joined(separator: "\n")
        let candidate = replacements.map { "Review the quarterly \($0) draft today" }.joined(separator: "\n")

        XCTAssertTrue(isMaterial(current, candidate))
        XCTAssertFalse(isMaterial(current, candidate.components(separatedBy: "\n").prefix(1).joined(separator: "\n")
            + "\n" + current.components(separatedBy: "\n").dropFirst().joined(separator: "\n")))
    }

    // MARK: - Helpers

    private func isMaterial(_ current: String, _ candidate: String) -> Bool {
        VisualContextExcerptStability.isMaterialChange(from: current, to: candidate)
    }
}
