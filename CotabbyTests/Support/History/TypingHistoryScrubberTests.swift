@testable import Cotabby
import XCTest

final class TypingHistoryScrubberTests: XCTestCase {
    func test_proseAndShortNumbersPassThrough() {
        let text = "Hi Arnaud, the POC starts on 12 October at 10:30. Kind regards, Senad"
        XCTAssertEqual(TypingHistoryScrubber.scrub(text), text)
    }

    func test_longAllLetterWordsAreKept() {
        let turkish = "Çekoslovakyalılaştıramadıklarımızdanmışsınız diye yazdım."
        XCTAssertEqual(TypingHistoryScrubber.scrub(turkish), turkish)
    }

    func test_credentialsAndTokensAreRedacted() {
        let text = "key sk-ant-api03-abcdefghijklmnop1234 and ghp_abcdefghijklmnopqrstuvwxyz123456 "
            + "plus token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abc123"
        let scrubbed = TypingHistoryScrubber.scrub(text)

        XCTAssertFalse(scrubbed.contains("sk-ant"))
        XCTAssertFalse(scrubbed.contains("ghp_"))
        XCTAssertFalse(scrubbed.contains("eyJhbGci"))
        XCTAssertTrue(scrubbed.hasPrefix("key [redacted] and [redacted]"))
    }

    func test_cardNumbersAreRedactedButPhoneNumbersAndDatesStay() {
        XCTAssertEqual(
            TypingHistoryScrubber.scrub("card 4111 1111 1111 1111 exp 12/27, or 5500-0000-0000-0004"),
            "card [redacted] exp 12/27, or [redacted]"
        )
        let prose = "Call me on +1 415 555 0100 before 2026-10-04 17:30, order 123456789012."
        XCTAssertEqual(TypingHistoryScrubber.scrub(prose), prose)
    }

    func test_privateKeyBlocksAreRedacted() {
        let text = "here:\n-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXk\n-----END OPENSSH PRIVATE KEY-----\nthanks"
        XCTAssertEqual(TypingHistoryScrubber.scrub(text), "here:\n[redacted]\nthanks")
    }

    func test_aCredentialSplitByTheCaretIsStillRedacted() {
        // Each half alone is too short to look like a key; scrubbed apart and joined again, the
        // whole key would be stored.
        let scrubbed = TypingHistoryScrubber.scrub(before: "my key is sk-abcdefgh", after: "ijklmnop12345678 thanks")

        XCTAssertEqual(scrubbed.text, "my key is [redacted] thanks")
        XCTAssertEqual(scrubbed.typedLength, "my key is [redacted]".count, "A secret around the caret counts as typed")
    }

    func test_theCaretBoundarySurvivesRedactionBeforeIt() {
        let scrubbed = TypingHistoryScrubber.scrub(
            before: "token ghp_abcdefghijklmnopqrstuvwxyz123456 then ", after: "the rest"
        )

        XCTAssertEqual(scrubbed.text, "token [redacted] then the rest")
        XCTAssertEqual(scrubbed.typedLength, "token [redacted] then ".count)
    }

    func test_aKeptLongWordAroundTheCaretKeepsTheBoundaryInPlace() {
        let scrubbed = TypingHistoryScrubber.scrub(before: "Donaudampfschifffahrts", after: "gesellschaft fährt")

        XCTAssertEqual(scrubbed.text, "Donaudampfschifffahrtsgesellschaft fährt")
        XCTAssertEqual(scrubbed.typedLength, "Donaudampfschifffahrts".count)
    }

    func test_longRecordsKeepTheirTail() {
        let text = String(repeating: "word ", count: 5_000) + "the end"
        let scrubbed = TypingHistoryScrubber.scrub(text)

        XCTAssertEqual(scrubbed.count, TypingHistoryScrubber.maximumRecordCharacters)
        XCTAssertTrue(scrubbed.hasSuffix("the end"))
    }
}
