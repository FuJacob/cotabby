import XCTest
@testable import tabby

/// Tests for the URLSession temp-file rescue that fixes #30.
///
/// These tests can't reproduce CFNetwork's actual "delete on callback return"
/// behavior — that lives inside the URL loading system and isn't hook-able.
/// What they *can* lock in is the exact logic the rescue depends on: that
/// given a real source file the rescue moves it, and given a source that
/// doesn't exist the rescue surfaces the failure instead of silently
/// returning a broken URL. The pre-fix code would have passed the happy-path
/// case here but silently succeeded on the missing-source case, because the
/// old code just stored the URL and moved later. Locking this in means a
/// future refactor that re-introduces the "store and move later" pattern
/// will break the test suite instead of surfacing as user-visible download
/// failures again.
final class DownloadFileRescuerTests: XCTestCase {

    // Track URLs to tear down so tests don't litter the temp directory with
    // rescue-test fixtures. This matters more in CI, where the test process
    // is short-lived but many test runs accumulate.
    private var cleanupURLs: [URL] = []

    override func tearDown() {
        cleanupURLs.forEach { try? FileManager.default.removeItem(at: $0) }
        cleanupURLs.removeAll()
        super.tearDown()
    }

    // MARK: - rescue happy path

    func test_rescue_movesFileFromSourceToHoldingURL() throws {
        let sourceURL = try makeTemporarySourceFile(contents: "hello")

        let holdingURL = try DownloadFileRescuer.rescue(temporaryFileAt: sourceURL)
        cleanupURLs.append(holdingURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: holdingURL.path),
                      "rescue should produce a holding file at the returned URL")
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path),
                       "rescue moves (not copies) — source should be gone afterwards")
    }

    func test_rescue_preservesFileContents() throws {
        let sourceURL = try makeTemporarySourceFile(contents: "content-marker-XYZ")

        let holdingURL = try DownloadFileRescuer.rescue(temporaryFileAt: sourceURL)
        cleanupURLs.append(holdingURL)

        let contents = try String(contentsOf: holdingURL, encoding: .utf8)
        XCTAssertEqual(contents, "content-marker-XYZ")
    }

    func test_rescue_producesHoldingURLInTemporaryDirectory() throws {
        let sourceURL = try makeTemporarySourceFile(contents: "x")

        let holdingURL = try DownloadFileRescuer.rescue(temporaryFileAt: sourceURL)
        cleanupURLs.append(holdingURL)

        let tempDir = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().path
        XCTAssertTrue(holdingURL.resolvingSymlinksInPath().path.hasPrefix(tempDir),
                      "holding file should live under temporaryDirectory")
    }

    func test_rescue_producesUniqueHoldingURLsAcrossCalls() throws {
        let first = try makeTemporarySourceFile(contents: "a")
        let second = try makeTemporarySourceFile(contents: "b")

        let h1 = try DownloadFileRescuer.rescue(temporaryFileAt: first)
        let h2 = try DownloadFileRescuer.rescue(temporaryFileAt: second)
        cleanupURLs.append(contentsOf: [h1, h2])

        XCTAssertNotEqual(h1, h2, "concurrent downloads must not collide on one holding path")
    }

    // MARK: - rescue regression guard

    /// Regression test for #30. If the source URL points to a file that's no
    /// longer there — exactly the state CFNetwork leaves us in if we store
    /// the URL and read it later — the rescue must throw, not silently
    /// succeed with a bad URL. The pre-fix delegate did the equivalent of
    /// this silent-success and produced the user-visible
    /// "CFNetworkDownload_*.tmp couldn't be moved" error downstream.
    func test_rescue_throwsWhenSourceFileDoesNotExist() {
        let phantomURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tabby-rescue-test-phantom-\(UUID().uuidString)")

        XCTAssertFalse(FileManager.default.fileExists(atPath: phantomURL.path),
                       "precondition: phantom URL must not exist")

        XCTAssertThrowsError(try DownloadFileRescuer.rescue(temporaryFileAt: phantomURL))
    }

    // MARK: - cleanup

    func test_cleanup_removesExistingFile() throws {
        let victimURL = try makeTemporarySourceFile(contents: "doomed")

        DownloadFileRescuer.cleanup(holdingFileAt: victimURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: victimURL.path),
                       "cleanup should remove the file at the given URL")
    }

    /// Cleanup is best-effort — its documented contract is to swallow errors
    /// so they don't obscure the primary failure the caller is already
    /// reporting. Calling it on a URL whose file is already gone must not
    /// crash or throw.
    func test_cleanup_isSilentOnMissingFile() {
        let phantomURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("tabby-cleanup-test-phantom-\(UUID().uuidString)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: phantomURL.path))

        // No throw, no return value to check — just that we get here.
        DownloadFileRescuer.cleanup(holdingFileAt: phantomURL)
    }

    // MARK: - Helpers

    private func makeTemporarySourceFile(contents: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("tabby-rescue-test-src-\(UUID().uuidString)")
        try contents.write(to: url, atomically: true, encoding: .utf8)
        cleanupURLs.append(url)
        return url
    }
}
