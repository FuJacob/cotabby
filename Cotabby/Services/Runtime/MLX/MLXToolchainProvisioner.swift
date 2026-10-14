import Combine
import Foundation
import Logging

/// File overview:
/// The app's single source of truth for "is mlx-lm usable here, and where". It checks the known
/// install places, probes each candidate's version, and runs at most one install at a time, so
/// Settings and the server wiring observe one `state`. Owned by `CotabbyAppEnvironment` for the
/// app's lifetime. The server manager never installs anything; it only reads `state.toolchain`.
@MainActor
final class MLXToolchainProvisioner: ObservableObject {
    typealias VersionProbe = (URL) async -> String?

    @Published private(set) var state: MLXToolchainState = .checking

    private let paths: MLXPaths
    private let home: URL
    private let fileManager: FileManager
    private let probeVersion: VersionProbe
    private let installer: MLXToolchainInstalling
    /// The install that currently holds the single-flight slot, tagged with an identity. A finishing
    /// task clears the slot and publishes its state only while it is still this one, so a task that
    /// was superseded (cancelled by `remove()`) cannot overwrite a newer install's state.
    private var activeInstall: (id: UUID, task: Task<Void, Never>)?

    init(
        paths: MLXPaths,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default,
        probeVersion: @escaping VersionProbe,
        installer: MLXToolchainInstalling
    ) {
        self.paths = paths
        self.home = home
        self.fileManager = fileManager
        self.probeVersion = probeVersion
        self.installer = installer
    }

    static func live(paths: MLXPaths) -> MLXToolchainProvisioner {
        MLXToolchainProvisioner(
            paths: paths,
            probeVersion: { python in
                guard let result = try? await MLXProcessRunner.run(
                    executable: python,
                    arguments: ["-I", "-c", MLXToolchainRules.versionProbeScript],
                    environment: MLXToolchainRules.sanitizedEnvironment(ProcessInfo.processInfo.environment),
                    timeout: .seconds(5)
                ), result.status == 0 else { return nil }
                let version = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                return version.isEmpty ? nil : version
            },
            installer: MLXToolchainInstaller.live(paths: paths)
        )
    }

    /// Re-checks the install places unless an install is running (its own completion re-checks).
    /// `.checking` is published only when there is no toolchain yet. While MLX runs, a transient
    /// `.checking` would turn the server desire into "stopped" and kill the live server, so a
    /// rescan keeps the old state until the new result is known, and publishes it only if changed.
    func refresh() async {
        guard activeInstall == nil else { return }
        if state.toolchain == nil { state = .checking }
        let located = await locate()
        guard activeInstall == nil else { return }
        if located != state { state = located }
    }

    /// The rescan every "it may have changed" moment runs (pane opened, MLX selected, Retry): re-detect
    /// the toolchain, then re-list the model cache against the toolchain's supported architectures.
    func rescan(models downloader: MLXModelDownloader) async {
        await refresh()
        await downloader.refreshCache(toolchain: state.toolchain)
    }

    /// First candidate with a parseable launcher and a version at or above the minimum wins. A
    /// candidate whose Python does not answer (a half-written install) is skipped, never "ready".
    func locate() async -> MLXToolchainState {
        var tooOld: MLXToolchainState?
        for candidate in MLXToolchainRules.serverCandidates(paths: paths, home: home) {
            guard fileManager.isExecutableFile(atPath: candidate.path),
                  let python = interpreter(of: candidate),
                  let version = await probeVersion(python)
            else { continue }
            if MLXToolchainRules.isVersion(version, atLeast: MLXToolchainRules.minimumVersion) {
                return .ready(MLXToolchain(
                    serverExecutable: candidate,
                    pythonExecutable: python,
                    version: version,
                    isCotabbyInstall: candidate.standardizedFileURL == paths.ownServerExecutable.standardizedFileURL
                ))
            }
            tooOld = tooOld ?? .tooOld(version: version, path: candidate.path)
        }
        return tooOld ?? .notInstalled
    }

    /// Starts Cotabby's own install. A second call while one runs is ignored, so every caller
    /// shares the one install.
    func install() {
        guard activeInstall == nil else { return }
        CotabbyLogger.runtime.info("MLX install started")
        let id = UUID()
        // Annotated: the optional chain would otherwise infer Task<Void?, Never>.
        let task = Task<Void, Never> { [weak self] in
            await self?.runInstall(id: id)
        }
        activeInstall = (id: id, task: task)
    }

    func cancelInstall() {
        activeInstall?.task.cancel()
    }

    /// Cancels a running install and waits for it to finish before deleting anything, so no uv
    /// process can recreate files under the folder being removed. A second install cannot start
    /// meanwhile, because the slot stays taken until the cancelled task clears it. Then deletes
    /// Cotabby's own MLX folder (models in the Hugging Face cache are kept) and re-checks: an
    /// external install may still be usable.
    func remove() async {
        let running = activeInstall?.task
        running?.cancel()
        await running?.value
        // Tens of thousands of files: delete off the main actor, whose run loop serves the key taps.
        let root = paths.root
        let manager = fileManager
        await Task.detached(priority: .utility) {
            guard manager.fileExists(atPath: root.path) else { return }
            do { try manager.removeItem(at: root) } catch {
                CotabbyLogger.runtime.error("Removing MLX install failed: \(error.localizedDescription)")
            }
        }.value
        CotabbyLogger.runtime.info("Removed Cotabby's MLX install")
        let located = await locate()
        // An install started during the re-check owns the state now; do not overwrite it.
        guard activeInstall == nil else { return }
        state = located
    }

    /// One install run, publishing its outcome unless a newer install or a remove has taken over.
    /// The slot is cleared last, so a remove() that awaits this task resumes only after the state
    /// is final.
    private func runInstall(id: UUID) async {
        defer { if activeInstall?.id == id { activeInstall = nil } }
        do {
            try await installer.install { [weak self] phase in
                guard let self, self.activeInstall?.id == id else { return }
                self.state = .installing(phase)
            }
            let located = await locate()
            guard activeInstall?.id == id else { return }
            // Only Cotabby's own install counts. A working external install must not hide a broken own one.
            state = located.toolchain?.isCotabbyInstall == true
                ? located
                : .failed(reason: "MLX was installed but does not start.", logTail: [])
        } catch is CancellationError {
            let located = await locate()
            guard activeInstall?.id == id else { return }
            state = located
        } catch let error as MLXInstallError {
            CotabbyLogger.runtime.error("MLX install failed: \(error.localizedDescription)")
            guard activeInstall?.id == id else { return }
            state = .failed(reason: error.localizedDescription, logTail: error.logTail)
        } catch {
            CotabbyLogger.runtime.error("MLX install failed: \(error.localizedDescription)")
            guard activeInstall?.id == id else { return }
            state = .failed(reason: error.localizedDescription, logTail: [])
        }
    }

    /// Reads the launcher's first lines through any symlink (uv's bin entries are symlinks).
    private func interpreter(of script: URL) -> URL? {
        guard let handle = try? FileHandle(forReadingFrom: script.resolvingSymlinksInPath()) else { return nil }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 1024)) ?? Data()
        // Only the first two lines matter. Cutting after them keeps a multi-byte character split
        // by the 1 KB read from failing the decode of the whole head.
        let lineEnds = head.indices.filter { head[$0] == UInt8(ascii: "\n") }.prefix(2)
        let lines = head[..<(lineEnds.last.map { head.index(after: $0) } ?? head.endIndex)]
        return MLXToolchainRules.interpreter(fromScript: String(bytes: lines, encoding: .utf8) ?? "")
    }
}
