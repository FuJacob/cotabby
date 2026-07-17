import Foundation

/// Bundle-aware filesystem layout for terminal integration.
///
/// Cotabby and Cotabby Dev are intentionally allowed to run side-by-side. Giving each product its
/// own socket and installed-hook directory prevents one process from unlinking or updating the
/// other's endpoint. Hooks live in Application Support, while the socket uses the user's private
/// temporary directory so its path stays below Darwin's 104-byte `sockaddr_un.sun_path` limit.
nonisolated struct TerminalIntegrationPaths: Equatable, Sendable {
    let productIdentifier: String
    let rootDirectory: URL
    let socketURL: URL
    let hooksDirectory: URL

    init(
        bundleIdentifier: String,
        applicationSupportRoot: URL,
        socketRoot: URL = FileManager.default.temporaryDirectory
    ) {
        let safeIdentifier = Self.sanitizedPathComponent(bundleIdentifier)
        productIdentifier = safeIdentifier
        rootDirectory = applicationSupportRoot
            .appendingPathComponent("Cotabby", isDirectory: true)
            .appendingPathComponent("TerminalIntegration", isDirectory: true)
            .appendingPathComponent(safeIdentifier, isDirectory: true)
        socketURL = socketRoot
            .appendingPathComponent("cotabby-terminal", isDirectory: true)
            .appendingPathComponent(Self.socketFilename(for: safeIdentifier), isDirectory: false)
        hooksDirectory = rootDirectory.appendingPathComponent("shell-integration", isDirectory: true)
    }

    static func current(
        bundleIdentifier: String = Bundle.main.bundleIdentifier ?? "com.jacobfu.tabby",
        fileManager: FileManager = .default
    ) -> TerminalIntegrationPaths {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? fileManager.homeDirectoryForCurrentUser
        return TerminalIntegrationPaths(
            bundleIdentifier: bundleIdentifier,
            applicationSupportRoot: appSupport,
            socketRoot: fileManager.temporaryDirectory
        )
    }

    func hookURL(for shell: ShellType) -> URL {
        hooksDirectory.appendingPathComponent("cotabby.\(shell.rawValue)", isDirectory: false)
    }

    private static func sanitizedPathComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = raw.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "_" }
        let result = String(scalars)
        return result.isEmpty ? "cotabby" : String(result.prefix(120))
    }

    private static func socketFilename(for productIdentifier: String) -> String {
        switch productIdentifier {
        case "com.jacobfu.tabby": "cotabby.sock"
        case "com.jacobfu.tabby.dev": "cotabby-dev.sock"
        default: "\(String(productIdentifier.prefix(32))).sock"
        }
    }
}
