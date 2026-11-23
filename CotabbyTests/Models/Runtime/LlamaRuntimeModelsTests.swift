import AppKit
import XCTest
@testable import Cotabby

/// Runtime catalog, download-state, and generation-option values surfaced by onboarding, the menu,
/// and the llama engine.
final class LlamaRuntimeModelsTests: XCTestCase {
    func test_modelDownloadStateProgressFractionIsClamped() {
        XCTAssertEqual(ModelDownloadState.downloading(progress: -0.5).progressFraction, 0)
        XCTAssertEqual(ModelDownloadState.downloading(progress: 0.42).progressFraction, 0.42)
        XCTAssertEqual(ModelDownloadState.downloading(progress: 1.5).progressFraction, 1)
        XCTAssertEqual(ModelDownloadState.paused(progress: 0.75).progressFraction, 0.75)
        XCTAssertNil(ModelDownloadState.downloading(progress: nil).progressFraction)
        XCTAssertNil(ModelDownloadState.paused(progress: nil).progressFraction)
        XCTAssertNil(ModelDownloadState.idle.progressFraction)
    }

    func test_modelDownloadStateStatusTextUsesRoundedPercent() {
        XCTAssertEqual(ModelDownloadState.idle.statusText, "Not installed")
        XCTAssertEqual(ModelDownloadState.downloading(progress: nil).statusText, "Downloading")
        XCTAssertEqual(ModelDownloadState.downloading(progress: 0.426).statusText, "Downloading 43%")
        XCTAssertEqual(
            ModelDownloadState.downloading(progress: 0.426, speedFormatted: "42.5 MB/s", etaFormatted: "1m 15s").statusText,
            "Downloading 43% (42.5 MB/s · ETA 1m 15s)"
        )
        XCTAssertEqual(ModelDownloadState.paused(progress: 0.50).statusText, "Paused (50%)")
        XCTAssertEqual(ModelDownloadState.paused(progress: nil).statusText, "Paused")
        XCTAssertEqual(ModelDownloadState.downloaded.statusText, "Installed")
        XCTAssertEqual(ModelDownloadState.failed("Network failed").statusText, "Network failed")
    }

    func test_runtimeModelCatalogMapsKnownNamesAndLeavesCustomNamesAlone() {
        let expectations: [(filename: String, displayName: String)] = [
            ("Qwen3.5-0.8B-Base.i1-Q6_K.gguf", "tabby-2-nano"),
            ("Qwen3.5-2B-Base.i1-Q4_K_M.gguf", "tabby-2-mini"),
            ("gemma-4-E2B.i1-Q6_K.gguf", "tabby-2-base"),
            ("gemma-4-E4B.i1-Q4_K_M.gguf", "tabby-2-pro"),
            // Retired models fall back to their raw filename like any unknown local GGUF. The 4B Qwen
            // base was dropped when the catalog moved to the nano/mini/base/pro four-tier lineup.
            ("Qwen3.5-4B-Base.i1-Q4_K_M.gguf", "Qwen3.5-4B-Base.i1-Q4_K_M.gguf"),
            ("Qwen3.5-0.8B-Q4_K_M.gguf", "Qwen3.5-0.8B-Q4_K_M.gguf"),
            ("gemma-3-1b-it-Q4_K_M.gguf", "gemma-3-1b-it-Q4_K_M.gguf"),
            ("custom-local-model.gguf", "custom-local-model.gguf")
        ]

        for expectation in expectations {
            XCTAssertEqual(
                RuntimeModelCatalog.displayName(for: expectation.filename),
                expectation.displayName,
                expectation.filename
            )
        }
    }

    func test_runtimeBootstrapState_failureDetailIsNonNilOnlyWhenFailed() {
        XCTAssertEqual(RuntimeBootstrapState.failed("Missing model file").failureDetail, "Missing model file")
        XCTAssertNil(RuntimeBootstrapState.idle.failureDetail)
        XCTAssertNil(RuntimeBootstrapState.loading("Loading model").failureDetail)
        XCTAssertNil(RuntimeBootstrapState.ready("tabby-2-base ready").failureDetail)
    }

    func test_runtimeModelOption_keepsRawFilenameAsIdentityButAliasesDisplayName() {
        let option = RuntimeModelOption(
            filename: "Qwen3.5-0.8B-Base.i1-Q6_K.gguf",
            url: URL(fileURLWithPath: "/tmp/models/Qwen3.5-0.8B-Base.i1-Q6_K.gguf")
        )

        XCTAssertEqual(option.id, "Qwen3.5-0.8B-Base.i1-Q6_K.gguf")
        XCTAssertEqual(option.displayName, "tabby-2-nano")
    }

    func test_downloadableRuntimeModel_defaultsLeaveValidationMetadataEmpty() throws {
        let url = try XCTUnwrap(URL(string: "https://example.com/custom.gguf"))
        let model = DownloadableRuntimeModel(
            filename: "custom.gguf",
            displayName: "Custom",
            downloadURL: url,
            approximateSizeInGigabytes: 1.4
        )

        XCTAssertEqual(model.id, "https://example.com/custom.gguf")
        XCTAssertNil(model.expectedSizeBytes)
        XCTAssertNil(model.sha256)
        XCTAssertEqual(model.approximateSizeLabel, "~1.4 GB")
    }

    func test_downloadableModelCatalog_entriesAreUniqueHuggingFaceGGUFDownloads() {
        let models = RuntimeModelCatalog.downloadableModels

        XCTAssertEqual(models.count, 4)
        XCTAssertEqual(Set(models.map(\.id)).count, models.count)
        for model in models {
            XCTAssertTrue(model.filename.hasSuffix(".gguf"), "\(model.filename) should be a GGUF")
            XCTAssertEqual(model.downloadURL.host, "huggingface.co")
            XCTAssertTrue(model.downloadURL.absoluteString.hasSuffix("?download=true"))
            XCTAssertEqual(model.displayName, RuntimeModelCatalog.displayName(for: model.filename))
        }
    }

    func test_defaultRuntimeConfiguration_prefersExactlyTheDownloadableCatalog() {
        // The locator loads the first preferred file that exists. A preferred name missing from the
        // catalog could never be installed by onboarding, and a catalog model missing from the list
        // would lose its priority slot to alphabetical discovery.
        let preferred = LlamaRuntimeConfiguration.default.preferredModelNames
        let catalog = RuntimeModelCatalog.downloadableModels.map(\.filename)

        XCTAssertEqual(Set(preferred), Set(catalog))
        XCTAssertEqual(preferred.count, catalog.count, "Preferred names must not contain duplicates")
    }

    func test_llamaGenerationOptions_defaultsKeepMaskingAndSuppressionOff() {
        // Omitting the trailing parameters must reproduce the conservative production defaults:
        // no line masking, no forced word continuation, suppression disabled, two-token stop floor,
        // and the argmax end-of-generation stop left on.
        let options = LlamaGenerationOptions(
            maxPredictionTokens: 8,
            temperature: 0.1,
            topK: 20,
            topP: 0.7,
            minP: 0.08,
            repetitionPenalty: 1.05,
            seed: nil
        )

        XCTAssertNil(options.seed)
        XCTAssertFalse(options.singleLine)
        XCTAssertFalse(options.forceWordContinuation)
        XCTAssertEqual(options.confidenceFloor, -.infinity)
        XCTAssertEqual(options.sentenceStopMinimumTokens, 2)
        XCTAssertTrue(options.stopAtArgmaxEOG)
    }
}
