import XCTest
@testable import Cotabby

final class MLXToolchainRulesTests: XCTestCase {
    private let paths = MLXPaths(root: URL(fileURLWithPath: "/S/Cotabby/MLX"))
    private let home = URL(fileURLWithPath: "/Users/u")

    func test_candidatesAreOwnInstallThenUvThenHomebrew() {
        XCTAssertEqual(MLXToolchainRules.serverCandidates(paths: paths, home: home).map(\.path), [
            "/S/Cotabby/MLX/bin/mlx_lm.server",
            "/Users/u/.local/bin/mlx_lm.server",
            "/opt/homebrew/bin/mlx_lm.server"
        ])
    }

    func test_interpreterFromPlainShebang() {
        XCTAssertEqual(
            MLXToolchainRules.interpreter(fromScript: "#!/Users/u/.local/share/uv/tools/mlx-lm/bin/python\nimport x")?.path,
            "/Users/u/.local/share/uv/tools/mlx-lm/bin/python"
        )
    }

    /// uv and pip write a /bin/sh trampoline when the Python path has a space, which Cotabby's own
    /// install always does ("Application Support").
    func test_interpreterFromShellTrampoline() {
        let script = "#!/bin/sh\n'''exec' '/S/Cotabby Dev/MLX/tools/mlx-lm/bin/python' \"$0\" \"$@\"\n' '''\nimport sys\n"
        XCTAssertEqual(MLXToolchainRules.interpreter(fromScript: script)?.path,
                       "/S/Cotabby Dev/MLX/tools/mlx-lm/bin/python")
    }

    func test_interpreterRejectsEnvAndGarbage() {
        XCTAssertNil(MLXToolchainRules.interpreter(fromScript: "#!/usr/bin/env python3\n"))
        XCTAssertNil(MLXToolchainRules.interpreter(fromScript: "print('hi')"))
        XCTAssertNil(MLXToolchainRules.interpreter(fromScript: "#!/bin/sh\necho hi\n"))
        XCTAssertNil(MLXToolchainRules.interpreter(fromScript: ""))
    }

    func test_versionComparison() {
        XCTAssertTrue(MLXToolchainRules.isVersion("0.32.0", atLeast: "0.32.0"))
        XCTAssertTrue(MLXToolchainRules.isVersion("0.32.1", atLeast: "0.32.0"))
        XCTAssertTrue(MLXToolchainRules.isVersion("0.40", atLeast: "0.32.0"))
        XCTAssertTrue(MLXToolchainRules.isVersion("1.0.0rc1", atLeast: "0.32.0"))
        XCTAssertFalse(MLXToolchainRules.isVersion("0.31.9", atLeast: "0.32.0"))
        XCTAssertFalse(MLXToolchainRules.isVersion("0.9.0", atLeast: "0.32.0"))
        XCTAssertFalse(MLXToolchainRules.isVersion("garbage", atLeast: "0.32.0"))
    }

    func test_serverCommandLineIsExact() {
        XCTAssertEqual(
            MLXToolchainRules.serverArguments(modelID: "mlx-community/gemma-4-e4b-5bit", port: 50123, promptCacheBytes: 1 << 30),
            ["--model", "mlx-community/gemma-4-e4b-5bit", "--host", "127.0.0.1", "--port", "50123",
             "--prompt-cache-size", "2", "--prompt-cache-bytes", "1073741824", "--log-level", "WARNING"]
        )
    }

    func test_serverRunsThroughTheFullCacheBootstrapWhenThePythonIsKnown() {
        let script = URL(fileURLWithPath: "/S/MLX/bin/mlx_lm.server")
        let python = URL(fileURLWithPath: "/S/MLX/tools/mlx-lm/bin/python")
        let command = MLXToolchainRules.serverCommand(serverScript: script, interpreter: python, arguments: ["--port", "1"])
        XCTAssertEqual(command.executable, python)
        XCTAssertEqual(command.arguments,
                       ["-I", "-c", MLXToolchainRules.fullCacheServerScript, script.path, "--port", "1"])
        // The launcher path stays in argv, so a leftover server is still recognized as ours.
        XCTAssertTrue(MLXToolchainRules.isOurServer(arguments:
            [python.path] + command.arguments + ["--host", "127.0.0.1"]))

        let fallback = MLXToolchainRules.serverCommand(serverScript: script, interpreter: nil, arguments: ["--port", "1"])
        XCTAssertEqual(fallback.executable, script)
        XCTAssertEqual(fallback.arguments, ["--port", "1"])
    }

    func test_environmentsDropPythonOverridesAndPinOfflineServing() {
        let base = ["HOME": "/Users/u", "PATH": "/x", "PYTHONPATH": "/evil", "PYTHONHOME": "/evil",
                    "VIRTUAL_ENV": "/venv", "CONDA_PREFIX": "/conda", "UV_INDEX_URL": "https://mirror",
                    "HF_HOME": "/hf"]
        let server = MLXToolchainRules.serverEnvironment(base: base)
        XCTAssertEqual(server["HF_HUB_OFFLINE"], "1")
        XCTAssertEqual(server["HF_HOME"], "/hf", "a user-set cache location is honored")
        XCTAssertNil(server["PYTHONPATH"]); XCTAssertNil(server["PYTHONHOME"])
        XCTAssertNil(server["VIRTUAL_ENV"]); XCTAssertNil(server["CONDA_PREFIX"]); XCTAssertNil(server["UV_INDEX_URL"])
        XCTAssertEqual(server["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")

        let download = MLXToolchainRules.downloadEnvironment(base: base)
        XCTAssertNil(download["HF_HUB_OFFLINE"], "downloads must reach the network")
        XCTAssertEqual(download["HF_HUB_DISABLE_TELEMETRY"], "1")
        XCTAssertEqual(download["HF_HUB_DISABLE_PROGRESS_BARS"], "1")

        let install = MLXToolchainRules.installEnvironment(paths: paths, base: base)
        XCTAssertEqual(install["UV_TOOL_DIR"], "/S/Cotabby/MLX/tools")
        XCTAssertEqual(install["UV_TOOL_BIN_DIR"], "/S/Cotabby/MLX/bin")
        XCTAssertEqual(install["UV_PYTHON_INSTALL_DIR"], "/S/Cotabby/MLX/python")
        XCTAssertEqual(install["UV_CACHE_DIR"], "/S/Cotabby/MLX/cache")
        XCTAssertEqual(install["UV_NO_CONFIG"], "1")
        XCTAssertEqual(install["UV_PYTHON_PREFERENCE"], "only-managed")
        XCTAssertEqual(install["UV_COMPILE_BYTECODE"], "1")
        XCTAssertNil(install["UV_INDEX_URL"], "a user's uv mirror setting must not redirect Cotabby's install")
        XCTAssertEqual(MLXToolchainRules.installArguments(), ["tool", "install", "mlx-lm==0.32.0", "--python", "3.12"])
    }

    func test_procArgsParsing() {
        var bytes: [UInt8] = []
        withUnsafeBytes(of: Int32(3).littleEndian) { bytes += $0 }
        bytes += Array("/usr/bin/python3".utf8) + [0, 0, 0, 0]
        for arg in ["python3", "/S/MLX/bin/mlx_lm.server", "--port"] { bytes += Array(arg.utf8) + [0] }
        bytes += Array("ENV=1".utf8) + [0]
        XCTAssertEqual(MLXToolchainRules.parseProcArgs(bytes), ["python3", "/S/MLX/bin/mlx_lm.server", "--port"])
        XCTAssertNil(MLXToolchainRules.parseProcArgs([1, 0]))
    }

    func test_isOurServerNeedsTheScriptAndLoopbackHost() {
        XCTAssertTrue(MLXToolchainRules.isOurServer(arguments:
            ["/p/python", "/S/MLX/bin/mlx_lm.server", "--model", "a/b", "--host", "127.0.0.1", "--port", "1"]))
        XCTAssertFalse(MLXToolchainRules.isOurServer(arguments:
            ["/p/python", "/S/MLX/bin/mlx_lm.server", "--host", "0.0.0.0"]))
        XCTAssertFalse(MLXToolchainRules.isOurServer(arguments: ["/usr/bin/vim", "--host", "127.0.0.1"]))
    }
}
