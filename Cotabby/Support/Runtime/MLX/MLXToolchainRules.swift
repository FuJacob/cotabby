import Foundation

/// File overview:
/// The pure rules behind finding, installing and running mlx-lm: where an install may live, how
/// to find the Python a launcher script runs, which versions are acceptable, and the exact command
/// lines and environments Cotabby uses. Services (`MLXToolchainProvisioner`, `MLXServerManager`,
/// `MLXModelDownloader`) call these instead of assembling strings themselves, so every flag and
/// environment variable is pinned by a unit test.
nonisolated enum MLXToolchainRules {
    static let minimumVersion = "0.32.0"
    static let pinnedVersion = "0.32.0"

    /// Prints the installed mlx-lm version from package metadata. Importing `mlx_lm` itself loads
    /// MLX and its heavy dependencies (seconds), which made the probe slow enough to re-run only
    /// at launch; reading `importlib.metadata` is milliseconds. Run with `python -I` so user
    /// site-packages and PYTHON* variables cannot change what is found.
    static let versionProbeScript =
        "import sys, importlib.metadata as m; sys.stdout.write(m.version('mlx-lm'))"

    /// Prints a JSON list of every `model_type` the installed mlx-lm can load: its model modules
    /// plus the remapped aliases (for example `mistral` loads through `llama`).
    static let supportedModelTypesScript = """
    import json, pkgutil, sys
    import mlx_lm.models as models
    from mlx_lm.utils import MODEL_REMAPPING
    names = [name for _, name, _ in pkgutil.iter_modules(models.__path__)]
    sys.stdout.write(json.dumps(sorted(set(names) | set(MODEL_REMAPPING))))
    """

    /// Downloads one repo into the Hugging Face cache. The repo id arrives as `sys.argv[1]`, never
    /// interpolated into the code string.
    static let downloadScript =
        "import sys; from huggingface_hub import snapshot_download; snapshot_download(sys.argv[1])"

    /// GUI apps do not inherit the shell's PATH, so the usual install places are checked by path:
    /// Cotabby's own install, uv's default tool bin, Homebrew.
    static func serverCandidates(paths: MLXPaths, home: URL) -> [URL] {
        [
            paths.ownServerExecutable,
            home.appendingPathComponent(".local/bin/mlx_lm.server"),
            URL(fileURLWithPath: "/opt/homebrew/bin/mlx_lm.server")
        ]
    }

    /// The Python a console-script launcher runs. Two shapes exist:
    /// - `#!/abs/path/python`
    /// - a `/bin/sh` trampoline (`'''exec' '/path with space/python' "$0" "$@"`) that uv and pip
    ///   write when the path has a space.
    /// `#!/usr/bin/env python3` is rejected: a GUI app has no reliable PATH to resolve it with.
    static func interpreter(fromScript text: String) -> URL? {
        let lines = text.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first, first.hasPrefix("#!") else { return nil }
        let shebang = first.dropFirst(2).trimmingCharacters(in: .whitespaces)
        if shebang == "/bin/sh" {
            let prefix = "'''exec' '"
            guard lines.count > 1, lines[1].hasPrefix(prefix) else { return nil }
            let rest = lines[1].dropFirst(prefix.count)
            guard let end = rest.firstIndex(of: "'"), end > rest.startIndex else { return nil }
            return URL(fileURLWithPath: String(rest[..<end]))
        }
        guard shebang.hasPrefix("/"), !shebang.contains(" ") else { return nil }
        return URL(fileURLWithPath: shebang)
    }

    /// Numeric comparison of dotted versions; a component's trailing letters ("0rc1") are ignored.
    static func isVersion(_ version: String, atLeast minimum: String) -> Bool {
        guard let lhs = numericComponents(version), let rhs = numericComponents(minimum) else { return false }
        for index in 0..<max(lhs.count, rhs.count) {
            let left = index < lhs.count ? lhs[index] : 0
            let right = index < rhs.count ? rhs[index] : 0
            if left != right { return left > right }
        }
        return true
    }

    /// The environment every MLX helper starts from: the app's environment without anything that
    /// could make Python or uv load other code (PYTHONPATH, PYTHONHOME, an active virtualenv or
    /// conda env, the user's own UV_* settings), with a fixed system PATH.
    static func sanitizedEnvironment(_ base: [String: String]) -> [String: String] {
        var environment = base.filter { key, _ in
            !key.hasPrefix("PYTHON") && !key.hasPrefix("UV_") && !key.hasPrefix("CONDA_")
                && key != "VIRTUAL_ENV" && key != "PIP_INDEX_URL" && key != "PIP_EXTRA_INDEX_URL"
        }
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        return environment
    }

    static func installArguments() -> [String] {
        ["tool", "install", "mlx-lm==\(pinnedVersion)", "--python", "3.12"]
    }

    /// Everything uv writes stays under Cotabby's MLX folder; uv downloads its own Python and
    /// never touches or uses the system one.
    static func installEnvironment(paths: MLXPaths, base: [String: String]) -> [String: String] {
        var environment = sanitizedEnvironment(base)
        environment["UV_TOOL_DIR"] = paths.toolsDirectory.path
        environment["UV_TOOL_BIN_DIR"] = paths.binDirectory.path
        environment["UV_PYTHON_INSTALL_DIR"] = paths.pythonDirectory.path
        environment["UV_CACHE_DIR"] = paths.cacheDirectory.path
        environment["UV_NO_CONFIG"] = "1"
        environment["UV_PYTHON_PREFERENCE"] = "only-managed"
        // Compile bytecode at install time so the first server start does not pay for it.
        environment["UV_COMPILE_BYTECODE"] = "1"
        return environment
    }

    /// The server binds loopback only, keeps two prompt caches (the current field and the one
    /// before), and bounds their memory.
    static func serverArguments(modelID: String, port: Int, promptCacheBytes: Int) -> [String] {
        [
            "--model", modelID,
            "--host", "127.0.0.1",
            "--port", String(port),
            "--prompt-cache-size", "2",
            "--prompt-cache-bytes", String(promptCacheBytes),
            "--log-level", "WARNING"
        ]
    }

    /// `HF_HUB_OFFLINE=1`: the server never downloads on its own; downloads happen only when the
    /// user presses Download.
    static func serverEnvironment(base: [String: String]) -> [String: String] {
        var environment = sanitizedEnvironment(base)
        environment["HF_HUB_OFFLINE"] = "1"
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        return environment
    }

    static func downloadEnvironment(base: [String: String]) -> [String: String] {
        var environment = sanitizedEnvironment(base)
        environment.removeValue(forKey: "HF_HUB_OFFLINE")
        environment["HF_HUB_DISABLE_TELEMETRY"] = "1"
        // Progress bars would flood the captured stderr with carriage-return redraws.
        environment["HF_HUB_DISABLE_PROGRESS_BARS"] = "1"
        return environment
    }

    /// Parses a `KERN_PROCARGS2` buffer: argc (Int32), the executable path, NUL padding, then argc
    /// NUL-terminated arguments (the environment follows and is ignored).
    static func parseProcArgs(_ bytes: [UInt8]) -> [String]? {
        guard bytes.count > MemoryLayout<Int32>.size else { return nil }
        let argc = Int(bytes.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard argc > 0 else { return nil }
        var index = MemoryLayout<Int32>.size
        while index < bytes.count, bytes[index] != 0 { index += 1 }
        while index < bytes.count, bytes[index] == 0 { index += 1 }
        var arguments: [String] = []
        while arguments.count < argc, index < bytes.count {
            let start = index
            while index < bytes.count, bytes[index] != 0 { index += 1 }
            arguments.append(String(decoding: bytes[start..<index], as: UTF8.self))
            index += 1
        }
        return arguments.count == argc ? arguments : nil
    }

    /// A process is Cotabby's MLX server only when it runs the `mlx_lm.server` script bound to
    /// loopback, the way Cotabby launches it. Checked before signalling a pid read from the pid
    /// file, because pids are reused.
    static func isOurServer(arguments: [String]) -> Bool {
        let runsServer = arguments.contains { ($0 as NSString).lastPathComponent == "mlx_lm.server" }
        let loopback = zip(arguments, arguments.dropFirst()).contains { $0 == "--host" && $1 == "127.0.0.1" }
        return runsServer && loopback
    }

    private static func numericComponents(_ version: String) -> [Int]? {
        let parts = version.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        var numbers: [Int] = []
        for part in parts {
            let digits = part.prefix { $0.isNumber }
            guard let value = Int(digits) else { break }
            numbers.append(value)
            if digits.count != part.count { break }
        }
        return numbers.isEmpty ? nil : numbers
    }
}
