import Foundation

/// File overview:
/// Resolves which local model assets Tabby should load from user-managed storage.
/// Supports both single-file GGUF models and directory-based MLX models.
/// This keeps startup deterministic while ensuring large model files are never required in the app bundle.
///
enum BundledRuntimeLocatorError: LocalizedError {
    case runtimeDirectoryMissing(String)
    case modelMissing(String)
    case namedModelMissing(String)

    var errorDescription: String? {
        switch self {
        case .runtimeDirectoryMissing(let path):
            return "Runtime directory is missing at \(path)."
        case .modelMissing(let path):
            return "No GGUF model was found at \(path)."
        case .namedModelMissing(let filename):
            return "The local model \(filename) was not found."
        }
    }
}

/// Resolves locally installed model assets from user-writable runtime directories.
/// GGUF models are single files in `LlamaRuntime/`; MLX models are subdirectories
/// in `MLXRuntime/` containing `config.json` and `.safetensors` weight files.
struct BundledRuntimeLocator {
    private struct RuntimeCandidate {
        let runtimeDirectoryURL: URL
        let modelDirectoryURL: URL
    }

    static let runtimeFolderName = "LlamaRuntime"
    static let mlxRuntimeFolderName = "MLXRuntime"

    let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    /// Returns the user-writable runtime directory used for on-demand model downloads.
    /// This keeps large GGUF assets out of the app bundle and allows independent model updates.
    static func userRuntimeDirectoryURL(bundle: Bundle = .main) -> URL {
        let appSupportRoot =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        let appFolderName =
            (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Tabby"
        return
            appSupportRoot
            .appendingPathComponent(appFolderName, isDirectory: true)
            .appendingPathComponent(Self.runtimeFolderName, isDirectory: true)
    }

    /// Returns the user-writable directory for MLX model storage.
    static func mlxRuntimeDirectoryURL(bundle: Bundle = .main) -> URL {
        let appSupportRoot =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        let appFolderName =
            (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Tabby"
        return
            appSupportRoot
            .appendingPathComponent(appFolderName, isDirectory: true)
            .appendingPathComponent(Self.mlxRuntimeFolderName, isDirectory: true)
    }

    /// Ordered runtime search directories used to discover GGUF files.
    /// This mirrors runtime resolution order and is shared by model-install status checks.
    static func runtimeSearchDirectories(bundle: Bundle = .main) -> [URL] {
        [userRuntimeDirectoryURL(bundle: bundle)]
    }

    /// Search directories for MLX model discovery.
    static func mlxRuntimeSearchDirectories(bundle: Bundle = .main) -> [URL] {
        [mlxRuntimeDirectoryURL(bundle: bundle)]
    }

    /// Finds the first preferred local model that exists and returns the fully resolved runtime asset paths.
    func resolve(configuration: LlamaRuntimeConfiguration) throws -> ResolvedLlamaRuntime {
        try resolve(configuration: configuration, selectedModelFilename: nil)
    }

    /// Resolves a specific model when selected explicitly, or the default preferred model order otherwise.
    func resolve(
        configuration: LlamaRuntimeConfiguration,
        selectedModelFilename: String?
    ) throws -> ResolvedLlamaRuntime {
        var lastError: Error?

        // We try candidates in order so explicit runtime overrides can opt into custom directories.
        for candidate in runtimeCandidates(for: configuration) {
            do {
                let modelOptions = try availableModels(
                    candidate: candidate,
                    preferredModelNames: configuration.preferredModelNames
                )

                let selectedOption: RuntimeModelOption
                if let selectedModelFilename {
                    guard
                        let matchingOption = modelOptions.first(where: {
                            $0.filename == selectedModelFilename
                        })
                    else {
                        throw BundledRuntimeLocatorError.namedModelMissing(selectedModelFilename)
                    }
                    selectedOption = matchingOption
                } else if let firstOption = modelOptions.first {
                    selectedOption = firstOption
                } else {
                    throw BundledRuntimeLocatorError.modelMissing(candidate.modelDirectoryURL.path)
                }

                return resolvedRuntime(from: selectedOption, candidate: candidate)
            } catch {
                lastError = error
            }
        }

        throw lastError
            ?? BundledRuntimeLocatorError.runtimeDirectoryMissing(
                "No runtime candidates were available.")
    }

    /// Lists all GGUF models in deterministic display order for the highest-priority runtime candidate.
    func availableModels(configuration: LlamaRuntimeConfiguration) -> [RuntimeModelOption] {
        for candidate in runtimeCandidates(for: configuration) {
            if let modelOptions = try? availableModels(
                candidate: candidate,
                preferredModelNames: configuration.preferredModelNames
            ),
                !modelOptions.isEmpty {
                return modelOptions
            }
        }

        return []
    }

    /// Enumerates runtime directories. By default we only load from the user-managed model directory.
    /// An explicit `runtimeDirectoryPath` can override this for tests or advanced local setups.
    private func runtimeCandidates(for configuration: LlamaRuntimeConfiguration)
        -> [RuntimeCandidate] {
        if let runtimeDirectoryPath = configuration.runtimeDirectoryPath,
            !runtimeDirectoryPath.isEmpty {
            let runtimeDirectoryURL = URL(fileURLWithPath: runtimeDirectoryPath, isDirectory: true)
            return [
                RuntimeCandidate(
                    runtimeDirectoryURL: runtimeDirectoryURL,
                    modelDirectoryURL: runtimeDirectoryURL
                )
            ]
        }

        let userRuntimeDirectoryURL = Self.userRuntimeDirectoryURL(bundle: bundle)
        return [
            RuntimeCandidate(
                runtimeDirectoryURL: userRuntimeDirectoryURL,
                modelDirectoryURL: userRuntimeDirectoryURL
            )
        ]
    }

    /// Enumerates and orders all GGUF models for one runtime candidate.
    /// Preferred names come first; user-added GGUF files are appended alphabetically.
    private func availableModels(
        candidate: RuntimeCandidate,
        preferredModelNames: [String]
    ) throws -> [RuntimeModelOption] {
        let fileManager = FileManager.default
        var isDirectory = ObjCBool(false)

        guard
            fileManager.fileExists(
                atPath: candidate.runtimeDirectoryURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw BundledRuntimeLocatorError.runtimeDirectoryMissing(
                candidate.runtimeDirectoryURL.path)
        }

        var isModelDirectory = ObjCBool(false)
        guard
            fileManager.fileExists(
                atPath: candidate.modelDirectoryURL.path, isDirectory: &isModelDirectory),
            isModelDirectory.boolValue
        else {
            throw BundledRuntimeLocatorError.modelMissing(candidate.modelDirectoryURL.path)
        }

        let discoveredModelURLs = try fileManager.contentsOfDirectory(
            at: candidate.modelDirectoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension.caseInsensitiveCompare("gguf") == .orderedSame }

        guard !discoveredModelURLs.isEmpty else {
            throw BundledRuntimeLocatorError.modelMissing(candidate.modelDirectoryURL.path)
        }

        let modelOptionsByFilename = Dictionary(
            uniqueKeysWithValues: discoveredModelURLs.map { modelURL in
                let option = RuntimeModelOption(
                    filename: modelURL.lastPathComponent,
                    url: modelURL,
                    format: .gguf
                )
                return (option.filename, option)
            })

        var orderedModels: [RuntimeModelOption] = []
        var seenFilenames = Set<String>()

        for preferredModelName in preferredModelNames {
            guard let modelOption = modelOptionsByFilename[preferredModelName],
                seenFilenames.insert(preferredModelName).inserted
            else {
                continue
            }

            orderedModels.append(modelOption)
        }

        // Custom user-added GGUF files are appended so they stay selectable without being
        // explicitly listed in preferredModelNames.
        let sortedDiscoveredModels =
            discoveredModelURLs
            .map { modelURL in
                RuntimeModelOption(
                    filename: modelURL.lastPathComponent,
                    url: modelURL,
                    format: .gguf
                )
            }
            .sorted { lhs, rhs in
                lhs.filename.localizedCaseInsensitiveCompare(rhs.filename) == .orderedAscending
            }

        for modelOption in sortedDiscoveredModels {
            guard seenFilenames.insert(modelOption.filename).inserted else {
                continue
            }

            orderedModels.append(modelOption)
        }

        // Defensive fallback for unexpected directory listing anomalies.
        if orderedModels.isEmpty {
            throw BundledRuntimeLocatorError.modelMissing(candidate.modelDirectoryURL.path)
        }

        return orderedModels
    }

    /// Builds the concrete runtime asset paths for one chosen model option.
    private func resolvedRuntime(
        from modelOption: RuntimeModelOption,
        candidate: RuntimeCandidate
    ) -> ResolvedLlamaRuntime {
        ResolvedLlamaRuntime(
            runtimeDirectoryURL: candidate.runtimeDirectoryURL,
            modelFileURL: modelOption.url,
            modelDisplayName: modelOption.displayName
        )
    }

    // MARK: - MLX Model Discovery

    /// Discovers MLX models installed as subdirectories containing `config.json`
    /// and at least one `.safetensors` weight file.
    func availableMLXModels(preferredModelNames: [String] = []) -> [RuntimeModelOption] {
        let directoryURL = Self.mlxRuntimeDirectoryURL(bundle: bundle)
        let fileManager = FileManager.default
        var isDirectory = ObjCBool(false)

        guard
            fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            return []
        }

        guard
            let contents = try? fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        let validModelDirs = contents.filter { url in
            var isDirFlag = ObjCBool(false)
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirFlag),
                isDirFlag.boolValue
            else {
                return false
            }
            let configExists = fileManager.fileExists(
                atPath: url.appendingPathComponent("config.json").path
            )
            let hasSafetensors = (try? fileManager.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            ))?.contains { $0.pathExtension == "safetensors" } ?? false
            return configExists && hasSafetensors
        }

        guard !validModelDirs.isEmpty else { return [] }

        let optionsByName = Dictionary(
            uniqueKeysWithValues: validModelDirs.map { dirURL in
                let option = RuntimeModelOption(
                    filename: dirURL.lastPathComponent,
                    url: dirURL,
                    format: .mlx
                )
                return (option.filename, option)
            }
        )

        var ordered: [RuntimeModelOption] = []
        var seen = Set<String>()

        for name in preferredModelNames {
            if let option = optionsByName[name], seen.insert(name).inserted {
                ordered.append(option)
            }
        }

        let sorted = validModelDirs
            .map { RuntimeModelOption(filename: $0.lastPathComponent, url: $0, format: .mlx) }
            .sorted { $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending }

        for option in sorted where seen.insert(option.filename).inserted {
            ordered.append(option)
        }

        return ordered
    }
}
