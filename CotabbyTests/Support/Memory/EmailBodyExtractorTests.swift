import Foundation
import XCTest
@testable import Cotabby

/// Pins how memory reads mail bodies: the encodings and structures real mail uses, legacy Turkish
/// charsets, HTML-only mail, attachments, and Mail's `.emlx` framing.
final class EmailBodyExtractorTests: XCTestCase {
    private func body(_ raw: String) -> String? {
        EmailBodyExtractor.body(fromMessage: Data(raw.replacingOccurrences(of: "\n", with: "\r\n").utf8))
    }

    func test_plainTextMessage() {
        XCTAssertEqual(body("Subject: Hi\nContent-Type: text/plain; charset=utf-8\n\nThe invoice is paid.\n"), "The invoice is paid.")
    }

    func test_quotedPrintableWithSoftBreaksAndEscapes() {
        let raw = "Content-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: quoted-printable\n\n" +
            "Toplant=C4=B1 yar=C4=B1n saat =\n=C3=BC=C3=A7te.\n"
        XCTAssertEqual(body(raw), "Toplantı yarın saat üçte.")
    }

    func test_base64InWindows1254DecodesTurkishLetters() {
        // "Şirket güncellemesi" in Windows-1254: Ş = 0xDE, ü = 0xFC.
        let bytes: [UInt8] = [0xDE, 0x69, 0x72, 0x6B, 0x65, 0x74, 0x20, 0x67, 0xFC, 0x6E, 0x63, 0x65, 0x6C, 0x6C,
                              0x65, 0x6D, 0x65, 0x73, 0x69]
        let raw = "Content-Type: text/plain; charset=windows-1254\nContent-Transfer-Encoding: base64\n\n" +
            Data(bytes).base64EncodedString() + "\n"
        XCTAssertEqual(body(raw), "Şirket güncellemesi")
    }

    func test_multipartAlternativePrefersPlainTextAndSkipsAttachments() {
        let raw = """
        Content-Type: multipart/mixed; boundary="outer"

        --outer
        Content-Type: multipart/alternative; boundary=inner

        --inner
        Content-Type: text/plain; charset=utf-8

        Plain version.
        --inner
        Content-Type: text/html; charset=utf-8

        <p>HTML version.</p>
        --inner--
        --outer
        Content-Type: text/plain
        Content-Disposition: attachment; filename="notes.txt"

        Attachment text.
        --outer--
        """
        XCTAssertEqual(body(raw), "Plain version.")
    }

    func test_htmlOnlyMailBecomesTextAndMarksQuotedReplies() {
        let raw = """
        Content-Type: text/html; charset=utf-8

        <html><head><style>p{color:red}</style></head><body><p>Numbers look great &amp; on time.</p>\
        <blockquote>please send the numbers</blockquote></body></html>
        """
        let text = body(raw) ?? ""
        XCTAssertTrue(text.hasPrefix("Numbers look great & on time."))
        XCTAssertTrue(text.contains("> please send the numbers"))
        XCTAssertFalse(text.contains("color:red"))
    }

    func test_emlxFramingReadsOnlyTheMessageBytes() {
        let message = "Content-Type: text/plain\r\n\r\nHello there."
        let emlx = "\(message.utf8.count)\n\(message)<?xml version=\"1.0\"?><plist></plist>"
        XCTAssertEqual(EmailBodyExtractor.bodyFromEmlx(Data(emlx.utf8)), "Hello there.")
    }

    func test_numericEntities() {
        XCTAssertEqual(EmailBodyExtractor.decodeEntities("&#350;irket &#xFC;"), "Şirket ü")
    }

    /// Mail is attacker-controlled: absurd nesting must be refused quickly, not recursed into.
    func test_deeplyNestedMultipartIsRefusedWithoutRecursingForever() {
        var raw = "Content-Type: text/plain\n\nInnermost."
        for level in 0..<5000 {
            raw = "Content-Type: multipart/mixed; boundary=b\(level)\n\n--b\(level)\n\(raw)\n--b\(level)--\n"
        }
        let started = Date()
        XCTAssertNil(EmailBodyExtractor.body(fromMessage: Data(raw.utf8)))
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    /// Crafted HTML that made the old regular expressions rescan the input from every position
    /// (unclosed tags and style blocks, runs of blank lines, endless entity digits) converts in
    /// linear time.
    func test_adversarialHTMLConvertsInLinearTime() {
        let pieces: [String] = [
            String(repeating: "<style>", count: 40_000),
            String(repeating: "<div", count: 40_000),
            String(repeating: "\n \n \t", count: 100_000),
            "&#" + String(repeating: "1", count: 200_000),
            String(repeating: "<blockquote>", count: 20_000)
        ]
        for html in pieces {
            let started = Date()
            _ = EmailBodyExtractor.htmlToText(html)
            XCTAssertLessThan(Date().timeIntervalSince(started), 2, "\(html.prefix(12))…")
        }
        XCTAssertEqual(EmailBodyExtractor.htmlToText("a <b>bold</b> b<br>c<STYLE>x</style>d<p>e</P>f"), "a bold b\nc de\nf")
        XCTAssertEqual(EmailBodyExtractor.htmlToText("1 < 2 and no tag closes"), "1 < 2 and no tag closes")
    }

    /// A huge message with pathological MIME (a header block with no end, folded a hundred
    /// thousand times, an absurd boundary) is bounded, not parsed whole.
    func test_pathologicalMIMEIsBoundedAndFast() {
        let foldedHeader = "Content-Type: text/plain\n" + String(repeating: "X-Junk: a\n b\n", count: 200_000)
        let hugeBoundary = "Content-Type: multipart/mixed; boundary=\(String(repeating: "q", count: 500_000))\n\nbody"
        let longLines = "Content-Type: text/plain\n\n" + String(repeating: "word ", count: 1_000_000)
        for raw in [foldedHeader, hugeBoundary, longLines] {
            let started = Date()
            let text = EmailBodyExtractor.body(fromMessage: Data(raw.utf8))
            XCTAssertLessThan(Date().timeIntervalSince(started), 3)
            XCTAssertLessThanOrEqual(text?.count ?? 0, EmailBodyExtractor.maximumCharacters)
        }
    }
}
