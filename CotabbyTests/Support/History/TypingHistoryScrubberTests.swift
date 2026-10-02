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

    func test_privateKeyBlocksAreRedacted() {
        let text = "here:\n-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXk\n-----END OPENSSH PRIVATE KEY-----\nthanks"
        XCTAssertEqual(TypingHistoryScrubber.scrub(text), "here:\n[redacted]\nthanks")
    }

    func test_longRecordsKeepTheirTail() {
        let text = String(repeating: "word ", count: 5_000) + "the end"
        let scrubbed = TypingHistoryScrubber.scrub(text)

        XCTAssertEqual(scrubbed.count, TypingHistoryScrubber.maximumRecordCharacters)
        XCTAssertTrue(scrubbed.hasSuffix("the end"))
    }
}
