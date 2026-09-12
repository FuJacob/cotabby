import XCTest
@testable import Cotabby

/// The sign-off cue decides the only place the writer's name enters the base-model prompt, so it
/// must fire exactly at a closing line and nowhere else.
final class SignOffCueTests: XCTestCase {
    func test_closingLineWithTheCaretAfterItsComma() {
        XCTAssertTrue(SignOffCue.precedesSignature("see you Friday.\nBest,"))
        XCTAssertTrue(SignOffCue.precedesSignature("Thanks again,"))
        XCTAssertTrue(SignOffCue.precedesSignature("Kind regards"))
    }

    func test_closingLineWithTheCaretOnTheNextLine() {
        // The renderer trims trailing whitespace, but the rule must not depend on that.
        XCTAssertTrue(SignOffCue.precedesSignature("see you Friday.\n\nBest,\n"))
        XCTAssertTrue(SignOffCue.precedesSignature("Cheers!\n   "))
    }

    func test_punctuationCaseAndSpacingDoNotMatter() {
        XCTAssertTrue(SignOffCue.precedesSignature("— Thanks again!"))
        XCTAssertTrue(SignOffCue.precedesSignature("BEST  REGARDS:"))
        XCTAssertTrue(SignOffCue.precedesSignature("with gratitude,"))
    }

    func test_openingsAndOrdinaryProseNeverQualify() {
        XCTAssertFalse(SignOffCue.precedesSignature(""))
        XCTAssertFalse(SignOffCue.precedesSignature("Hi"))
        XCTAssertFalse(SignOffCue.precedesSignature("Hi Sarah,"))
        XCTAssertFalse(SignOffCue.precedesSignature("Thanks for"))
        XCTAssertFalse(SignOffCue.precedesSignature("I wish you the best,"))
        XCTAssertFalse(SignOffCue.precedesSignature("thanks for sending over the draft."))
    }

    /// The request window folds line breaks into spaces before the prompt is rendered, so the
    /// closing arrives at the end of the last sentence rather than on its own line.
    func test_aClosingFoldedOntoTheLastSentenceStillQualifies() {
        XCTAssertTrue(SignOffCue.precedesSignature("See you Friday. Thanks,"))
        XCTAssertTrue(SignOffCue.precedesSignature("Could you add the numbers before Friday? Thanks again,"))
        XCTAssertTrue(SignOffCue.precedesSignature("Let me know what you think! Best,"))
        XCTAssertFalse(SignOffCue.precedesSignature("Thanks for the update."))
        XCTAssertFalse(SignOffCue.precedesSignature("See you Friday. I wish you the best,"))
        XCTAssertFalse(SignOffCue.precedesSignature("It was great. Thanks to everyone who"))
    }

    func test_anAlreadySignedClosingDoesNotQualify() {
        XCTAssertFalse(SignOffCue.precedesSignature("Best,\nSam"))
        XCTAssertFalse(SignOffCue.precedesSignature("Thanks, Sam"))
    }
}
