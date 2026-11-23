import XCTest
@testable import Cotabby

/// Pure-function tests for the last-mile insertion safety gate: unambiguous junk (empty,
/// whitespace-only, lossy-decode glyphs, control characters) and scalars that would make the ghost
/// differ from the typed text (invisible, bidi-reordering, stray tags) are refused, while real
/// content, including lone structural punctuation, multi-line text, emoji sequences, and RTL or
/// Indic text that needs joiners and marks, passes.
final class InsertionSafetyGateTests: XCTestCase {
    func test_legitimateCompletionsAreSafe() {
        let cases: [(String, String)] = [
            ("hello there", "plain prose"),
            (")", "closing a bracket is a legitimate inline completion"),
            (".", "ending a sentence is a legitimate inline completion"),
            ("first line\nsecond line", "a line feed is content in multi-line mode"),
            ("  indented", "leading whitespace is fine when real text follows"),
            ("🎉 café", "non-ASCII scalars are not control characters")
        ]
        for (completion, reason) in cases {
            XCTAssertTrue(InsertionSafetyGate.isSafeToInsert(completion), reason)
        }
    }

    func test_junkCompletionsAreUnsafe() {
        let cases: [(String, String)] = [
            ("", "empty"),
            ("   ", "whitespace-only"),
            ("\n\n", "newline-only is still whitespace-only"),
            ("\u{00A0}", "a non-breaking space is whitespace"),
            ("ab\u{FFFD}cd", "replacement glyph from lossy detokenization"),
            ("a\tb", "interior tab"),
            ("a\u{1B}b", "stray escape"),
            ("a\u{7F}b", "DEL sits outside the C0 range but is still a control character"),
            ("a\rb", "only the line feed is exempt, so a carriage return is refused")
        ]
        for (completion, reason) in cases {
            XCTAssertFalse(InsertionSafetyGate.isSafeToInsert(completion), reason)
        }
    }

    // MARK: - Scalars real text needs

    func test_emojiSequencesAreSafe() {
        let cases: [(String, String)] = [
            ("\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}", "ZWJ family emoji"),
            ("\u{1F3F3}\u{FE0F}\u{200D}\u{1F308}", "ZWJ sequence with an emoji presentation selector"),
            ("\u{1F44D}\u{1F3FD}", "skin-tone modifier"),
            ("\u{2764}\u{FE0F}", "VS16 emoji presentation"),
            ("1\u{FE0F}\u{20E3}", "keycap sequence"),
            ("\u{1F1EF}\u{1F1F5}", "regional-indicator flag"),
            ("\u{1F3F4}\u{200D}\u{2620}\u{FE0F}", "pirate flag: a black flag that is not a tag sequence"),
            ("\u{1F3F4}", "a bare black flag")
        ]
        for (completion, reason) in cases {
            XCTAssertTrue(InsertionSafetyGate.isSafeToInsert(completion), reason)
        }
    }

    func test_subdivisionFlagsAreSafe() {
        let cases: [(String, String)] = [
            ("\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}", "England"),
            ("\u{1F3F4}\u{E0067}\u{E0062}\u{E0073}\u{E0063}\u{E0074}\u{E007F}", "Scotland"),
            ("\u{1F3F4}\u{E0067}\u{E0062}\u{E0077}\u{E006C}\u{E0073}\u{E007F}", "Wales"),
            (
                "go \u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}"
                    + "\u{1F3F4}\u{E0067}\u{E0062}\u{E0077}\u{E006C}\u{E0073}\u{E007F}!",
                "back-to-back flags inside prose"
            )
        ]
        for (completion, reason) in cases {
            XCTAssertTrue(InsertionSafetyGate.isSafeToInsert(completion), reason)
        }
    }

    func test_rtlAndIndicTextWithJoinersAndMarksIsSafe() {
        let cases: [(String, String)] = [
            ("می\u{200C}خواهم", "Persian needs ZWNJ between a prefix and its verb"),
            (" کتاب\u{200C}ها", "Persian plural suffix after ZWNJ"),
            ("क्\u{200D}ष", "Devanagari half-form via ZWJ"),
            ("שלום\u{200F}!", "Hebrew with RLM placing trailing punctuation"),
            ("מחיר 50\u{200F} ש״ח", "Hebrew with RLM after digits"),
            ("abc\u{200E} (1)", "LRM in left-to-right text"),
            ("سعر\u{061C} 5", "Arabic letter mark"),
            ("\u{845B}\u{E0100}", "ideographic variation sequence")
        ]
        for (completion, reason) in cases {
            XCTAssertTrue(InsertionSafetyGate.isSafeToInsert(completion), reason)
        }
    }

    func test_onlyInvisibleAllowedScalarsIsNotACompletion() {
        let cases: [(String, String)] = [
            ("\u{200D}", "a lone ZWJ draws nothing"),
            ("\u{200C}\u{200F}", "joiners and marks alone draw nothing"),
            (" \u{FE0F}", "a variation selector after a space draws nothing")
        ]
        for (completion, reason) in cases {
            XCTAssertFalse(InsertionSafetyGate.isSafeToInsert(completion), reason)
        }
    }

    // MARK: - Scalars that make the ghost differ from what is typed

    func test_c1ControlsAreUnsafe() {
        for value in [0x80, 0x85, 0x9B, 0x9F] {
            let completion = "a" + String(Character(Unicode.Scalar(UInt32(value))!)) + "b"
            XCTAssertFalse(InsertionSafetyGate.isSafeToInsert(completion), "C1 control U+\(String(value, radix: 16))")
        }
    }

    func test_bidiEmbeddingsOverridesAndIsolatesAreUnsafe() {
        for value in Array(0x202A...0x202E) + Array(0x2066...0x2069) {
            let completion = "abc" + String(Character(Unicode.Scalar(UInt32(value))!)) + "def"
            XCTAssertFalse(InsertionSafetyGate.isSafeToInsert(completion), "bidi control U+\(String(value, radix: 16))")
        }
    }

    func test_lineAndParagraphSeparatorsAreUnsafe() {
        XCTAssertFalse(InsertionSafetyGate.isSafeToInsert("first\u{2028}second"), "LINE SEPARATOR")
        XCTAssertFalse(InsertionSafetyGate.isSafeToInsert("first\u{2029}second"), "PARAGRAPH SEPARATOR")
    }

    func test_zeroWidthAndInvisibleCharactersAreUnsafe() {
        let cases: [(String, String)] = [
            ("pass\u{200B}word", "ZERO WIDTH SPACE"),
            ("pass\u{2060}word", "WORD JOINER"),
            ("a\u{2061}b", "FUNCTION APPLICATION"),
            ("a\u{2062}b", "INVISIBLE TIMES"),
            ("a\u{2063}b", "INVISIBLE SEPARATOR"),
            ("a\u{2064}b", "INVISIBLE PLUS"),
            ("a\u{206A}b", "deprecated INHIBIT SYMMETRIC SWAPPING"),
            ("a\u{FEFF}b", "byte-order mark"),
            ("a\u{180E}b", "MONGOLIAN VOWEL SEPARATOR"),
            ("pass\u{00AD}word", "SOFT HYPHEN draws nothing mid-line")
        ]
        for (completion, reason) in cases {
            XCTAssertFalse(InsertionSafetyGate.isSafeToInsert(completion), reason)
        }
    }

    func test_tagCharactersOutsideAFlagAreUnsafe() {
        let england = "\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}"
        let cases: [(String, String)] = [
            ("hi\u{E0068}\u{E0069}", "tag text after ordinary letters"),
            ("hi\u{E0068}\u{E0069}\u{E007F}", "tag text with a cancel tag but no flag base"),
            ("\u{1F600}" + england + "\u{E007F}", "tag run after a base other than the black flag"),
            ("\u{1F3F4}" + england, "flag tag run with no cancel tag"),
            ("\u{1F3F4}\u{E007F}", "black flag with an empty tag run"),
            ("\u{1F3F4}\u{E0067}\u{E0062}\u{E007F}", "tag run shorter than a subdivision code"),
            ("\u{1F3F4}" + england + "\u{E0078}\u{E0078}\u{E0078}\u{E007F}", "tag run longer than a subdivision code"),
            ("\u{1F3F4}\u{E0047}\u{E0042}\u{E0045}\u{E004E}\u{E0047}\u{E007F}", "uppercase tags are not a subdivision code"),
            ("\u{1F3F4}" + england + "\u{E007F}\u{E007F}", "a second cancel tag after a valid flag"),
            ("a\u{E0001}b", "LANGUAGE TAG"),
            ("ok\u{E007F}", "lone cancel tag")
        ]
        for (completion, reason) in cases {
            XCTAssertFalse(InsertionSafetyGate.isSafeToInsert(completion), reason)
        }
    }
}
