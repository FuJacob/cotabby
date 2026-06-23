import Foundation

/// File overview:
/// Discovers locally installed MLX model snapshots from user-writable storage.
///
/// This boundary is intentionally pure filesystem logic. It does not load MLX, create tokenizers, or
/// publish UI state. That keeps model discovery deterministic and testable while leaving runtime
/// lifecycle decisions to `MlxRuntimeManager`.

enum MlxRuntimeLocatorError: LocalizedError {
    case runtimeDirectoryMissing(String)
    case modelMissing(String)
    case namedModelMissing(String)

    var errorDescription: String? {
        switch self {
        case .runtimeDirectoryMissing(let path):
            return "MLX runtime directory is missing at \(path)."
        case .modelMissing(let path):
            return "No MLX model snapshot was found at \(path)."
        case .namedModelMissing(let modelID):
            return "The MLX model \(modelID) was not found."
        }
    }
}

struct MlxRuntimeLocator {
    private struct RuntimeCandidate {
        let runtimeDirectoryURL: URL
        let modelDirectoryURL: URL
    }

    static let runtimeFolderName = "MlxRuntime"

    let bundle: Bundle

    init(bundle: Bundle = .main) {
        self.bundle = bundle
    }

    /// Returns the user-writable MLX runtime directory used for snapshot imports/downloads.
    static func userRuntimeDirectoryURL(bundle: Bundle = .main) -> URL {
        let appSupportRoot =
            FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
        let appFolderName =
            (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Cotabby"
        return
            appSupportRoot
            .appendingPathComponent(appFolderName, isDirectory: true)
            .appendingPathComponent(Self.runtimeFolderName, isDirectory: true)
    }

    /// Finds model snapshot directories that look loadable by MLX Swift LM.
    ///
    /// A valid snapshot needs `config.json`, at least one tokenizer file, and at least one weight
    /// file. We intentionally avoid deep semantic validation here; the runtime load path remains the
    /// authority for architecture/tokenizer correctness.
    static func discoverModelSnapshotURLs(in directoryURL: URL, maxDepth: Int = 3) -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        var results: [URL] = []
        for case let url as URL in enumerator {
            if enumerator.level > maxDepth {
                enumerator.skipDescendants()
                continue
            }
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            if isModelSnapshotDirectory(url) {
                results.append(url)
                enumerator.skipDescendants()
            }
        }
        return results
    }

    static func isModelSnapshotDirectory(_ directoryURL: URL) -> Bool {
        let fileManager = FileManager.default
        let configURL = directoryURL.appendingPathComponent("config.json", isDirectory: false)
        guard fileManager.fileExists(atPath: configURL.path) else {
            return false
        }

        let tokenizerNames = [
            "tokenizer.json",
            "tokenizer.model",
            "vocab.json"
        ]
        let hasTokenizer = tokenizerNames.contains { name in
            fileManager.fileExists(
                atPath: directoryURL.appendingPathComponent(name, isDirectory: false).path
            )
        }
        guard hasTokenizer else {
            return false
        }

        guard let contents = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return false
        }

        return contents.contains { url in
            let ext = url.pathExtension.lowercased()
            let name = url.lastPathComponent.lowercased()
            return ext == "safetensors" || ext == "npz" || name.hasSuffix(".bin")
        }
    }

    func resolve(configuration: MlxRuntimeConfiguration) throws -> ResolvedMlxRuntime {
        try resolve(configuration: configuration, selectedModelID: nil)
    }

    func resolve(
        configuration: MlxRuntimeConfiguration,
        selectedModelID: String?
    ) throws -> ResolvedMlxRuntime {
        var lastError: Error?

        for candidate in runtimeCandidates(for: configuration) {
            do {
                let modelOptions = try availableModels(
                    candidate: candidate,
                    preferredModelIDs: configuration.preferredModelIDs
                )
                let selectedOption: MlxRuntimeModelOption
                if let selectedModelID {
                    guard let matchingOption = modelOptions.first(where: { $0.id == selectedModelID }) else {
                        throw MlxRuntimeLocatorError.namedModelMissing(selectedModelID)
                    }
                    selectedOption = matchingOption
                } else if let firstOption = modelOptions.first {
                    selectedOption = firstOption
                } else {
                    throw MlxRuntimeLocatorError.modelMissing(candidate.modelDirectoryURL.path)
                }

                return resolvedRuntime(from: selectedOption, candidate: candidate)
            } catch {
                lastError = error
            }
        }

        throw lastError
            ?? MlxRuntimeLocatorError.runtimeDirectoryMissing("No MLX runtime candidates were available.")
    }

    func availableModels(configuration: MlxRuntimeConfiguration) -> [MlxRuntimeModelOption] {
        var merged: [MlxRuntimeModelOption] = []
        var seenIDs = Set<String>()

        for candidate in runtimeCandidates(for: configuration) {
            guard let modelOptions = try? availableModels(
                candidate: candidate,
                preferredModelIDs: configuration.preferredModelIDs
            ) else {
                continue
            }

            for option in modelOptions where seenIDs.insert(option.id).inserted {
                merged.append(option)
            }
        }

        return merged
    }

    private func runtimeCandidates(for configuration: MlxRuntimeConfiguration) -> [RuntimeCandidate] {
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

        let userDir = Self.userRuntimeDirectoryURL(bundle: bundle)
        return [
            RuntimeCandidate(
                runtimeDirectoryURL: userDir,
                modelDirectoryURL: userDir
            )
        ]
    }

    private func availableModels(
        candidate: RuntimeCandidate,
        preferredModelIDs: [String]
    ) throws -> [MlxRuntimeModelOption] {
        let fileManager = FileManager.default
        var isDirectory = ObjCBool(false)

        guard
            fileManager.fileExists(atPath: candidate.runtimeDirectoryURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw MlxRuntimeLocatorError.runtimeDirectoryMissing(candidate.runtimeDirectoryURL.path)
        }

        let discoveredURLs = Self.discoverModelSnapshotURLs(in: candidate.modelDirectoryURL)
        guard !discoveredURLs.isEmpty else {
            throw MlxRuntimeLocatorError.modelMissing(candidate.modelDirectoryURL.path)
        }

        var optionsByID: [String: MlxRuntimeModelOption] = [:]
        for url in discoveredURLs {
            let modelID = modelID(for: url, relativeTo: candidate.modelDirectoryURL)
            guard optionsByID[modelID] == nil else { continue }
            optionsByID[modelID] = MlxRuntimeModelOption(id: modelID, url: url)
        }

        var ordered: [MlxRuntimeModelOption] = []
        var seenIDs = Set<String>()
        for preferredID in preferredModelIDs {
            guard let option = optionsByID[preferredID],
                  seenIDs.insert(preferredID).inserted
            else {
                continue
            }
            ordered.append(option)
        }

        let sortedDiscovered = optionsByID.values.sorted {
            $0.id.localizedCaseInsensitiveCompare($1.id) == .orderedAscending
        }
        for option in sortedDiscovered where seenIDs.insert(option.id).inserted {
            ordered.append(option)
        }

        guard !ordered.isEmpty else {
            throw MlxRuntimeLocatorError.modelMissing(candidate.modelDirectoryURL.path)
        }
        return ordered
    }

    /// Preserves common Hugging Face nesting (`publisher/repo`) as the model ID while still
    /// supporting a flat imported folder by using the final directory name.
    private func modelID(for modelURL: URL, relativeTo rootURL: URL) -> String {
        let rootPath = rootURL.standardizedFileURL.path
        let modelPath = modelURL.standardizedFileURL.path
        guard modelPath.hasPrefix(rootPath) else {
            return modelURL.lastPathComponent
        }

        let suffix = modelPath.dropFirst(rootPath.count).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return suffix.isEmpty ? modelURL.lastPathComponent : suffix
    }

    private func resolvedRuntime(
        from modelOption: MlxRuntimeModelOption,
        candidate: RuntimeCandidate
    ) -> ResolvedMlxRuntime {
        ResolvedMlxRuntime(
            runtimeDirectoryURL: candidate.runtimeDirectoryURL,
            modelDirectoryURL: modelOption.url,
            modelID: modelOption.id,
            modelDisplayName: modelOption.displayName
        )
    }
}
