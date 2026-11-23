import Foundation
import XCTest
@testable import Cotabby

/// Locks where debug artifacts live and how they are protected: one directory under
/// `~/Library/Logs/<app>/`, owner-only folders and files, capped capture folders, and a Delete All
/// sweep that removes exactly the artifacts that can hold typed text.
///
/// Every case runs against a per-test temporary directory, never the user's real logs.
final class CotabbyDebugArtifactsTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = try makeTemporaryDirectory()
    }

    override func tearDown() {
        directory = nil
        super.tearDown()
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? Int) & 0o777
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - Layout

    func test_directory_isTheBundlesFolderUnderLibraryLogs() {
        let library = URL(fileURLWithPath: "/Users/someone/Library", isDirectory: true)

        XCTAssertEqual(
            CotabbyDebugArtifacts.directory(libraryURL: library, bundleName: "Cotabby Dev")?.path,
            "/Users/someone/Library/Logs/Cotabby Dev"
        )
    }

    func test_directory_fallsBackToCotabbyWithoutABundleName() {
        let library = URL(fileURLWithPath: "/Users/someone/Library", isDirectory: true)

        XCTAssertEqual(CotabbyDebugArtifacts.directory(libraryURL: library, bundleName: nil)?.lastPathComponent, "Cotabby")
        XCTAssertEqual(CotabbyDebugArtifacts.directory(libraryURL: library, bundleName: "")?.lastPathComponent, "Cotabby")
        XCTAssertNil(CotabbyDebugArtifacts.directory(libraryURL: nil, bundleName: "Cotabby"))
    }

    func test_liveArtifactsAreNotOnTheDesktop() throws {
        // The Desktop is often synced to iCloud; nothing that can hold typed text belongs there.
        let root = try XCTUnwrap(CotabbyDebugArtifacts.directoryURL)

        XCTAssertTrue(root.path.contains("/Library/Logs/"), root.path)
        XCTAssertFalse(root.path.contains("/Desktop"), root.path)
    }

    func test_calibrationStripSwitchIsCompiledOutOfShippingBuilds() {
        #if !(DEBUG || COTABBY_DEV)
        XCTAssertFalse(CotabbyDebugArtifacts.dumpsCalibrationStrips)
        #endif
        XCTAssertEqual(CotabbyDebugArtifacts.calibrationStripsDefaultsKey, "cotabbyDumpCalibrationStrips")
    }

    // MARK: - Owner-only modes

    func test_preparedDirectory_createsOwnerOnlyFoldersAndTightensAnExistingRoot() throws {
        let root = directory.appendingPathComponent("Logs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755]
        )

        let folder = try XCTUnwrap(CotabbyDebugArtifacts.preparedDirectory(["screenshots", "Safari"], root: root))

        XCTAssertEqual(folder.path, root.appendingPathComponent("screenshots/Safari", isDirectory: true).path)
        XCTAssertEqual(try permissions(of: root), 0o700)
        XCTAssertEqual(try permissions(of: root.appendingPathComponent("screenshots")), 0o700)
        XCTAssertEqual(try permissions(of: folder), 0o700)
    }

    func test_preparedDirectory_isNilWithoutARoot() {
        XCTAssertNil(CotabbyDebugArtifacts.preparedDirectory(["strips"], root: nil))
    }

    func test_writePrivateFile_createsAndReplacesFilesOwnerOnly() throws {
        let url = directory.appendingPathComponent("ax-dump.txt")
        try Data("old".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        XCTAssertTrue(CotabbyDebugArtifacts.writePrivateFile(Data("new".utf8), to: url))

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new")
        XCTAssertEqual(try permissions(of: url), 0o600)
    }

    // MARK: - Capture eviction

    func test_evictOldCaptures_keepsTheNewestCapturesWithTheirSidecars() throws {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<5 {
            for fileExtension in ["png", "json"] {
                let url = directory.appendingPathComponent("strip-\(index).\(fileExtension)")
                try Data("x".utf8).write(to: url)
                try FileManager.default.setAttributes(
                    [.modificationDate: base.addingTimeInterval(Double(index))], ofItemAtPath: url.path
                )
            }
        }

        CotabbyDebugArtifacts.evictOldCaptures(in: directory, keeping: 2)

        let remaining = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(remaining, ["strip-3.json", "strip-3.png", "strip-4.json", "strip-4.png"])
    }

    func test_evictOldCaptures_leavesAFolderUnderTheCapAlone() throws {
        try Data("x".utf8).write(to: directory.appendingPathComponent("caret-1.png"))
        try Data("x".utf8).write(to: directory.appendingPathComponent("caret-1.json"))

        CotabbyDebugArtifacts.evictOldCaptures(in: directory, keeping: 2)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
    }

    // MARK: - Delete All

    func test_removeUserTextArtifacts_removesEveryArtifactThatCanHoldTypedText() throws {
        for name in ["cotabby.jsonl", "cotabby.jsonl.1", "llm-io.jsonl", "llm-io.jsonl.1", "ax-dump.txt"] {
            try Data("typed".utf8).write(to: directory.appendingPathComponent(name))
        }
        let screenshots = directory.appendingPathComponent("screenshots/Mail", isDirectory: true)
        let strips = directory.appendingPathComponent("strips", isDirectory: true)
        try FileManager.default.createDirectory(at: screenshots, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: strips, withIntermediateDirectories: true)
        try Data("ocr".utf8).write(to: screenshots.appendingPathComponent("capture.txt"))
        try Data("line".utf8).write(to: strips.appendingPathComponent("strip-1.json"))
        // Anything else in the folder is not Cotabby's to delete.
        let unrelated = directory.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: unrelated)

        CotabbyDebugArtifacts.removeUserTextArtifacts(in: directory)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["notes.txt"])
        XCTAssertTrue(exists(unrelated))
    }

    func test_removeUserTextArtifacts_isANoOpOnAnEmptyFolder() throws {
        CotabbyDebugArtifacts.removeUserTextArtifacts(in: directory)

        XCTAssertTrue(exists(directory))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [])
    }

    func test_userTextArtifactNames_coverEveryWriter() {
        let names = Set(CotabbyDebugArtifacts.userTextArtifactNames)

        for name in [
            CotabbyDebugArtifacts.eventLogName,
            CotabbyDebugArtifacts.llmIOLogName,
            CotabbyDebugArtifacts.axDumpName,
            CotabbyDebugArtifacts.screenshotsFolderName,
            CotabbyDebugArtifacts.stripsFolderName
        ] {
            XCTAssertTrue(names.contains(name), name)
        }
        XCTAssertTrue(names.contains(CotabbyDebugArtifacts.eventLogName + ".1"))
        XCTAssertTrue(names.contains(CotabbyDebugArtifacts.llmIOLogName + ".1"))
    }
}
