import XCTest
@testable import Cotabby

/// Tests for `EmojiCatalog`'s impure loading entry point and its failure modes.
///
/// `bundled(in:)` must degrade to an empty catalog on a packaging mistake (missing or undecodable
/// resource) instead of taking down the app, so each failure branch is pinned against a throwaway
/// directory bundle. The matcher-facing index behavior lives in `EmojiCatalogMatcherTests`.
final class EmojiCatalogTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func test_bundled_loadsEntriesFromResourceJSON() throws {
        let json = """
        [
            {"glyph": "😀", "name": "grinning face", "aliases": ["grinning"],
             "keywords": ["smile", "happy"], "group": "Smileys & Emotion", "unicodeVersion": "6.1"},
            {"glyph": "👍", "name": "thumbs up", "aliases": ["+1", "thumbsup"],
             "keywords": ["approve"], "group": "People & Body", "unicodeVersion": "6.0"}
        ]
        """
        let bundle = try makeResourceBundle(emojiJSON: json)

        let catalog = EmojiCatalog.bundled(in: bundle)

        XCTAssertEqual(catalog.count, 2)
        XCTAssertFalse(catalog.isEmpty)
        // The loaded catalog must resolve stored aliases case-insensitively, as recents/popularity
        // lookups rely on.
        XCTAssertEqual(catalog.entry(forAlias: "Grinning")?.glyph, "😀")
        XCTAssertEqual(catalog.entry(forAlias: "+1")?.glyph, "👍")
    }

    func test_bundled_returnsEmptyCatalogWhenResourceIsMissing() throws {
        let bundle = try makeResourceBundle(emojiJSON: nil)

        let catalog = EmojiCatalog.bundled(in: bundle)

        XCTAssertTrue(catalog.isEmpty, "A missing resource must disable the picker, not crash")
        XCTAssertEqual(catalog.count, 0)
    }

    func test_bundled_returnsEmptyCatalogWhenJSONIsMalformed() throws {
        let bundle = try makeResourceBundle(emojiJSON: "this is not json")

        let catalog = EmojiCatalog.bundled(in: bundle)

        XCTAssertTrue(catalog.isEmpty, "An undecodable resource must disable the picker, not crash")
    }

    func test_count_reportsNumberOfIndexedEntries() {
        let entries = [
            EmojiEntry(
                glyph: "🐱",
                name: "cat face",
                aliases: ["cat"],
                keywords: ["pet"],
                group: "Animals & Nature",
                unicodeVersion: "6.0"
            )
        ]

        XCTAssertEqual(EmojiCatalog(entries: entries).count, 1)
        XCTAssertEqual(EmojiCatalog(entries: []).count, 0)
    }

    /// Builds a flat directory bundle. Foundation treats a plain directory as an unbundled layout
    /// whose resources live at the root, which is exactly how `bundled(in:)` probes for emoji.json.
    private func makeResourceBundle(emojiJSON: String?) throws -> Bundle {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cotabby-emoji-catalog-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        temporaryDirectories.append(dir)
        if let emojiJSON {
            try emojiJSON.write(
                to: dir.appendingPathComponent("emoji.json", isDirectory: false),
                atomically: true,
                encoding: .utf8
            )
        }
        return try XCTUnwrap(Bundle(url: dir))
    }
}
