@testable import Cotabby
import XCTest

final class TypingHistoryScrubberTests: XCTestCase {
    /// Everything before the caret, the shape a freshly typed field reaches the recorder in.
    private func scrub(_ text: String) -> String {
        TypingHistoryScrubber.scrub(before: text, after: "").text
    }

    func test_proseAndShortNumbersPassThrough() {
        let text = "Hi Arnaud, the POC starts on 12 October at 10:30. Kind regards, Senad"
        XCTAssertEqual(scrub(text), text)
    }

    func test_longAllLetterWordsAreKept() {
        let turkish = "Çekoslovakyalılaştıramadıklarımızdanmışsınız diye yazdım."
        XCTAssertEqual(scrub(turkish), turkish)
    }

    func test_credentialsAndTokensAreRedacted() {
        let text = "key sk-ant-api03-abcdefghijklmnop1234 and ghp_abcdefghijklmnopqrstuvwxyz123456 "
            + "plus token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abc123"
        let scrubbed = scrub(text)

        XCTAssertFalse(scrubbed.contains("sk-ant"))
        XCTAssertFalse(scrubbed.contains("ghp_"))
        XCTAssertFalse(scrubbed.contains("eyJhbGci"))
        XCTAssertTrue(scrubbed.hasPrefix("key [redacted] and [redacted]"))
    }

    func test_cardNumbersAreRedactedButPhoneNumbersAndDatesStay() {
        XCTAssertEqual(
            scrub("card 4111 1111 1111 1111 exp 12/27, or 5500-0000-0000-0004"),
            "card [redacted] exp 12/27, or [redacted]"
        )
        let prose = "Call me on +1 415 555 0100 before 2026-10-04 17:30, order 123456789012."
        XCTAssertEqual(scrub(prose), prose)
    }

    func test_privateKeyBlocksAreRedacted() {
        let text = "here:\n-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXk\n-----END OPENSSH PRIVATE KEY-----\nthanks"
        XCTAssertEqual(scrub(text), "here:\n[redacted]\nthanks")
    }

    func test_aCredentialSplitByTheCaretIsStillRedacted() {
        // Each half alone is too short to look like a key; scrubbed apart and joined again, the
        // whole key would be stored.
        let scrubbed = TypingHistoryScrubber.scrub(before: "my key is sk-abcdefgh", after: "ijklmnop12345678 thanks")

        XCTAssertEqual(scrubbed.text, "my key is [redacted] thanks")
        XCTAssertEqual(scrubbed.typedLength, "my key is [redacted]".count, "A secret around the caret counts as typed")
    }

    func test_theCaretBoundarySurvivesRedactionBeforeIt() {
        let scrubbed = scrub(
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
        let scrubbed = scrub(text)

        XCTAssertEqual(scrubbed.count, TypingHistoryScrubber.maximumRecordCharacters)
        XCTAssertTrue(scrubbed.hasSuffix("the end"))
    }

    // MARK: - Vendor prefixes

    /// Builds a key-shaped string from separate literals, so no complete token appears in the
    /// source for secret scanners to flag.
    private func fakeKey(_ prefix: String, _ length: Int, alphabet: String = "abcdefghijklmnopqrstuvwxyz0123456789") -> String {
        let characters = Array(alphabet)
        return prefix + String((0..<length).map { characters[$0 % characters.count] })
    }

    func test_distinctivelyPrefixedKeysAreRedactedEvenBelowTheGenericLength() {
        let keys = [
            fakeKey("glpat-", 20),
            fakeKey("xapp-1-", 12),
            fakeKey("AS" + "IA", 16, alphabet: "ABCDEFGHIJ0123456789"),
            fakeKey("AI" + "za", 35),
            fakeKey("hf" + "_", 34, alphabet: "abcdefghijklmnopqrstuvwxyzABCDEFGH"),
            fakeKey("npm" + "_", 36),
            fakeKey("pypi-" + "AgE", 20),
            fakeKey("shp" + "at_", 32, alphabet: "0123456789abcdef"),
            fakeKey("sk" + "_live_", 16),
            fakeKey("rk" + "_test_", 16),
            fakeKey("sk-" + "proj-", 16),
            fakeKey("sk-" + "ant-api03-", 16)
        ]
        for key in keys {
            XCTAssertEqual(scrub("use \(key) here"), "use [redacted] here", key)
        }
    }

    func test_prefixLookalikesInOrdinaryWritingStay() {
        for text in [
            "Call hf_hub_download before the run.",
            "Install pypi-server on the build box.",
            "The ASIAPACIFICREGIONAL office called.",
            "Our sk-team meets on Fridays."
        ] {
            XCTAssertEqual(scrub(text), text)
        }
    }

    // MARK: - Labelled secrets

    func test_labelledSecretsLoseTheirValueButKeepTheLabel() {
        XCTAssertEqual(scrub("the password: hunter2 for now"), "the password: [redacted] for now")
        XCTAssertEqual(scrub("Passwd = hunter2"), "Passwd = [redacted]")
        XCTAssertEqual(scrub("pwd:abc"), "pwd:[redacted]")
        XCTAssertEqual(scrub("DB_PASSWORD=s3cr3t ok"), "DB_PASSWORD=[redacted] ok")
        XCTAssertEqual(scrub("GITHUB_TOKEN=abc ok"), "GITHUB_TOKEN=[redacted] ok")
        // An unquoted value runs to the next whitespace, so a trailing comma goes with it.
        XCTAssertEqual(
            scrub("secret=x, api_key: y, apikey=z"),
            "secret=[redacted] api_key: [redacted] apikey=[redacted]"
        )
        XCTAssertEqual(
            scrub("{\"client_secret\": \"two words\", \"name\": \"Senad\"}"),
            "{\"client_secret\": [redacted], \"name\": \"Senad\"}"
        )
    }

    func test_secretWordsInProseStay() {
        for text in [
            "I forgot my password again, can you reset it?",
            "The secret is out: we ship on Monday.",
            "Use the tokenizer: it splits on spaces.",
            "mypassword: is not a label we know"
        ] {
            XCTAssertEqual(scrub(text), text)
        }
    }

    func test_aLabelledSecretAcrossTheCaretIsRedactedWhole() {
        let scrubbed = TypingHistoryScrubber.scrub(before: "my password: hun", after: "ter2 and more")

        XCTAssertEqual(scrubbed.text, "my password: [redacted] and more")
        XCTAssertEqual(scrubbed.typedLength, "my password: [redacted]".count)
    }

    // MARK: - SSNs and one-time codes

    func test_socialSecurityNumbersAreRedacted() {
        XCTAssertEqual(scrub("SSN 123-45-6789, thanks"), "SSN [redacted], thanks")
        // Other dashed numbers keep their shape.
        let prose = "Ref 2026-10-04 and 12-345-6789 and 123-456-7890"
        XCTAssertEqual(scrub(prose), prose)
    }

    func test_labelledOneTimeCodesAreRedacted() {
        let cases = [
            ("Your OTP 123456 expires soon", "Your OTP [redacted] expires soon"),
            ("verification code is 482913.", "verification code is [redacted]."),
            ("2FA code: 123 456", "2FA code: [redacted]"),
            ("security code 123", "security code [redacted]"),
            ("one-time code 9876", "one-time code [redacted]"),
            ("code: 123456", "code: [redacted]"),
            ("PIN: 4821", "PIN: [redacted]")
        ]
        for (text, expected) in cases {
            XCTAssertEqual(scrub(text), expected, text)
        }
    }

    func test_bareAndUnlabelledNumbersStay() {
        for text in [
            "Order 123456 shipped today.",
            "The code 2024 release is out.",
            "Error code 404 again.",
            "Send it to zip code 94103.",
            "Promo code SAVE20 still works.",
            "Pin the tab and call 4821."
        ] {
            XCTAssertEqual(scrub(text), text)
        }
    }
}
