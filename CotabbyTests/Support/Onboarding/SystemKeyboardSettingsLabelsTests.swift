import XCTest
@testable import Cotabby

/// Pins the directions to the inline predictive text switch: they use System Settings' own words
/// when those resolve, and the English wording for any label that does not.
final class SystemKeyboardSettingsLabelsTests: XCTestCase {
    func testResolvedLabelsAreUsedInTheInstruction() {
        let german = [
            "Text Input": "Texteingabe",
            "Edit\u{2026}": "Bearbeiten\u{00A0}\u{2026}",
            "Show inline predictive text": "Inline-Textvorschläge einblenden",
        ]
        let labels = SystemKeyboardSettingsLabels.resolved { german[$0] }
        XCTAssertEqual(labels.textInput, "Texteingabe")
        XCTAssertTrue(labels.turnOffInstruction.contains("Texteingabe \u{203A} Bearbeiten\u{00A0}\u{2026}"))
        XCTAssertTrue(labels.turnOffInstruction.contains("\u{201C}Inline-Textvorschläge einblenden\u{201D}"))
    }

    func testUnresolvedLabelsFallBackToEnglish() {
        XCTAssertEqual(SystemKeyboardSettingsLabels.resolved { _ in nil }, .english)
        XCTAssertEqual(SystemKeyboardSettingsLabels.resolved { _ in "" }, .english)
        XCTAssertEqual(
            SystemKeyboardSettingsLabels.english.turnOffInstruction,
            "In Keyboard settings, choose Text Input \u{203A} Edit\u{2026} and turn off "
                + "\u{201C}Show inline predictive text\u{201D} so only Cotabby suggests."
        )
    }
}
