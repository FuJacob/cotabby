import Foundation

/// File overview:
/// Resolves which local model assets Cotabby should load from user-managed storage.
/// This keeps startup deterministic while ensuring large model files are never required in the app bundle.
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
/// GGUF models are single files in `LlamaRuntime/`. Despite the name, nothing is read from the
/// app bundle: `bundle` only supplies the app name that scopes the Application Support folder.
struct BundledRuntimeLocator {
    static let runtimeFolderName = "LlamaRuntime"

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
            (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Cotabby"
        return
            appSupportRoot
            .appendingPathComponent(appFolderName, isDirectory: true)
            .appendingPathComponent(Self.runtimeFolderName, isDirectory: true)
    }

    /// Toggle key for "also read models from LM Studio". The LM Studio library is an *additional*
    /// read-only source, never a replacement: Cotabby's own writable directory is always scanned and
    /// is always where downloads land. This is a Bool, not a stored path, because the only opt-in
    /// source we support is LM Studio's well-known location.
    static let lmStudioSourceEnabledKey = "lmStudioModelsEnabled"

    /// Whether the user opted to also scan their LM Studio library for GGUF models.
    static func isLMStudioSourceEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: lmStudioSourceEnabledKey)
    }

    /// The LM Studio models directory only when the user enabled the source *and* it exists on disk.
    /// A stale toggle (enabled, but LM Studio later uninstalled) resolves to nil so callers never
    /// scan a missing directory.
    static func enabledLMStudioModelsDirectory() -> URL? {
        guard isLMStudioSourceEnabled() else { return nil }
        return lmStudioModelsDirectoryIfAvailable()
    }

    /// The LM Studio models directory (`~/.lmstudio/models`) when it exists on disk, else nil.
    /// The filesystem probe lives here, not in a SwiftUI view body (which would re-stat on every
    /// render); callers compute it once, e.g. in `onAppear`, and cache the result.
    static func lmStudioModelsDirectoryIfAvailable() -> URL? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".lmstudio/models")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Ordered runtime search directories used to discover GGUF files.
    /// Cotabby's own directory is always first (it is authoritative and the download target); the LM
    /// Studio library, when enabled, is appended as an additive source.
    static func runtimeSearchDirectories(bundle: Bundle = .main) -> [URL] {
        var directories: [URL] = [userRuntimeDirectoryURL(bundle: bundle)]
        if let lmStudio = enabledLMStudioModelsDirectory() {
            directories.append(lmStudio)
        }
        return directories
    }

    /// Recursively discovers loadable GGUF model files under `directoryURL`.
    ///
    /// Recursion is required because third-party libraries (notably LM Studio) nest models as
    /// `<publisher>/<repo>/<file>.gguf` rather than as a flat folder, so a shallow listing of the
    /// root finds nothing and silently falls back to the default directory. Depth is bounded so a
    /// user pointing at a large tree cannot trigger an unbounded walk. `mmproj-*.gguf` files are
    /// vision/CLIP projector sidecars, not standalone language models, so they are skipped to keep
    /// them out of the model picker.
    static func discoverGGUFModelURLs(in directoryURL: URL, maxDepth: Int = 4) -> [URL] {
        let fileManager = FileManager.default
        // `FileManager.enumerator` does not descend into a root that is itself a symbolic link, so a
        // models folder linked to another location (an external drive, another app's folder) would
        // list nothing. Resolve the root first; links deeper inside stay unfollowed, which keeps
        // the bounded walk from escaping into arbitrary trees.
        guard let enumerator = fileManager.enumerator(
            at: directoryURL.resolvingSymlinksInPath(),
            includingPropertiesForKeys: [.isRegularFileKey],
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
            // A directory can carry a `.gguf` extension; only regular files are loadable models, and
            // passing a directory path to the runtime would surface a confusing error instead of a
            // clean "model missing".
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            guard url.pathExtension.caseInsensitiveCompare("gguf") == .orderedSame else { continue }
            // LM Studio always names projector sidecars `mmproj-…`; the trailing dash avoids
            // excluding a legitimately named model that merely starts with "mmproj".
            guard !url.lastPathComponent.lowercased().hasPrefix("mmproj-") else { continue }
            results.append(url)
        }
        return results
    }

    /// Resolves a specific model when selected explicitly, or the default preferred model order otherwise.
    func resolve(
        configuration: LlamaRuntimeConfiguration,
        selectedModelFilename: String?
    ) throws -> ResolvedLlamaRuntime {
        var lastError: Error?

        // Directories are tried in order, so a model missing from Cotabby's own folder can still
        // resolve from an additive source such as the LM Studio library.
        for directoryURL in searchDirectories(for: configuration) {
            do {
                let modelOptions = try availableModels(
                    in: directoryURL,
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
                    throw BundledRuntimeLocatorError.modelMissing(directoryURL.path)
                }

                return ResolvedLlamaRuntime(
                    modelFileURL: selectedOption.url,
                    modelDisplayName: selectedOption.displayName
                )
            } catch {
                lastError = error
            }
        }

        throw lastError
            ?? BundledRuntimeLocatorError.runtimeDirectoryMissing(
                "No runtime candidates were available.")
    }

    /// Lists all GGUF models in deterministic display order, merged across every search directory.
    ///
    /// Merging (rather than returning the first non-empty directory) is what makes the LM Studio
    /// source additive: the picker shows Cotabby's own models plus the LM Studio library together.
    /// Directory order is preserved (Cotabby's directory first) and duplicate filenames are deduped,
    /// keeping the first occurrence so the authoritative directory wins a name collision.
    func availableModels(configuration: LlamaRuntimeConfiguration) -> [RuntimeModelOption] {
        var merged: [RuntimeModelOption] = []
        var seenFilenames = Set<String>()

        for directoryURL in searchDirectories(for: configuration) {
            guard let modelOptions = try? availableModels(
                in: directoryURL,
                preferredModelNames: configuration.preferredModelNames
            ) else {
                continue
            }

            for option in modelOptions where seenFilenames.insert(option.filename).inserted {
                merged.append(option)
            }
        }

        return merged
    }

    /// The directories to scan. An explicit `runtimeDirectoryPath` replaces the default search set
    /// for tests or advanced local setups.
    private func searchDirectories(for configuration: LlamaRuntimeConfiguration) -> [URL] {
        if let runtimeDirectoryPath = configuration.runtimeDirectoryPath,
            !runtimeDirectoryPath.isEmpty {
            return [URL(fileURLWithPath: runtimeDirectoryPath, isDirectory: true)]
        }
        return Self.runtimeSearchDirectories(bundle: bundle)
    }

    /// Enumerates and orders all GGUF models in one directory.
    /// Preferred names come first; user-added GGUF files are appended alphabetically.
    private func availableModels(
        in directoryURL: URL,
        preferredModelNames: [String]
    ) throws -> [RuntimeModelOption] {
        var isDirectory = ObjCBool(false)
        guard
            FileManager.default.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw BundledRuntimeLocatorError.runtimeDirectoryMissing(directoryURL.path)
        }

        // Recursive discovery can surface the same filename from two nested repos. Dedupe by
        // filename keeping the first occurrence so a name collision resolves deterministically.
        var discoveredOptions: [RuntimeModelOption] = []
        var modelOptionsByFilename: [String: RuntimeModelOption] = [:]
        for modelURL in Self.discoverGGUFModelURLs(in: directoryURL) {
            let filename = modelURL.lastPathComponent
            guard modelOptionsByFilename[filename] == nil else { continue }
            let option = RuntimeModelOption(filename: filename, url: modelURL)
            modelOptionsByFilename[filename] = option
            discoveredOptions.append(option)
        }

        guard !discoveredOptions.isEmpty else {
            throw BundledRuntimeLocatorError.modelMissing(directoryURL.path)
        }

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
        let sortedDiscoveredModels = discoveredOptions.sorted { lhs, rhs in
            lhs.filename.localizedCaseInsensitiveCompare(rhs.filename) == .orderedAscending
        }
        for modelOption in sortedDiscoveredModels where seenFilenames.insert(modelOption.filename).inserted {
            orderedModels.append(modelOption)
        }

        return orderedModels
    }
}
