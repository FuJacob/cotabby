@testable import Cotabby
import XCTest

final class CotypistExportImporterTests: XCTestCase {
    private func export(_ rows: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: rows)
    }

    func test_keepsOnlyTheMostCompleteSnapshotOfEachField() throws {
        let data = try export([
            ["createdAt": "2026-06-05 16:23:53.028", "updatedAt": "2026-06-05 16:23:53.028",
             "appBundleIdentifier": "com.microsoft.Outlook", "textUpToCursor": "Hi Arnaud, the POC is read", "domain": "-"],
            ["createdAt": "2026-06-05 16:24:10.000", "updatedAt": "2026-06-05 16:24:10.000",
             "appBundleIdentifier": "com.microsoft.Outlook", "textUpToCursor": "Hi Arnaud, the POC is ready for review.",
             "textAfterCursor": " Kind regards, Senad", "domain": "-"],
            ["createdAt": "2026-06-06 09:00:00.000", "appBundleIdentifier": "com.google.Chrome",
             "textUpToCursor": "Can you summarize this incident report for me please?", "domain": "claude.ai"]
        ])

        let records = try CotypistExportImporter.records(fromExport: data)

        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].text, "Hi Arnaud, the POC is ready for review. Kind regards, Senad")
        XCTAssertNil(records[0].domain, "Cotypist's \"-\" means no site")
        XCTAssertEqual(records[1].domain, "claude.ai")
        XCTAssertTrue(records.allSatisfy { $0.source == .imported })
    }

    func test_differentMessagesThatOpenTheSameWayAreBothKept() throws {
        let data = try export([
            ["appBundleIdentifier": "com.apple.mail",
             "textUpToCursor": "Thanks for reaching out! I'd be happy to help with your billing question about the March invoice."],
            ["appBundleIdentifier": "com.apple.mail",
             "textUpToCursor": "Thanks for reaching out! I'd be happy to help. Unfortunately we cannot refund annual plans after thirty days."]
        ])

        XCTAssertEqual(try CotypistExportImporter.records(fromExport: data).count, 2)
    }

    func test_anEditedEarlierSnapshotStillCollapsesIntoTheFinalText() throws {
        let final = "Hi Arnaud, the POC is ready for review. I tested it on the staging server and everything works. Let me know."
        let data = try export([
            ["appBundleIdentifier": "com.microsoft.Outlook",
             "textUpToCursor": "Hi Arnaud, the POC is ready for review. I tested it on the stagng server and it works."],
            ["appBundleIdentifier": "com.microsoft.Outlook", "textUpToCursor": final]
        ])

        XCTAssertEqual(try CotypistExportImporter.records(fromExport: data).map(\.text), [final])
    }

    func test_fragmentsAreDropped() throws {
        let data = try export([["appBundleIdentifier": "net.whatsapp.WhatsApp", "textUpToCursor": "ok"]])
        XCTAssertEqual(try CotypistExportImporter.records(fromExport: data), [])
    }

    func test_secretsAreScrubbedOnImport() throws {
        let data = try export([[
            "appBundleIdentifier": "com.googlecode.iterm2",
            "textUpToCursor": "export OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuvwx1234 && run the build"
        ]])

        let text = try CotypistExportImporter.records(fromExport: data).first?.text

        XCTAssertEqual(text?.contains("sk-proj"), false)
        XCTAssertEqual(text?.contains("run the build"), true)
    }

    func test_otherJSONIsRejected() {
        XCTAssertThrowsError(try CotypistExportImporter.records(fromExport: Data("{\"a\":1}".utf8)))
        XCTAssertThrowsError(try CotypistExportImporter.records(fromExport: Data("[{\"name\":\"x\"}]".utf8)))
    }

    // MARK: - Bounds

    private func temporaryFile(_ data: Data) throws -> URL {
        let url = try makeTemporaryDirectory().appendingPathComponent("user_inputs.json")
        try data.write(to: url)
        return url
    }

    func test_readExport_refusesAFileOverTheLimitBeforeReadingIt() throws {
        let url = try temporaryFile(Data(repeating: 0x20, count: 2_048))

        XCTAssertThrowsError(try CotypistExportImporter.readExport(at: url, maximumBytes: 1_024)) { error in
            XCTAssertEqual(error as? CotypistExportImporter.ImportError, .fileTooLarge)
        }
    }

    func test_readExport_readsAFileWithinTheLimit() throws {
        let data = try export([["appBundleIdentifier": "com.apple.mail", "textUpToCursor": "Thanks for the quick reply, see you then."]])
        let url = try temporaryFile(data)

        XCTAssertEqual(try CotypistExportImporter.readExport(at: url, maximumBytes: data.count), data)
    }

    func test_readExport_refusesSomethingThatIsNotARegularFile() {
        XCTAssertThrowsError(try CotypistExportImporter.readExport(at: makeTemporaryDirectory())) { error in
            XCTAssertEqual(error as? CotypistExportImporter.ImportError, .unrecognizedFormat)
        }
    }

    func test_anExportWithTooManyRowsIsRefused() throws {
        let rows: [[String: Any]] = (0..<3).map { index in
            ["appBundleIdentifier": "com.apple.mail", "textUpToCursor": "Message number \(index) about the plan."]
        }

        XCTAssertThrowsError(try CotypistExportImporter.records(fromExport: export(rows), rowLimit: 2)) { error in
            XCTAssertEqual(error as? CotypistExportImporter.ImportError, .tooManyRows)
        }
        XCTAssertEqual(try CotypistExportImporter.records(fromExport: export(rows), rowLimit: 3).count, 3)
    }

    func test_boundErrorsExplainThemselves() {
        XCTAssertNotNil(CotypistExportImporter.ImportError.fileTooLarge.errorDescription)
        XCTAssertNotNil(CotypistExportImporter.ImportError.tooManyRows.errorDescription)
    }

    // MARK: - Dedup at scale

    func test_aChainOfEarlySnapshotsCollapsesIntoTheLongestAndASiblingStays() throws {
        // All shorter than the grouping prefix, so each lands in its own group and only the
        // prefix pass can collapse them.
        let data = try export([
            ["appBundleIdentifier": "com.apple.mail", "textUpToCursor": "See you at the offsite"],
            ["appBundleIdentifier": "com.apple.mail", "textUpToCursor": "See you at the offsite next week"],
            ["appBundleIdentifier": "com.apple.mail", "textUpToCursor": "See you at the offsite next week, Senad"],
            ["appBundleIdentifier": "com.apple.mail", "textUpToCursor": "See you at the office tomorrow"],
            // The same text in another app is someone else's writing context and stays.
            ["appBundleIdentifier": "com.tinyspeck.slackmacgap", "textUpToCursor": "See you at the offsite"]
        ])

        let texts = try CotypistExportImporter.records(fromExport: data).map(\.text).sorted()

        XCTAssertEqual(texts, [
            "See you at the office tomorrow",
            "See you at the offsite",
            "See you at the offsite next week, Senad"
        ])
    }

    func test_thousandsOfDistinctMessagesWithOneOpeningAreAllKept() throws {
        // One support macro opening thousands of different replies: every reply is its own writing.
        let count = 2_000
        let rows: [[String: Any]] = (0..<count).map { index in
            let reply = "Thanks for reaching out about your invoice. Ticket alpha\(index) bravo\(index) "
                + "charlie\(index) delta\(index) echo\(index) resolved."
            return ["appBundleIdentifier": "com.apple.mail", "textUpToCursor": reply]
        }

        XCTAssertEqual(try CotypistExportImporter.records(fromExport: export(rows)).count, count)
    }

    func test_manySnapshotsOfOneMessageCollapseToTheFinalText() throws {
        let final = "Hi Arnaud, the POC is ready for review. I tested it on the staging server and everything works fine."
        let words = final.split(separator: " ")
        let rows: [[String: Any]] = (8...words.count).map { length in
            ["appBundleIdentifier": "com.microsoft.Outlook", "textUpToCursor": words.prefix(length).joined(separator: " ")]
        }

        XCTAssertEqual(try CotypistExportImporter.records(fromExport: export(rows)).map(\.text), [final])
    }
}
