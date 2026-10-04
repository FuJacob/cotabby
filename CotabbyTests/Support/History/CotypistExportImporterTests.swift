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
}
