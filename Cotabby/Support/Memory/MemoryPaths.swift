import Foundation

/// File overview:
/// Where conversation memory's files live, as pure path arithmetic.
///
/// Everything sits under `Application Support/<app name>/Memory/`, named per app (like the llama
/// runtime and typing history), so the dev build and the released app never share a store:
///
/// ```
/// Memory/
///   data/          config.json and messages.sqlite (the encrypted store, vectors included)  (0700)
///   Models/        the embedding model (kept apart from completion models, so it is never
///                  offered as one)
/// ```
nonisolated struct MemoryPaths: Equatable, Sendable {
    let root: URL

    init(root: URL) {
        self.root = root
    }

    /// The paths for the running app, keyed by its bundle name.
    static func standard(bundle: Bundle = .main) -> MemoryPaths {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let appName = (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String) ?? "Cotabby"
        return MemoryPaths(root: support.appendingPathComponent(appName).appendingPathComponent("Memory"))
    }

    var dataDirectory: URL { root.appendingPathComponent("data", isDirectory: true) }
    var modelsDirectory: URL { root.appendingPathComponent("Models", isDirectory: true) }
}
