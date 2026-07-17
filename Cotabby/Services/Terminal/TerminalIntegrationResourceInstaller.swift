import Darwin
import Foundation

/// Copies code-signed shell hook resources to a stable per-product user directory.
///
/// The app bundle is sealed and may move between updates or development builds, so shell startup
/// files should never source a mutable file inside `Contents/Resources`. Installation is an atomic
/// byte-for-byte copy; this type does not edit the user's shell configuration.
nonisolated struct TerminalIntegrationResourceInstaller {
    enum InstallError: LocalizedError {
        case bundledHooksMissing(URL)
        case bundledHookMissing(String)

        var errorDescription: String? {
            switch self {
            case let .bundledHooksMissing(url):
                "Bundled shell integration directory is missing at \(url.path)."
            case let .bundledHookMissing(name):
                "Bundled shell integration hook \(name) is missing."
            }
        }
    }

    let paths: TerminalIntegrationPaths
    let bundledHooksDirectory: URL
    let fileManager: FileManager

    init(
        paths: TerminalIntegrationPaths,
        bundledHooksDirectory: URL? = Bundle.main.resourceURL?
            .appendingPathComponent("shell-integration", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.bundledHooksDirectory = bundledHooksDirectory
            ?? URL(fileURLWithPath: "/nonexistent/cotabby-shell-integration")
        self.fileManager = fileManager
    }

    func install() throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: bundledHooksDirectory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw InstallError.bundledHooksMissing(bundledHooksDirectory)
        }

        try fileManager.createDirectory(
            at: paths.hooksDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        guard chmod(paths.rootDirectory.path, 0o700) == 0,
              chmod(paths.hooksDirectory.path, 0o700) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EACCES)
        }

        for shell in ShellType.allCasesForInstallation {
            let name = "cotabby.\(shell.rawValue)"
            let source = bundledHooksDirectory.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: source.path) else {
                throw InstallError.bundledHookMissing(name)
            }
            let data = try Data(contentsOf: source)
            let destination = paths.hookURL(for: shell)
            try data.write(to: destination, options: .atomic)
            guard chmod(destination.path, 0o600) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EACCES)
            }
        }
    }
}

private nonisolated extension ShellType {
    static let allCasesForInstallation: [ShellType] = [.zsh, .bash, .fish]
}
