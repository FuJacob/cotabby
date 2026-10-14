import XCTest
@testable import Cotabby

/// File overview:
/// Tests for the MLX value types in `Models/Runtime/MLXModels.swift`: repo id validation (the
/// security boundary before a model id reaches a command line), the curated catalog merge, the
/// server state's user-facing messages, and the install paths. All of them are pure, so no test
/// here touches the network, the file system outside a fixed URL, or a process.

final class MLXRepoIDTests: XCTestCase {
    func test_acceptsOwnerSlashNameAndTrims() {
        XCTAssertEqual(MLXRepoID("  mlx-community/gemma-4-e4b-5bit \n")?.value, "mlx-community/gemma-4-e4b-5bit")
        XCTAssertEqual(MLXRepoID("Org_1/Model.v2")?.value, "Org_1/Model.v2")
    }

    func test_reducesAPastedHuggingFaceURL() {
        XCTAssertEqual(MLXRepoID("https://huggingface.co/mlx-community/gemma-4-e4b-5bit")?.value,
                       "mlx-community/gemma-4-e4b-5bit")
        XCTAssertEqual(MLXRepoID("https://huggingface.co/mlx-community/gemma-4-e4b-5bit/tree/main")?.value,
                       "mlx-community/gemma-4-e4b-5bit")
        XCTAssertNil(MLXRepoID("https://example.com/mlx-community/x"))
    }

    func test_rejectsAnythingElse() {
        for raw in ["", "gemma", "org/name/extra", "../../etc", "org/..", "org/a b", "org/-x",
                    "org/.hidden", "org/a--b", "org/a;rm", "/name", "org/"] {
            XCTAssertNil(MLXRepoID(raw), raw)
        }
    }

    func test_cacheFolderNameRoundTrips() {
        let id = MLXRepoID("mlx-community/gemma-4-e4b-5bit")!
        XCTAssertEqual(id.cacheFolderName, "models--mlx-community--gemma-4-e4b-5bit")
        XCTAssertEqual(MLXRepoID(cacheFolderName: "models--mlx-community--gemma-4-e4b-5bit"), id)
        XCTAssertNil(MLXRepoID(cacheFolderName: "datasets--a--b"))
        XCTAssertNil(MLXRepoID(cacheFolderName: "models--onlyone"))
    }
}

final class MLXModelCatalogTests: XCTestCase {
    private func cached(_ id: String, size: Int64 = 1, instruct: Bool = false) -> MLXCachedModel {
        MLXCachedModel(repoID: MLXRepoID(id)!, snapshotURL: URL(fileURLWithPath: "/tmp/\(id)"),
                       sizeBytes: size, modelType: "gemma4", isInstruct: instruct)
    }

    func test_curatedComeFirstThenOtherCachedModelsSorted() {
        let options = MLXModelCatalog.options(cached: [
            cached("zeta/z"), cached("mlx-community/gemma-4-e2b-6bit", size: 42), cached("alpha/a", instruct: true)
        ])
        XCTAssertEqual(options.map(\.id), [
            "mlx-community/gemma-4-e4b-5bit", "mlx-community/gemma-4-e2b-6bit", "alpha/a", "zeta/z"
        ])
        XCTAssertFalse(options[0].isDownloaded)
        XCTAssertTrue(options[0].isRecommended)
        XCTAssertTrue(options[1].isDownloaded)
        XCTAssertEqual(options[1].sizeBytes, 42, "a downloaded model shows its real size")
        XCTAssertEqual(options[2].note, MLXModelCatalog.instructNote)
    }

    func test_defaultSelectionPrefersADownloadedCuratedModel() {
        XCTAssertNil(MLXModelCatalog.defaultSelection(cached: []))
        XCTAssertEqual(MLXModelCatalog.defaultSelection(cached: [cached("alpha/a")])?.value, "alpha/a")
        XCTAssertEqual(
            MLXModelCatalog.defaultSelection(cached: [cached("alpha/a"), cached("mlx-community/gemma-4-e2b-6bit")])?.value,
            "mlx-community/gemma-4-e2b-6bit"
        )
    }
}

final class MLXStateTests: XCTestCase {
    func test_serverProblemOnlyWhenTheUserMustAct() {
        XCTAssertNil(MLXServerState.idle.problem)
        XCTAssertNil(MLXServerState.starting(modelID: "a/b").problem)
        XCTAssertNil(MLXServerState.ready(port: 1, modelID: "a/b").problem)
        XCTAssertNotNil(MLXServerState.unavailable(.notInstalled).problem)
        XCTAssertNotNil(MLXServerState.failed(reason: "boom", logTail: []).problem)
    }

    func test_notReadyMessageNamesTheReason() {
        XCTAssertEqual(MLXServerState.starting(modelID: "a/b").notReadyMessage, "MLX is loading a/b…")
        XCTAssertEqual(MLXServerState.unavailable(.noModel).notReadyMessage, "Choose an MLX model in Settings → Engine & Model.")
    }

    func test_pathsLiveUnderTheAppsSupportFolder() {
        let paths = MLXPaths(root: URL(fileURLWithPath: "/S/Cotabby Dev/MLX"))
        XCTAssertEqual(paths.ownServerExecutable.path, "/S/Cotabby Dev/MLX/bin/mlx_lm.server")
        XCTAssertEqual(paths.uvExecutable.path, "/S/Cotabby Dev/MLX/uv/uv-aarch64-apple-darwin/uv")
        XCTAssertEqual(paths.serverPIDFile.path, "/S/Cotabby Dev/MLX/server.pid")
    }
}
