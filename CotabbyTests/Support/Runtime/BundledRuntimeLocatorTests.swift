import XCTest
@testable import Cotabby

/// Locks how Cotabby finds local GGUF models: explicit-directory overrides, preferred-then-
/// alphabetical ordering, recursive discovery with sidecar filtering, and the error surfaced for
/// each missing-asset shape. Every fixture lives in a temp directory removed in `tearDown`.
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

        let resolved = try locator.resolve(configuration: config, selectedModelFilename: nil)
        XCTAssertEqual(resolved.modelFileURL.lastPathComponent, "beta.gguf")
    }

    func test_resolve_fallsBackToAlphabeticalWhenNoPreferredModelExists() throws {
        let dir = try makeTemporaryRuntimeDirectory(
            ggufFilenames: ["charlie.gguf", "alpha.gguf", "bravo.gguf"]
        )
        let config = makeConfig(runtimePath: dir.path, preferred: ["nonexistent.gguf"])
        let locator = BundledRuntimeLocator()

        let resolved = try locator.resolve(configuration: config, selectedModelFilename: nil)
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

        XCTAssertThrowsError(try locator.resolve(configuration: config, selectedModelFilename: nil)) { error in
            guard case BundledRuntimeLocatorError.runtimeDirectoryMissing = error else {
                XCTFail("Expected runtimeDirectoryMissing, got \(error)")
                return
            }
        }
    }

    func test_resolve_throwsModelMissingWhenNoLoadableModelExists() throws {
        // An empty directory and one holding only a projector sidecar both have nothing loadable.
        for sidecars in [[], ["mmproj-model-F16.gguf"]] {
            let dir = try makeTemporaryRuntimeDirectory(ggufFilenames: sidecars)
            let config = makeConfig(runtimePath: dir.path, preferred: [])
            let locator = BundledRuntimeLocator()

            XCTAssertThrowsError(try locator.resolve(configuration: config, selectedModelFilename: nil)) { error in
                guard case BundledRuntimeLocatorError.modelMissing(let path) = error else {
                    XCTFail("Expected modelMissing for \(sidecars), got \(error)")
                    return
                }
                XCTAssertEqual(path, dir.path, "files: \(sidecars)")
            }
        }
    }

    func test_resolve_ignoresNonGGUFFiles() throws {
        let dir = try makeTemporaryRuntimeDirectory(
            ggufFilenames: ["model.gguf", "readme.txt", "weights.bin"]
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

    func test_availableModels_ignoresRepeatedAndMissingPreferredNames() throws {
        let dir = try makeTemporaryRuntimeDirectory(
            ggufFilenames: ["alpha.gguf", "bravo.gguf"]
        )
        // A preferred name listed twice must appear once; a preferred name not on disk is skipped.
        let config = makeConfig(
            runtimePath: dir.path,
            preferred: ["missing.gguf", "bravo.gguf", "bravo.gguf"]
        )
        let locator = BundledRuntimeLocator()

        XCTAssertEqual(
            locator.availableModels(configuration: config).map(\.filename),
            ["bravo.gguf", "alpha.gguf"]
        )
    }

    func test_availableModels_sortsCaseInsensitively() throws {
        let dir = try makeTemporaryRuntimeDirectory(
            ggufFilenames: ["beta.gguf", "Alpha.gguf", "charlie.gguf"]
        )
        let config = makeConfig(runtimePath: dir.path, preferred: [])

        XCTAssertEqual(
            BundledRuntimeLocator().availableModels(configuration: config).map(\.filename),
            ["Alpha.gguf", "beta.gguf", "charlie.gguf"]
        )
    }

    func test_availableModels_returnsEmptyArrayWhenDirectoryMissing() {
        let config = makeConfig(
            runtimePath: "/tmp/Cotabby-test-nonexistent-\(UUID().uuidString)",
            preferred: []
        )
        let locator = BundledRuntimeLocator()

        XCTAssertEqual(locator.availableModels(configuration: config), [])
    }

    func test_resolve_usesExplicitRuntimeDirectoryPathAndCatalogDisplayName() throws {
        let dir = try makeTemporaryRuntimeDirectory(ggufFilenames: ["gemma-4-E2B.i1-Q6_K.gguf"])
        let config = makeConfig(runtimePath: dir.path, preferred: [])
        let locator = BundledRuntimeLocator()

        let resolved = try locator.resolve(configuration: config, selectedModelFilename: nil)
        XCTAssertEqual(resolved.runtimeDirectoryURL.path, dir.path)
        XCTAssertEqual(resolved.modelFileURL.lastPathComponent, "gemma-4-E2B.i1-Q6_K.gguf")
        // Known catalog files resolve to their product name rather than the raw filename.
        XCTAssertEqual(resolved.modelDisplayName, "Cotabby Base")
    }

    func test_emptyRuntimeDirectoryPathFallsBackToDefaultCandidates() {
        // An empty override is treated like nil, not as "the current directory". Both configurations
        // read the same real default directories (read-only), so their listings must match exactly.
        let emptyPath = makeConfig(runtimePath: "", preferred: [])
        let noPath = LlamaRuntimeConfiguration(
            runtimeDirectoryPath: nil,
            preferredModelNames: [],
            contextWindowTokens: 2048,
            batchSize: 512,
            gpuLayerCount: -1
        )
        let locator = BundledRuntimeLocator()

        XCTAssertEqual(
            locator.availableModels(configuration: emptyPath),
            locator.availableModels(configuration: noPath)
        )
    }

    // MARK: - Error descriptions

    func test_errorDescriptions_areHumanReadable() {
        XCTAssertEqual(
            BundledRuntimeLocatorError.runtimeDirectoryMissing("/some/path").errorDescription,
            "Runtime directory is missing at /some/path."
        )
        XCTAssertEqual(
            BundledRuntimeLocatorError.modelMissing("/models").errorDescription,
            "No GGUF model was found at /models."
        )
        XCTAssertEqual(
            BundledRuntimeLocatorError.namedModelMissing("test.gguf").errorDescription,
            "The local model test.gguf was not found."
        )
    }

    // MARK: - Recursive discovery (LM Studio nested layout)

    func test_discoverGGUFModelURLs_findsNestedModels() throws {
        // Mirrors LM Studio's `<publisher>/<repo>/<file>.gguf` layout, which a flat scan misses.
        let root = try makeTemporaryDirectory()
        try writeFile(at: root, relativePath: "publisher/repo/model.gguf")
        try writeFile(at: root, relativePath: "publisher/other-repo/another.gguf")

        let discovered = BundledRuntimeLocator.discoverGGUFModelURLs(in: root)
            .map(\.lastPathComponent)
            .sorted()

        XCTAssertEqual(discovered, ["another.gguf", "model.gguf"])
    }

    func test_discoverGGUFModelURLs_skipsMmprojSidecars() throws {
        let root = try makeTemporaryDirectory()
        try writeFile(at: root, relativePath: "publisher/repo/model.gguf")
        try writeFile(at: root, relativePath: "publisher/repo/mmproj-model-BF16.gguf")

        let discovered = BundledRuntimeLocator.discoverGGUFModelURLs(in: root)
            .map(\.lastPathComponent)

        XCTAssertEqual(discovered, ["model.gguf"], "mmproj projector sidecars are not loadable models")
    }

    func test_discoverGGUFModelURLs_filtersByExtensionVisibilityAndSidecarPrefix() throws {
        let root = try makeTemporaryDirectory()
        // Kept: the extension match is case-insensitive, and only the dashed `mmproj-` prefix marks
        // a projector sidecar.
        try writeFile(at: root, relativePath: "UPPER.GGUF")
        try writeFile(at: root, relativePath: "mmprojector.gguf")
        // Skipped: hidden files (and hidden directories' contents), a case-variant sidecar, and
        // files whose name merely contains "gguf".
        try writeFile(at: root, relativePath: ".hidden.gguf")
        try writeFile(at: root, relativePath: ".cache/model.gguf")
        try writeFile(at: root, relativePath: "MMPROJ-vision.gguf")
        try writeFile(at: root, relativePath: "model.gguf.part")

        let discovered = BundledRuntimeLocator.discoverGGUFModelURLs(in: root)
            .map(\.lastPathComponent)
            .sorted()

        XCTAssertEqual(discovered, ["UPPER.GGUF", "mmprojector.gguf"])
    }

    func test_discoverGGUFModelURLs_returnsEmptyForMissingDirectory() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("Cotabby-locator-missing-\(UUID().uuidString)", isDirectory: true)

        XCTAssertEqual(BundledRuntimeLocator.discoverGGUFModelURLs(in: missing), [])
    }

    func test_discoverGGUFModelURLs_skipsDirectoriesWithGGUFExtension() throws {
        // A directory can legitimately carry a `.gguf` name; it is not a loadable model file.
        let root = try makeTemporaryDirectory()
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("bundle.gguf", isDirectory: true),
            withIntermediateDirectories: true
        )
        try writeFile(at: root, relativePath: "real.gguf")

        let discovered = BundledRuntimeLocator.discoverGGUFModelURLs(in: root)
            .map(\.lastPathComponent)

        XCTAssertEqual(discovered, ["real.gguf"])
    }

    func test_discoverGGUFModelURLs_respectsMaxDepth() throws {
        let root = try makeTemporaryDirectory()
        try writeFile(at: root, relativePath: "a/b/c/deep.gguf")

        let shallow = BundledRuntimeLocator.discoverGGUFModelURLs(in: root, maxDepth: 2)
        XCTAssertTrue(shallow.isEmpty, "A file below the depth bound should not be discovered")

        let deep = BundledRuntimeLocator.discoverGGUFModelURLs(in: root, maxDepth: 4)
        XCTAssertEqual(deep.map(\.lastPathComponent), ["deep.gguf"])
    }

    func test_availableModels_discoversNestedLayoutThroughPublicAPI() throws {
        let root = try makeTemporaryDirectory()
        try writeFile(at: root, relativePath: "publisher/repo/nested.gguf")
        let config = makeConfig(runtimePath: root.path, preferred: [])
        let locator = BundledRuntimeLocator()

        let filenames = locator.availableModels(configuration: config).map(\.filename)
        XCTAssertEqual(filenames, ["nested.gguf"])
    }

    func test_availableModels_dedupesDuplicateFilenamesAcrossNestedRepos() throws {
        // Two repos shipping the same filename must not trap the keyed lookup or appear twice.
        let root = try makeTemporaryDirectory()
        try writeFile(at: root, relativePath: "publisher/repo-a/model.gguf")
        try writeFile(at: root, relativePath: "publisher/repo-b/model.gguf")
        let config = makeConfig(runtimePath: root.path, preferred: [])
        let locator = BundledRuntimeLocator()

        let filenames = locator.availableModels(configuration: config).map(\.filename)
        XCTAssertEqual(filenames, ["model.gguf"])
    }

    // MARK: - LM Studio source toggle

    func test_lmStudioSourceToggle_persistsAndClears() {
        let key = BundledRuntimeLocator.lmStudioSourceEnabledKey
        let original = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(original, forKey: key) }

        UserDefaults.standard.set(true, forKey: key)
        XCTAssertTrue(BundledRuntimeLocator.isLMStudioSourceEnabled())

        UserDefaults.standard.set(false, forKey: key)
        XCTAssertFalse(BundledRuntimeLocator.isLMStudioSourceEnabled())
        // Disabled means no LM Studio directory is ever returned, even if it exists on disk.
        XCTAssertNil(BundledRuntimeLocator.enabledLMStudioModelsDirectory())
    }

    // MARK: - User runtime directory resolution

    func test_userRuntimeDirectoryURL_usesBundleNameFromInfoPlist() throws {
        let bundle = try makeBundle(withInfo: ["CFBundleName": "LocatorProbe"])

        let url = BundledRuntimeLocator.userRuntimeDirectoryURL(bundle: bundle)

        XCTAssertEqual(url.lastPathComponent, BundledRuntimeLocator.runtimeFolderName)
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "LocatorProbe")
        XCTAssertEqual(
            url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent,
            "Application Support"
        )
    }

    func test_userRuntimeDirectoryURL_keepsDevelopmentModelsSeparate() throws {
        let bundle = try makeBundle(withInfo: ["CFBundleName": "Cotabby Dev"])
        let url = BundledRuntimeLocator.userRuntimeDirectoryURL(bundle: bundle)
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Cotabby Dev")
        XCTAssertEqual(url.lastPathComponent, "LlamaRuntime")
    }

    func test_userRuntimeDirectoryURL_fallsBackToCotabbyFolderWhenBundleNameMissing() throws {
        // A bare directory bundle carries no Info.plist, so CFBundleName resolves to nil and the
        // app-folder name must fall back to "Cotabby" rather than producing a nameless path.
        let bundle = try makeBundle(withInfo: nil)

        let url = BundledRuntimeLocator.userRuntimeDirectoryURL(bundle: bundle)

        XCTAssertEqual(url.lastPathComponent, BundledRuntimeLocator.runtimeFolderName)
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Cotabby")
    }

    // MARK: - Default candidate enumeration (nil runtimeDirectoryPath)

    func test_resolve_defaultCandidates_throwsLocatorErrorForUnknownSelectedModel() {
        // No explicit runtime directory: the locator walks its default candidates (the user-managed
        // Application Support directory, plus LM Studio when enabled). The selected filename is
        // unique, so resolution must fail with a locator error on every machine regardless of which
        // models happen to be installed. This is read-only against the real directories.
        let config = LlamaRuntimeConfiguration(
            runtimeDirectoryPath: nil,
            preferredModelNames: [],
            contextWindowTokens: 2048,
            batchSize: 512,
            gpuLayerCount: -1
        )
        let locator = BundledRuntimeLocator()

        XCTAssertThrowsError(
            try locator.resolve(
                configuration: config,
                selectedModelFilename: "cotabby-test-missing-\(UUID().uuidString).gguf"
            )
        ) { error in
            XCTAssertTrue(error is BundledRuntimeLocatorError, "Expected a locator error, got \(error)")
        }
    }

    func test_runtimeSearchDirectories_putsUserManagedDirectoryFirst() {
        let directories = BundledRuntimeLocator.runtimeSearchDirectories(bundle: .main)

        // Cotabby's own directory is authoritative (and the download target), so it must always be
        // scanned first; the LM Studio library may or may not be appended depending on the toggle.
        XCTAssertEqual(directories.first, BundledRuntimeLocator.userRuntimeDirectoryURL(bundle: .main))
        XCTAssertFalse(directories.isEmpty)
    }

    func test_lmStudioModelsDirectoryIfAvailable_returnsWellKnownPathOnlyWhenPresent() {
        // Machine-state dependent by design, so assert the contract that holds either way: nil when
        // ~/.lmstudio/models does not exist, otherwise exactly that directory.
        let url = BundledRuntimeLocator.lmStudioModelsDirectoryIfAvailable()

        if let url {
            XCTAssertTrue(url.path.hasSuffix("/.lmstudio/models"))
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        } else {
            let expected = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".lmstudio/models")
            XCTAssertFalse(FileManager.default.fileExists(atPath: expected.path))
        }
    }

    // MARK: - Helpers

    /// Builds a throwaway on-disk bundle. With `info`, a minimal `.app` layout carrying that
    /// Info.plist; with nil, a bare directory whose Bundle has no info dictionary values.
    private func makeBundle(withInfo info: [String: Any]?) throws -> Bundle {
        let root = try makeTemporaryDirectory()
        guard let info else {
            return try XCTUnwrap(Bundle(url: root))
        }
        let appURL = root.appendingPathComponent("Probe.app", isDirectory: true)
        let contentsURL = appURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let plistData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plistData.write(to: contentsURL.appendingPathComponent("Info.plist", isDirectory: false))
        return try XCTUnwrap(Bundle(url: appURL))
    }

    private func makeTemporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("Cotabby-locator-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        temporaryDirectories.append(dir)
        return dir
    }

    private func writeFile(at root: URL, relativePath: String) throws {
        let fileURL = root.appendingPathComponent(relativePath, isDirectory: false)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
    }

    private func makeTemporaryRuntimeDirectory(ggufFilenames: [String]) throws -> URL {
        let dir = try makeTemporaryDirectory()
        for filename in ggufFilenames {
            try writeFile(at: dir, relativePath: filename)
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
