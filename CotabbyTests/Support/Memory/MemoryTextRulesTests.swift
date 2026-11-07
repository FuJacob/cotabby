import Foundation
import XCTest
@testable import Cotabby

/// Pins the text rules memory applies before storing a message and the keys it matches
/// conversations and people by. A change here changes what existing stored data means (its keys and
/// what was redacted), so the cases are exact.
final class MemoryTextRulesTests: XCTestCase {
    func test_scrubRedactsSecretsAndDropsOneTimeCodes() {
        XCTAssertNil(MemoryTextScrubber.scrub("Your verification code is 482913"))
        XCTAssertNil(MemoryTextScrubber.scrub("Doğrulama kodu: 4829"))
        let cleaned = MemoryTextScrubber.scrub("card 4111 1111 1111 1111 and password: hunter2 ok") ?? ""
        XCTAssertFalse(cleaned.contains("4111"))
        XCTAssertFalse(cleaned.contains("hunter2"))
        XCTAssertTrue(cleaned.contains("ok"))
        XCTAssertNil(MemoryTextScrubber.scrub("   "))
        XCTAssertEqual(MemoryTextScrubber.scrub("see you   at\t3"), "see you at 3")
    }

    func test_mailQuotesAndSignaturesAreStripped() {
        let body = "Sounds good, see you then.\n\nOn Mon, 3 Oct 2026, Ayşe wrote:\n> Shall we meet?\n> Thanks"
        XCTAssertEqual(MailQuoteStripper.strip(body), "Sounds good, see you then.")
        XCTAssertEqual(MailQuoteStripper.strip("Tamam.\n\n3 Eki 2026 tarihinde Ayşe şunu yazdı:\n> Olur mu?"), "Tamam.")
        XCTAssertEqual(MailQuoteStripper.strip("Done.\n-- \nSam"), "Done.")
        XCTAssertEqual(MailQuoteStripper.strip("Yes\n> quoted line\nand more"), "Yes\nand more")
    }

    func test_titlesMatchWithoutBadgesCaseDirectionMarksOrReplyPrefixes() {
        XCTAssertEqual(ConversationTitleKey.key("(3) \u{200E}Ayşe  Yılmaz"), ConversationTitleKey.key("ayşe yılmaz"))
        XCTAssertEqual(ConversationTitleKey.key("Re: Fwd: POC results"), ConversationTitleKey.key("POC results"))
        XCTAssertEqual(ConversationTitleKey.key("YNT: POC results"), "poc results")
    }

    func test_participantsAreNormalizedToTheirAddress() {
        XCTAssertEqual(ParticipantNormalizer.normalize("Ayşe Yılmaz <AYSE@example.com>"), "ayse@example.com")
        XCTAssertEqual(ParticipantNormalizer.normalize("  Avery Stone "), "avery stone")
    }

    func test_chunksOverlapAndShortTextIsOnePassage() {
        XCTAssertEqual(PassageChunker.chunks("a short message", size: 4, overlap: 1), ["a short message"])
        let words = (1...10).map(String.init).joined(separator: " ")
        XCTAssertEqual(PassageChunker.chunks(words, size: 4, overlap: 1), ["1 2 3 4", "4 5 6 7", "7 8 9 10", "10"])
    }

    func test_passageTextIsDatedAndAttributed() {
        let date = Date(timeIntervalSince1970: 1_789_200_000) // 2026-09-12 UTC
        XCTAssertEqual(
            PassageChunker.passageText(timestamp: date, sender: "Ayşe", isFromMe: false, subject: nil, text: "the invoice is paid"),
            "[2026-09-12] Ayşe: the invoice is paid"
        )
        XCTAssertEqual(
            PassageChunker.passageText(timestamp: date, sender: "x", isFromMe: true, subject: "POC", text: "done"),
            "[2026-09-12] You (re: POC): done"
        )
    }

    func test_keywordScorerMatchesPrefixesAndRanksTheBetterMatchFirst() {
        let documents = ["the invoice is paid", "lunch tomorrow", "invoice invoice reminder"]
        XCTAssertEqual(KeywordScorer.rank(query: "invo", documents: documents, limit: 5), [2, 0])
        XCTAssertEqual(KeywordScorer.rank(query: "nothing here", documents: documents, limit: 5), [])
    }

    func test_rankFusionWeighsBothLists() {
        let fused = ReciprocalRankFusion.fuse(vector: ["a", "b"], keyword: ["b", "c"], vectorWeight: 0.7)
        XCTAssertEqual(fused.first?.id, "b", "found by both paths ranks first")
        XCTAssertEqual(Set(fused.map(\.id)), ["a", "b", "c"])
    }

    func test_termsAreUnicodeWordsLongerThanOneCharacter() {
        XCTAssertEqual(MemoryTerms.terms("Yarın 3'te Karaköy'de, OK?"), ["yarın", "te", "karaköy", "de", "ok"])
    }

    func test_halfPrecisionRoundTripsVectorsClosely() {
        let values: [Float] = [0.25, -0.5, 1, 0, 0.123456, -0.98765]
        let decoded = HalfPrecision.decode(HalfPrecision.encode(values))
        for (original, restored) in zip(values, decoded) {
            XCTAssertEqual(original, restored, accuracy: 0.001)
        }
        XCTAssertEqual(HalfPrecision.encode([]), [])
    }
}
