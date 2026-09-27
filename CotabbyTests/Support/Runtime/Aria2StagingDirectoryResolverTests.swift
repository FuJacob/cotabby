import XCTest
@testable import Cotabby

/// Locks the resume-directory identity: a source-URL hash plus the leaf filename, so start, retry,
/// and cancellation for one download share state while equal filenames from different repos never do.
final class Aria2StagingDirectoryResolverTests: XCTestCase {
    private let runtimeDirectory = URL(fileURLWithPath: "/tmp/CotabbyModels", isDirectory: true)

    private func directory(_ source: String, _ filename: String) -> URL {
        Aria2StagingDirectoryResolver.directory(
            in: runtimeDirectory,
            downloadURL: URL(string: source)!,
            filename: filename
        )
    }

    func test_directory_isAHiddenChildNamedByTruncatedSourceHashAndFilename() {
        // First 12 hex characters of SHA-256("https://example.com/repo-a/model.gguf"). Pinning the
        // exact name keeps partial downloads resumable across app versions: a changed derivation
        // would silently orphan every in-progress `.aria2` control file.
        let url = directory("https://example.com/repo-a/model.gguf", "model.gguf")

        XCTAssertEqual(url.lastPathComponent, ".aria2-staging-22a30703215b-model.gguf")
        XCTAssertEqual(url.deletingLastPathComponent().path, runtimeDirectory.path)
        XCTAssertTrue(url.hasDirectoryPath)
        XCTAssertEqual(url, directory("https://example.com/repo-a/model.gguf", "model.gguf"))
    }

    func test_sameFilenameFromDifferentSourcesUsesDifferentDirectories() {
        let first = directory("https://example.com/repo-a/model.gguf", "model.gguf")
        let second = directory("https://example.com/repo-b/model.gguf", "model.gguf")

        XCTAssertNotEqual(first, second)
        XCTAssertTrue(first.lastPathComponent.hasSuffix("-model.gguf"))
        XCTAssertTrue(second.lastPathComponent.hasSuffix("-model.gguf"))
    }

    func test_differentFilenamesFromTheSameSourceUseDifferentDirectories() {
        let first = directory("https://example.com/repo-a/model.gguf", "a.gguf")
        let second = directory("https://example.com/repo-a/model.gguf", "b.gguf")

        XCTAssertEqual(first.lastPathComponent, ".aria2-staging-22a30703215b-a.gguf")
        XCTAssertEqual(second.lastPathComponent, ".aria2-staging-22a30703215b-b.gguf")
    }

    func test_filenameIsReducedToItsLeafComponent() {
        // A path-shaped filename must not escape the runtime directory or create nested staging.
        let url = directory("https://example.com/repo-a/model.gguf", "../nested/model.gguf")

        XCTAssertEqual(url.deletingLastPathComponent().path, runtimeDirectory.path)
        XCTAssertEqual(url.lastPathComponent, ".aria2-staging-22a30703215b-model.gguf")
    }
}
