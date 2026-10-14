import CryptoKit
import Foundation
import Logging
import Security

/// File overview:
/// Installs mlx-lm for Cotabby in two verified steps:
/// 1. Download Astral's `uv`, pinned by version and SHA-256, and check its code signature before
///    it ever runs.
/// 2. Have uv install the pinned mlx-lm, with its own Python, entirely under Cotabby's MLX folder.
/// Nothing touches the system Python or the user's shell setup. The network, process and
/// signature steps are injected closures, so tests run the whole sequence without downloading or
/// executing anything.

nonisolated enum MLXInstallError: LocalizedError, Equatable {
    case downloadFailed(String)
    case checksumMismatch
    case extractFailed
    case signatureInvalid
    case installFailed(tail: [String])
    case timedOut

    var errorDescription: String? {
        switch self {
        case .downloadFailed(let message): return "Could not download the MLX installer: \(message)"
        case .checksumMismatch: return "The downloaded installer did not match its published checksum, so it was not used."
        case .extractFailed: return "Could not unpack the MLX installer."
        case .signatureInvalid: return "The installer is not signed by its publisher (Astral), so it was not run."
        case .installFailed: return "Installing MLX failed."
        case .timedOut: return "Installing MLX took longer than 10 minutes and was stopped."
        }
    }

    var logTail: [String] {
        if case .installFailed(let tail) = self { return tail }
        return []
    }
}

/// The seam `MLXToolchainProvisioner` installs through; tests substitute a fake.
protocol MLXToolchainInstalling {
    func install(phase: @escaping @MainActor (MLXInstallPhase) -> Void) async throws
}

/// One install run. A value type with injected effects; the provisioner owns one for the app's
/// lifetime and calls it at most once at a time. It is `nonisolated` so the hashing, file writes
/// and signature check run off the main actor; only the `phase` callback hops back to it.
nonisolated struct MLXToolchainInstaller: MLXToolchainInstalling {
    typealias Download = (URL) async throws -> Data
    typealias RunProcess = (URL, [String], [String: String], Duration) async throws -> MLXProcessResult
    typealias VerifySignature = (URL) -> Bool

    static let uvArchiveURL = URL(string: "https://github.com/astral-sh/uv/releases/download/0.12.18/uv-aarch64-apple-darwin.tar.gz")!
    static let uvArchiveSHA256 = "cf40e0c6a202190ccd9e0406dcfdd5b2d6668a9a5c779b17948963df32aafe5b"
    /// Astral Software Inc.'s Apple Developer team.
    static let astralTeamID = "2DC432GLL2"
    static let totalTimeout: Duration = .seconds(600)

    let paths: MLXPaths
    let expectedSHA256: String
    let download: Download
    let runProcess: RunProcess
    let verifySignature: VerifySignature

    init(
        paths: MLXPaths,
        expectedSHA256: String = MLXToolchainInstaller.uvArchiveSHA256,
        download: @escaping Download,
        runProcess: @escaping RunProcess,
        verifySignature: @escaping VerifySignature
    ) {
        self.paths = paths
        self.expectedSHA256 = expectedSHA256
        self.download = download
        self.runProcess = runProcess
        self.verifySignature = verifySignature
    }

    static func live(paths: MLXPaths) -> MLXToolchainInstaller {
        MLXToolchainInstaller(
            paths: paths,
            download: { url in
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForResource = 180
                let session = URLSession(configuration: configuration)
                defer { session.finishTasksAndInvalidate() }
                let (data, response) = try await session.data(from: url)
                guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                    throw MLXInstallError.downloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
                }
                return data
            },
            runProcess: { executable, arguments, environment, timeout in
                try await MLXProcessRunner.run(
                    executable: executable, arguments: arguments, environment: environment, timeout: timeout)
            },
            verifySignature: Self.isSignedByAstral
        )
    }

    func install(phase: @escaping @MainActor (MLXInstallPhase) -> Void) async throws {
        let deadline = ContinuousClock.now + Self.totalTimeout
        let fileManager = FileManager.default

        await phase(.downloadingUV)
        let archive: Data
        do {
            archive = try await download(Self.uvArchiveURL)
        } catch let error as MLXInstallError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error where Task.isCancelled || (error as? URLError)?.code == .cancelled {
            // URLSession reports a cancelled task as URLError(.cancelled), not CancellationError.
            // Map it, so cancelInstall() reverts to the real state instead of showing a failure.
            throw CancellationError()
        } catch {
            throw MLXInstallError.downloadFailed(error.localizedDescription)
        }

        await phase(.verifyingUV)
        let digest = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        guard digest == expectedSHA256 else { throw MLXInstallError.checksumMismatch }
        try? fileManager.removeItem(at: paths.uvDirectory)
        try fileManager.createDirectory(at: paths.uvDirectory, withIntermediateDirectories: true)
        let archiveURL = paths.uvDirectory.appendingPathComponent("uv.tar.gz")
        try archive.write(to: archiveURL)
        let extract = try await runProcess(
            URL(fileURLWithPath: "/usr/bin/tar"),
            ["-xzf", archiveURL.path, "-C", paths.uvDirectory.path],
            MLXToolchainRules.sanitizedEnvironment(ProcessInfo.processInfo.environment),
            Self.remaining(until: deadline)
        )
        guard extract.status == 0 else { throw MLXInstallError.extractFailed }
        guard verifySignature(paths.uvExecutable) else { throw MLXInstallError.signatureInvalid }

        await phase(.installingMLX)
        let result: MLXProcessResult
        do {
            result = try await runProcess(
                paths.uvExecutable,
                MLXToolchainRules.installArguments(),
                MLXToolchainRules.installEnvironment(paths: paths, base: ProcessInfo.processInfo.environment),
                Self.remaining(until: deadline)
            )
        } catch MLXProcessRunnerError.timedOut {
            throw MLXInstallError.timedOut
        }
        guard result.status == 0 else { throw MLXInstallError.installFailed(tail: result.stderrTail) }
        CotabbyLogger.runtime.info("Installed mlx-lm \(MLXToolchainRules.pinnedVersion) with uv")
    }

    private static func remaining(until deadline: ContinuousClock.Instant) throws -> Duration {
        let left = deadline - ContinuousClock.now
        guard left > .zero else { throw MLXInstallError.timedOut }
        return left
    }

    /// Full signature check, including the executable's own pages (the binary is small), against
    /// a requirement naming Astral's team: an Apple-issued Developer ID certificate whose
    /// organizational unit is `2DC432GLL2`.
    nonisolated static func isSignedByAstral(_ executable: URL) -> Bool {
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(executable as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode
        else { return false }
        var requirement: SecRequirement?
        let text = "anchor apple generic and certificate leaf[subject.OU] = \"\(astralTeamID)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement
        else { return false }
        return SecStaticCodeCheckValidity(staticCode, SecCSFlags(rawValue: kSecCSCheckAllArchitectures), requirement)
            == errSecSuccess
    }
}
