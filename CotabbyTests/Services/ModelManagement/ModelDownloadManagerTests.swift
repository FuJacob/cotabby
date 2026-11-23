import XCTest
@testable import Cotabby

/// Locks the download manager's filesystem-facing state rules: install detection, deletion,
/// same-filename source isolation, and cancel/pause transitions. Every manager points at a fresh
/// temporary directory; tests that need no transfer never start one.
@MainActor
final class ModelDownloadManagerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = try makeTemporaryDirectory()
    }

    func test_modelsDirectoryPath_pointsToProvidedRuntimeDirectory() {
        let manager = makeManager()
        XCTAssertEqual(manager.modelsDirectoryPath, tempDir.path)
    }

    func test_isModelInstalled_returnsFalseWhenFileAbsent() {
        let manager = makeManager()
        XCTAssertFalse(manager.isModelInstalled(filename: "nonexistent.gguf"))
    }

    func test_isModelInstalled_returnsTrueWhenFileExistsInDirectory() throws {
        let testFile = tempDir.appendingPathComponent("test-model.gguf")
        try "dummy model content".write(to: testFile, atomically: true, encoding: .utf8)

        let manager = makeManager()
        XCTAssertTrue(manager.isModelInstalled(filename: "test-model.gguf"))
    }

    func test_canDeleteModel_onlyAllowsUserRuntimeDirectoryFiles() throws {
        let testFile = tempDir.appendingPathComponent("deletable.gguf")
        try "content".write(to: testFile, atomically: true, encoding: .utf8)

        let manager = makeManager()
        XCTAssertTrue(manager.canDeleteModel(filename: "deletable.gguf"))
        XCTAssertFalse(manager.canDeleteModel(filename: "nonexistent.gguf"))
    }

    func test_deleteModel_removesFileAndRefreshesState() throws {
        let testFile = tempDir.appendingPathComponent("to-delete.gguf")
        try "content".write(to: testFile, atomically: true, encoding: .utf8)

        let manager = makeManager()
        XCTAssertTrue(manager.isModelInstalled(filename: "to-delete.gguf"))

        manager.deleteModel(filename: "to-delete.gguf")
        XCTAssertFalse(manager.isModelInstalled(filename: "to-delete.gguf"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: testFile.path))
    }

    func test_sameFilenameSourcesKeepIndependentStateAndPreserveFailureOnRefresh() async throws {
        let manager = makeManager()
        let first = try makeModel(source: "https://example.com/first/shared.gguf")
        let second = try makeModel(source: "https://example.com/second/shared.gguf")

        manager.download(first)
        manager.download(second)

        XCTAssertTrue(manager.state(for: first).isDownloading)
        guard case .failed(let message) = manager.state(for: second) else {
            return XCTFail("Expected the second source to be blocked by the flat destination policy")
        }
        XCTAssertTrue(message.contains("Cancel that transfer"))
        XCTAssertNotEqual(first.id, second.id)

        manager.cancel(first)
        try await waitForTransferToSettle(first, in: manager)
        manager.refreshModelStates()

        guard case .failed(let refreshedMessage) = manager.state(for: second) else {
            return XCTFail("Expected refresh to preserve the dynamic model's failure message")
        }
        XCTAssertEqual(refreshedMessage, message)
    }

    func test_refreshPreservesPausedDynamicSourceAndInactiveCancelReturnsToIdle() async throws {
        let manager = makeManager()
        let model = try makeModel(source: "https://example.com/paused/shared.gguf")

        manager.download(model)
        manager.pause(model)
        try await waitForTransferToSettle(model, in: manager)

        guard case .paused = manager.state(for: model) else {
            return XCTFail("Expected pause during setup to publish a paused state")
        }
        manager.refreshModelStates()
        guard case .paused = manager.state(for: model) else {
            return XCTFail("Expected refresh to preserve the paused dynamic source")
        }

        manager.cancel(model)
        XCTAssertEqual(manager.state(for: model), .idle)
    }

    /// A cancel deletes the partial data, so a pause pressed afterwards (both buttons stay visible
    /// until the transfer settles) must not turn the row back into a resumable one.
    func test_pauseAfterCancelStillCancelsTheTransfer() async throws {
        let manager = makeManager()
        let model = try makeModel(source: "https://example.com/cancel-then-pause/shared.gguf")

        manager.download(model)
        manager.cancel(model)
        manager.pause(model)
        try await waitForTransferToSettle(model, in: manager)

        XCTAssertEqual(manager.state(for: model), .idle)
    }

    func test_cancelAfterPauseDuringSetupCancelsTheTransfer() async throws {
        let manager = makeManager()
        let model = try makeModel(source: "https://example.com/pause-then-cancel/shared.gguf")

        manager.download(model)
        manager.pause(model)
        manager.cancel(model)
        try await waitForTransferToSettle(model, in: manager)

        XCTAssertEqual(manager.state(for: model), .idle)
    }

    /// A paused source keeps its claim on the flat destination filename until it is cancelled.
    func test_pausedSourceBlocksAnotherSourceUntilCancelled() async throws {
        let manager = makeManager()
        let first = try makeModel(source: "https://example.com/first/shared.gguf")
        let second = try makeModel(source: "https://example.com/second/shared.gguf")

        manager.download(first)
        manager.pause(first)
        try await waitForTransferToSettle(first, in: manager)
        manager.download(second)
        guard case .failed = manager.state(for: second) else {
            return XCTFail("Expected the paused source to block the second one")
        }

        manager.cancel(first)
        manager.download(second)
        XCTAssertTrue(manager.state(for: second).isDownloading)

        manager.cancel(second)
        try await waitForTransferToSettle(second, in: manager)
    }

    func test_inactiveCancelRestoresDownloadedWhenDestinationExists() throws {
        let installedURL = tempDir.appendingPathComponent("shared.gguf")
        try "installed".write(to: installedURL, atomically: true, encoding: .utf8)
        let manager = makeManager()
        let model = try makeModel(source: "https://example.com/installed/shared.gguf")

        manager.cancel(model)

        XCTAssertEqual(manager.state(for: model), .downloaded)
    }

    /// Builds that used aria2 left hidden staging directories (possibly multi-GB partials) in the
    /// model folder. The sweep removes exactly those and leaves models, sidecars and other hidden
    /// entries alone.
    func test_legacyAria2StagingSweepRemovesOnlyStagingDirectories() throws {
        let fileManager = FileManager.default
        let scopedStaging = tempDir.appendingPathComponent(".aria2-staging-0123456789ab-shared.gguf", isDirectory: true)
        let filenameOnlyStaging = tempDir.appendingPathComponent(".aria2-staging-shared.gguf", isDirectory: true)
        for directory in [scopedStaging, filenameOnlyStaging] {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            try "partial".write(
                to: directory.appendingPathComponent("shared.gguf.aria2"),
                atomically: true,
                encoding: .utf8
            )
        }
        let installedModel = tempDir.appendingPathComponent("shared.gguf")
        let stagingNamedFile = tempDir.appendingPathComponent(".aria2-staging-not-a-directory")
        let otherHiddenDirectory = tempDir.appendingPathComponent(".import-in-progress", isDirectory: true)
        try "installed".write(to: installedModel, atomically: true, encoding: .utf8)
        try "file".write(to: stagingNamedFile, atomically: true, encoding: .utf8)
        try fileManager.createDirectory(at: otherHiddenDirectory, withIntermediateDirectories: true)

        ModelDownloadManager.removeLegacyAria2StagingDirectories(in: tempDir)

        XCTAssertFalse(fileManager.fileExists(atPath: scopedStaging.path))
        XCTAssertFalse(fileManager.fileExists(atPath: filenameOnlyStaging.path))
        XCTAssertTrue(fileManager.fileExists(atPath: installedModel.path))
        XCTAssertTrue(fileManager.fileExists(atPath: stagingNamedFile.path))
        XCTAssertTrue(fileManager.fileExists(atPath: otherHiddenDirectory.path))
    }

    func test_legacyAria2StagingSweepIgnoresMissingDirectory() {
        let missing = tempDir.appendingPathComponent("missing", isDirectory: true)
        ModelDownloadManager.removeLegacyAria2StagingDirectories(in: missing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }

    /// An installed destination short-circuits `download` without starting a transfer, and
    /// deleting that file lets the untracked dynamic state fall back to "not installed".
    func test_downloadOfInstalledModelPublishesDownloadedThenDeleteReturnsToIdle() throws {
        let filename = "cotabby-test-\(UUID().uuidString).gguf"
        try "installed".write(to: tempDir.appendingPathComponent(filename), atomically: true, encoding: .utf8)
        let manager = makeManager()
        let model = DownloadableRuntimeModel(
            filename: filename,
            displayName: "Installed",
            downloadURL: try XCTUnwrap(URL(string: "https://example.com/installed.gguf")),
            approximateSizeInGigabytes: 1
        )

        manager.download(model)
        XCTAssertEqual(manager.state(for: model), .downloaded)

        manager.deleteModel(filename: filename)
        XCTAssertEqual(manager.state(for: model), .idle)
    }

    func test_pauseWithoutActiveTransferIsNoOp() throws {
        let manager = makeManager()
        let model = try makeModel(source: "https://example.com/idle/shared.gguf")

        manager.pause(model)

        XCTAssertEqual(manager.state(for: model), .idle)
    }

    private func makeManager() -> ModelDownloadManager {
        TestLifetime.retain(ModelDownloadManager(runtimeDirectoryURL: tempDir))
    }

    private func makeModel(source: String) throws -> DownloadableRuntimeModel {
        let url = try XCTUnwrap(URL(string: source))
        return DownloadableRuntimeModel(
            filename: "shared.gguf",
            displayName: "Shared",
            downloadURL: url,
            approximateSizeInGigabytes: 1
        )
    }

    private func waitForTransferToSettle(
        _ model: DownloadableRuntimeModel,
        in manager: ModelDownloadManager
    ) async throws {
        for _ in 0..<200 {
            if !manager.state(for: model).isDownloading {
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("The model transfer did not settle after cancellation")
    }
}
