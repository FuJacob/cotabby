import XCTest
@testable import Cotabby

final class BundledRuntimeLocatorTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for url in temporaryDirectories {
            try? FileManager.default.removeItem(at: url)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    // MARK: - resolve

    func test_resolve_returnsPreferredModelWhenMultipleGGUFsExist() throws {
        let dir = try makeTemporaryRuntimeDirectory(
            ggufFilenames: ["alpha.gguf", "beta.gguf", "gamma.gguf"]
        )
        let config = makeConfig(runtimePath: dir.path, preferred: ["beta.gguf"])
        let locator = BundledRuntimeLocator()

        let resolved = try locator.resolve(configuration: config)
        XCTAssertEqual(resolved.modelFileURL.lastPathComponent, "beta.gguf")
    }

    func test_resolve_fallsBackToAlphabeticalWhenNoPreferredModelExists() throws {
        let dir = try makeTemporaryRuntimeDirectory(
            ggufFilenames: ["charlie.gguf", "alpha.gguf", "bravo.gguf"]
        )
        let config = makeConfig(runtimePath: dir.path, preferred: ["nonexistent.gguf"])
        let locator = BundledRuntimeLocator()

        let resolved = try locator.resolve(configuration: config)
        XCTAssertEqual(resolved.modelFileURL.lastPathComponent, "alpha.gguf")
    }

    func test_resolve_selectsExplicitlyNamedModel() throws {
        let dir = try makeTemporaryRuntimeDirectory(
            ggufFilenames: ["first.gguf", "second.gguf"]
        )
        let config = makeConfig(runtimePath: dir.path, preferred: ["first.gguf"])
        let locator = BundledRuntimeLocator()

        let resolved = try locator.resolve(
            configuration: config,
            selectedModelFilename: "second.gguf"
        )
        XCTAssertEqual(resolved.modelFileURL.lastPathComponent, "second.gguf")
    }

    func test_resolve_throwsNamedModelMissingForNonexistentSelection() throws {
        let dir = try makeTemporaryRuntimeDirectory(ggufFilenames: ["model.gguf"])
        let config = makeConfig(runtimePath: dir.path, preferred: [])
        let locator = BundledRuntimeLocator()

        XCTAssertThrowsError(
            try locator.resolve(configuration: config, selectedModelFilename: "ghost.gguf")
        ) { error in
            guard case BundledRuntimeLocatorError.namedModelMissing = error else {
                XCTFail("Expected namedModelMissing, got \(error)")
                return
            }
        }
    }

    func test_resolve_throwsRuntimeDirectoryMissingWhenPathDoesNotExist() {
        let config = makeConfig(
            runtimePath: "/tmp/Cotabby-test-nonexistent-\(UUID().uuidString)",
            preferred: []
        )
        let locator = BundledRuntimeLocator()

        XCTAssertThrowsError(try locator.resolve(configuration: config)) { error in
            guard case BundledRuntimeLocatorError.runtimeDirectoryMissing = error else {
                XCTFail("Expected runtimeDirectoryMissing, got \(error)")
                return
            }
        }
    }

    func test_resolve_throwsModelMissingWhenDirectoryIsEmpty() throws {
        let dir = try makeTemporaryRuntimeDirectory(ggufFilenames: [])
        let config = makeConfig(runtimePath: dir.path, preferred: [])
        let locator = BundledRuntimeLocator()

        XCTAssertThrowsError(try locator.resolve(configuration: config)) { error in
            guard case BundledRuntimeLocatorError.modelMissing = error else {
                XCTFail("Expected modelMissing, got \(error)")
                return
            }
        }
    }

    func test_resolve_ignoresNonGGUFFiles() throws {
        let dir = try makeTemporaryRuntimeDirectory(ggufFilenames: ["model.gguf"])
        // Add non-GGUF files
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent("readme.txt").path,
            contents: nil
        )
        FileManager.default.createFile(
            atPath: dir.appendingPathComponent("weights.bin").path,
            contents: nil
        )
        let config = makeConfig(runtimePath: dir.path, preferred: [])
        let locator = BundledRuntimeLocator()

        let models = locator.availableModels(configuration: config)
        XCTAssertEqual(models.count, 1)
        XCTAssertEqual(models.first?.filename, "model.gguf")
    }

    // MARK: - availableModels

    func test_availableModels_ordersPreferredThenAlphabetical() throws {
        let dir = try makeTemporaryRuntimeDirectory(
            ggufFilenames: ["charlie.gguf", "alpha.gguf", "bravo.gguf"]
        )
        let config = makeConfig(runtimePath: dir.path, preferred: ["bravo.gguf"])
        let locator = BundledRuntimeLocator()

        let models = locator.availableModels(configuration: config)
        let filenames = models.map(\.filename)
        XCTAssertEqual(filenames, ["bravo.gguf", "alpha.gguf", "charlie.gguf"])
    }

    func test_availableModels_deduplicatesPreferredAndDiscovered() throws {
        let dir = try makeTemporaryRuntimeDirectory(
            ggufFilenames: ["alpha.gguf", "bravo.gguf"]
        )
        // alpha.gguf appears in both preferred list and directory
        let config = makeConfig(runtimePath: dir.path, preferred: ["alpha.gguf"])
        let locator = BundledRuntimeLocator()

        let models = locator.availableModels(configuration: config)
        let alphaCount = models.filter { $0.filename == "alpha.gguf" }.count
        XCTAssertEqual(alphaCount, 1, "Preferred model should not appear twice")
    }

    func test_availableModels_returnsEmptyArrayWhenDirectoryMissing() {
        let config = makeConfig(
            runtimePath: "/tmp/Cotabby-test-nonexistent-\(UUID().uuidString)",
            preferred: []
        )
        let locator = BundledRuntimeLocator()

        XCTAssertEqual(locator.availableModels(configuration: config), [])
    }

    func test_resolve_usesExplicitRuntimeDirectoryPathFromConfiguration() throws {
        let dir = try makeTemporaryRuntimeDirectory(ggufFilenames: ["custom.gguf"])
        let config = makeConfig(runtimePath: dir.path, preferred: [])
        let locator = BundledRuntimeLocator()

        let resolved = try locator.resolve(configuration: config)
        XCTAssertTrue(
            resolved.runtimeDirectoryURL.path.hasPrefix(dir.path),
            "Should resolve from the explicit runtime directory"
        )
    }

    // MARK: - Error descriptions

    func test_errorDescriptions_areHumanReadable() {
        let dirError = BundledRuntimeLocatorError.runtimeDirectoryMissing("/some/path")
        XCTAssertTrue(dirError.errorDescription?.contains("/some/path") ?? false)

        let modelError = BundledRuntimeLocatorError.modelMissing("/models")
        XCTAssertTrue(modelError.errorDescription?.contains("/models") ?? false)

        let namedError = BundledRuntimeLocatorError.namedModelMissing("test.gguf")
        XCTAssertTrue(namedError.errorDescription?.contains("test.gguf") ?? false)
    }

    // MARK: - Helpers

    private func makeTemporaryRuntimeDirectory(ggufFilenames: [String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Cotabby-locator-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        temporaryDirectories.append(dir)

        for filename in ggufFilenames {
            FileManager.default.createFile(
                atPath: dir.appendingPathComponent(filename).path,
                contents: nil
            )
        }
        return dir
    }

    private func makeConfig(
        runtimePath: String,
        preferred: [String]
    ) -> LlamaRuntimeConfiguration {
        LlamaRuntimeConfiguration(
            runtimeDirectoryPath: runtimePath,
            preferredModelNames: preferred,
            contextWindowTokens: 2048,
            batchSize: 512,
            gpuLayerCount: -1
        )
    }
}
