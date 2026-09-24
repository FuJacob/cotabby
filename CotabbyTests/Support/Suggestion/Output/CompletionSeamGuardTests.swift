import XCTest
@testable import Cotabby

/// Locks in that the seam guard fires only on the two failure shapes it exists for (fresh junk
/// punctuation runs, mid-word splices that misspell the joined word) and never on the ordinary
/// continuations that surround them. Every guard must fire rarely; most of these tests are
/// allow-cases for exactly that reason.
final class CompletionSeamGuardTests: XCTestCase {
    /// A stub dictionary: the listed words are known, everything else is an uncorrectable typo.
    private func knowing(
        _ words: Set<String>
    ) -> (String) -> CompletionSeamGuard.SpellingAssessment {
        { words.contains($0.lowercased()) ? .known : .uncorrectableTypo }
    }

    private let knowsEverything: (String) -> CompletionSeamGuard.SpellingAssessment = { _ in .known }
    private let knowsNothing: (String) -> CompletionSeamGuard.SpellingAssessment = {
        _ in .uncorrectableTypo
    }

    // MARK: - Junk punctuation runs

    func testFreshPunctuationRunIsSuppressed() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "Wait",
                completion: " what....",
                spellingAssessment: knowsEverything
            ),
            .junkPunctuationRun
        )
    }

    func testSymbolRunIsSuppressed() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "Price: ",
                completion: "$$$$",
                spellingAssessment: knowsEverything
            ),
            .junkPunctuationRun
        )
    }

    func testThreeCharacterRunIsAllowed() {
        // Ellipsis-length runs are ordinary prose.
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "Well",
                completion: "... maybe",
                spellingAssessment: knowsEverything
            ),
            .allow
        )
    }

    func testSingleTrailingCharacterDoesNotExemptAJunkRun() {
        // "Hello." ends with one period; that must not license "...." from the completion. Only
        // a real preceding run (two or more) reads as a divider being extended.
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "Hello.",
                completion: "....",
                spellingAssessment: knowsEverything
            ),
            .junkPunctuationRun
        )
    }

    func testStreamedPresentationRejectsJunkAndMalformedJoins() {
        XCTAssertEqual(CompletionSeamGuard.presentation(precedingText: "Wait", completion: " what....", isFinal: false,
            spellingAssessment: knowsEverything), .suppress(.junkPunctuationRun))
        XCTAssertEqual(CompletionSeamGuard.presentation(precedingText: "gre", completion: "atful and kind", isFinal: false,
            spellingAssessment: { _ in .correctableTypo }), .suppress(.seamMisspelling(word: "greatful")))
    }

    func testContinuingAnExistingDividerIsAllowed() {
        // The user already has a dash run at the caret; extending it is intentional.
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "----",
                completion: "------",
                spellingAssessment: knowsEverything
            ),
            .allow
        )
    }

    func testFreshDividerAwayFromSeamIsSuppressed() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "----",
                completion: " section ======",
                spellingAssessment: knowsEverything
            ),
            .junkPunctuationRun
        )
    }

    func testRepeatedLettersAreNotJunk() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "That is so",
                completion: " coooool",
                spellingAssessment: knowsEverything
            ),
            .allow
        )
    }

    // MARK: - Seam misspellings

    func testMisspelledSeamWordIsSuppressed() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "I am so gre",
                completion: "atful for this",
                spellingAssessment: { _ in .correctableTypo }
            ),
            .seamMisspelling(word: "greatful")
        )
    }

    func testKnownSeamWordIsAllowed() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "I am so gre",
                completion: "at to hear it",
                spellingAssessment: knowing(["great"])
            ),
            .allow
        )
    }

    func testSeamRuleOnlyAppliesMidWord() {
        // Caret after a space: no seam word exists, so nothing to judge.
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "I am so ",
                completion: "greatful",
                spellingAssessment: knowsNothing
            ),
            .allow
        )
    }

    func testCapitalizedSeamWordIsAllowed() {
        // Names and brands are routinely out-of-dictionary; never block them.
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "Ask Cota",
                completion: "bby about it",
                spellingAssessment: knowsNothing
            ),
            .allow
        )
    }

    func testShortSeamWordIsAllowed() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "a",
                completion: "t the office",
                spellingAssessment: knowsNothing
            ),
            .allow
        )
    }

    func testDigitAdjacentSeamIsAllowed() {
        // The letter-run join is "vbeta"? No: digits break the letter run, so the head is empty
        // and the mid-word precondition (letter on both sides) fails.
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "version 2",
                completion: "024 release",
                spellingAssessment: knowsNothing
            ),
            .allow
        )
    }

    func testCJKSeamIsAllowed() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "これはとても良",
                completion: "い天気ですね",
                spellingAssessment: knowsNothing
            ),
            .allow
        )
    }

    func testOrdinaryContinuationIsAllowed() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "Thanks again for your help",
                completion: " with the move last weekend.",
                spellingAssessment: knowing(["with"])
            ),
            .allow
        )
    }

    // MARK: - Leading-word misspellings

    /// A lowercase generated typo is hidden only when the checker has an actionable correction.
    func testMisspelledLeadingWordWithCorrectionIsSuppressed() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "Je veux ",
                completion: "ecrir plus vite",
                spellingAssessment: { $0 == "ecrir" ? .correctableTypo : .known }
            ),
            .leadingWordMisspelling(word: "ecrir")
        )
    }

    /// Unknown vocabulary remains visible when the checker cannot offer a replacement.
    func testLeadingWordWithoutCorrectionIsAllowed() {
        // An unknown name or domain term should not disappear merely because the native checker has
        // no suggestion for it.
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "Use ",
                completion: "cotabby avec soin",
                spellingAssessment: { $0 == "cotabby" ? .uncorrectableTypo : .known }
            ),
            .allow
        )
    }

    /// Capitalized names bypass spelling entirely to avoid dictionary-driven false positives.
    func testCapitalizedLeadingWordIsAllowed() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "Ask ",
                completion: "Cotypist about it",
                spellingAssessment: { _ in
                    XCTFail("capitalized leading words must not reach the spell checker")
                    return .correctableTypo
                }
            ),
            .allow
        )
    }

    /// Mid-word completions assess the joined word rather than reclassifying the generated suffix.
    func testMidWordCompletionOnlyAssessesTheJoinedSeamWord() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "Je veux ecr",
                completion: "irregular",
                spellingAssessment: { word in
                    XCTAssertEqual(word, "ecrirregular")
                    return .known
                }
            ),
            .allow
        )
    }

    /// Opening quotation marks still leave the following letters at a valid word boundary.
    func testQuotedLeadingWordIsSuppressed() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "Il répond ",
                completion: "“ecrir” plus vite",
                spellingAssessment: { $0 == "ecrir" ? .correctableTypo : .known }
            ),
            .leadingWordMisspelling(word: "ecrir")
        )
    }

    /// Punctuation introduced after existing text cannot hide the first generated typo.
    func testParenthesizedLeadingWordAfterTextIsSuppressed() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "Il répond",
                completion: ": (ecrir) plus vite",
                spellingAssessment: { $0 == "ecrir" ? .correctableTypo : .known }
            ),
            .leadingWordMisspelling(word: "ecrir")
        )
    }

    /// Interior apostrophes stay attached so a contraction is never checked as a truncated stem.
    func testContractionIsAssessedAsOneWord() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "It ",
                completion: "doesn't matter",
                spellingAssessment: { word in
                    XCTAssertEqual(word, "doesn't")
                    return .known
                }
            ),
            .allow
        )
    }

    /// A digit makes the whole leading token code/version-like, including its letter prefix.
    func testLetterAndDigitLeadingTokenIsAllowedWithoutSpellLookup() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "Use ",
                completion: "ecrir2 here",
                spellingAssessment: { _ in
                    XCTFail("letter-and-digit tokens must bypass spelling")
                    return .correctableTypo
                }
            ),
            .allow
        )
    }

    /// The final result is complete by definition, so a correctable last word needs no trailing
    /// boundary to be suppressed; only the streaming verdict waits for one.
    func testFinalVerdictSuppressesCorrectableLeadingWordWithoutTrailingBoundary() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "Je veux ",
                completion: "ecrir",
                spellingAssessment: { $0 == "ecrir" ? .correctableTypo : .known }
            ),
            .leadingWordMisspelling(word: "ecrir")
        )
    }

    /// A connector continuing the caret word ("don" + "'t") is the mid-word case, not a new word.
    func testConnectorContinuationOfTheCaretWordSkipsTheLeadingWordRule() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "I don",
                completion: "'t know",
                spellingAssessment: { word in
                    XCTAssertEqual(word, "don't")
                    return .known
                }
            ),
            .allow
        )
    }

    /// Interior hyphens bind the token, so "state-of-the-art" is assessed once, as the user sees it.
    func testHyphenatedLeadingWordIsAssessedAsOneToken() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "A ",
                completion: "state-of-the-art tool",
                spellingAssessment: { word in
                    XCTAssertEqual(word, "state-of-the-art")
                    return .known
                }
            ),
            .allow
        )
    }

    /// Words under four letters are too ambiguous to judge, so even a classic typo like "teh"
    /// passes without a lookup. This documents a deliberate limit, not an oversight.
    func testShortLeadingWordIsAllowedWithoutSpellLookup() {
        XCTAssertEqual(
            CompletionSeamGuard.verdict(
                precedingText: "Send ",
                completion: "teh report",
                spellingAssessment: { _ in
                    XCTFail("short leading words must bypass spelling")
                    return .correctableTypo
                }
            ),
            .allow
        )
    }

    // MARK: - Streamed leading words

    /// Streaming buffers a lowercase prefix because checking it before its boundary is unreliable.
    func testStreamedLeadingWordWaitsUntilItsBoundaryArrives() {
        XCTAssertEqual(
            CompletionSeamGuard.streamedLeadingWordVerdict(
                precedingText: "Je veux ",
                completion: "ecrir",
                spellingAssessment: { _ in
                    XCTFail("an incomplete streamed word must not reach the spell checker")
                    return .known
                }
            ),
            .wait
        )
    }

    /// A trailing apostrophe may still join the next letters, so it cannot finalize the word.
    func testStreamedContractionWaitsAfterADanglingApostrophe() {
        XCTAssertEqual(
            CompletionSeamGuard.streamedLeadingWordVerdict(
                precedingText: "It ",
                completion: "does'",
                spellingAssessment: { _ in
                    XCTFail("a dangling apostrophe may still continue the streamed word")
                    return .known
                }
            ),
            .wait
        )
    }

    /// Once its boundary arrives, a correctable streamed typo is suppressed before presentation.
    func testStreamedCorrectableLeadingWordIsSuppressedAtItsBoundary() {
        XCTAssertEqual(
            CompletionSeamGuard.streamedLeadingWordVerdict(
                precedingText: "Je veux ",
                completion: "ecrir ",
                spellingAssessment: { $0 == "ecrir" ? .correctableTypo : .known }
            ),
            .suppress
        )
    }

    /// A known streamed word becomes presentable as soon as its boundary makes it complete.
    func testStreamedKnownLeadingWordIsAllowedAtItsBoundary() {
        XCTAssertEqual(
            CompletionSeamGuard.streamedLeadingWordVerdict(
                precedingText: "Je veux ",
                completion: "écrire ",
                spellingAssessment: { $0 == "écrire" ? .known : .correctableTypo }
            ),
            .allow
        )
    }

    /// Streaming also exempts a completed letter-and-digit token without consulting spelling.
    func testStreamedLetterAndDigitLeadingTokenIsAllowedWithoutSpellLookup() {
        XCTAssertEqual(
            CompletionSeamGuard.streamedLeadingWordVerdict(
                precedingText: "Use ",
                completion: "ecrir2 ",
                spellingAssessment: { _ in
                    XCTFail("letter-and-digit tokens must bypass streamed spelling")
                    return .correctableTypo
                }
            ),
            .allow
        )
    }

    func testAbandonedFragmentIsSuppressedEvenIfNativeDictionaryRecognizesIt() {
        for isFinal in [false, true] {
            XCTAssertEqual(CompletionSeamGuard.presentation(precedingText: "book a roo", completion: " room for two guests",
                isFinal: isFinal, spellingAssessment: knowsEverything), .suppress(.abandonedWord(word: "roo")))
        }
        XCTAssertEqual(CompletionSeamGuard.presentation(precedingText: "a car", completion: " is parked", isFinal: true,
            spellingAssessment: knowsEverything), .show(text: " is parked", wordOnly: false))
    }

    func testBadJoinedWordNeverAppearsDuringStreaming() {
        XCTAssertEqual(CompletionSeamGuard.presentation(precedingText: "so gre", completion: "atf", isFinal: false,
            spellingAssessment: { _ in XCTFail("Wait for the full word"); return .known }), .wait)
        for isFinal in [false, true] {
            XCTAssertEqual(CompletionSeamGuard.presentation(precedingText: "so gre", completion: "atful for this", isFinal: isFinal,
                spellingAssessment: { _ in .correctableTypo }), .suppress(.seamMisspelling(word: "greatful")))
        }
    }

    /// The phrase is already generated. Keeping it once the seam is known lets acceptance and
    /// ordinary typing advance through one suggestion instead of discarding its useful tail.
    func testKnownJoinedWordKeepsItsPhraseAtEveryPrefixLength() {
        let word = "build"
        for prefixLength in 1..<word.count {
            let prefix = String(word.prefix(prefixLength))
            let completion = String(word.dropFirst(prefixLength)) + " a spaceship"
            for isFinal in [false, true] {
                XCTAssertEqual(
                    CompletionSeamGuard.presentation(
                        precedingText: "I would like to " + prefix,
                        completion: completion,
                        isFinal: isFinal,
                        spellingAssessment: knowing([word])
                    ),
                    .show(text: completion, wordOnly: false),
                    "Prefix: \(prefix), final: \(isFinal)"
                )
            }
        }
    }

    /// A dictionary entry is not a word boundary: `build` could still grow into `building`.
    /// Buffer until the stream proves the seam word complete, then expose its phrase in one step.
    func testKnownJoinedWordStillWaitsForItsStreamedBoundary() {
        for completion in ["u", "uil", "uild", "uilding"] {
            XCTAssertEqual(
                CompletionSeamGuard.presentation(
                    precedingText: "I would like to b",
                    completion: completion,
                    isFinal: false,
                    spellingAssessment: { _ in
                        XCTFail("An unfinished joined word must not reach spelling assessment")
                        return .known
                    }
                ),
                .wait
            )
        }
        XCTAssertEqual(
            CompletionSeamGuard.presentation(
                precedingText: "I would like to b",
                completion: "uild a spaceship",
                isFinal: false,
                spellingAssessment: knowing(["build"])
            ),
            .show(text: "uild a spaceship", wordOnly: false)
        )
    }

    func testShortPrefixDoesNotPermitAMalformedJoinedWord() {
        for isFinal in [false, true] {
            XCTAssertEqual(
                CompletionSeamGuard.presentation(
                    precedingText: "That looks b",
                    completion: "eutiful in the garden",
                    isFinal: isFinal,
                    spellingAssessment: { word in
                        XCTAssertEqual(word, "beutiful")
                        return .correctableTypo
                    }
                ),
                .suppress(.seamMisspelling(word: "beutiful"))
            )
        }
    }

    func testProseOpenersDoNotBypassTheStreamedSeamGuard() {
        for opening in ["(", "\"", "“", "(“"] {
            XCTAssertEqual(
                CompletionSeamGuard.presentation(
                    precedingText: "Try " + opening + "b",
                    completion: "uild",
                    isFinal: false,
                    spellingAssessment: knowsEverything
                ),
                .wait
            )
            for isFinal in [false, true] {
                XCTAssertEqual(
                    CompletionSeamGuard.presentation(
                        precedingText: "Try " + opening + "b",
                        completion: "uild a spaceship",
                        isFinal: isFinal,
                        spellingAssessment: knowing(["build"])
                    ),
                    .show(text: "uild a spaceship", wordOnly: false)
                )
                XCTAssertEqual(
                    CompletionSeamGuard.presentation(
                        precedingText: "Try " + opening + "gre",
                        completion: "atful for this",
                        isFinal: isFinal,
                        spellingAssessment: { _ in .correctableTypo }
                    ),
                    .suppress(.seamMisspelling(word: "greatful"))
                )
            }
        }
    }

    func testUnknownJoinedWordOnlyShowsItsEnding() {
        for isFinal in [false, true] {
            for prefix in ["C", "Cota"] {
                let ending = String("Cotabby".dropFirst(prefix.count))
                XCTAssertEqual(
                    CompletionSeamGuard.presentation(
                        precedingText: "Use " + prefix,
                        completion: ending + " for everything",
                        isFinal: isFinal,
                        spellingAssessment: knowsNothing
                    ),
                    .show(text: ending, wordOnly: true)
                )
            }
        }
    }
}
