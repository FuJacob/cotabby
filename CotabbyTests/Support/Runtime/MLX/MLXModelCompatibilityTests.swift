import XCTest
@testable import Cotabby

final class MLXModelCompatibilityTests: XCTestCase {
    private let goodFiles = ["config.json", "model.safetensors", "tokenizer.json"]

    private func verdict(
        _ name: String = "gemma-4-e4b-5bit",
        files: [String]? = nil,
        config: [String: Any]? = ["model_type": "gemma4", "architectures": ["Gemma4ForCausalLM"]],
        supported: Set<String>? = ["gemma4"]
    ) -> MLXModelCompatibility.Verdict {
        MLXModelCompatibility.verdict(
            repoName: name, fileNames: files ?? goodFiles, config: config, supportedModelTypes: supported)
    }

    func test_baseModelIsCompatible() {
        XCTAssertEqual(verdict(), .compatible(modelType: "gemma4", isInstruct: false))
    }

    func test_instructModelIsCompatibleAndMarked() {
        XCTAssertEqual(verdict("gemma-4-e4b-it-4bit"), .compatible(modelType: "gemma4", isInstruct: true))
        XCTAssertFalse(MLXModelCompatibility.isInstructName("unit-test"), "'it' must be a whole token")
    }

    func test_embeddingByName() {
        XCTAssertEqual(verdict("Qwen3-Embedding-0.6B-8bit"), .incompatible(.embeddingModel))
    }

    func test_rerankerByName() {
        XCTAssertEqual(verdict("bge-reranker-v2"), .incompatible(.rerankerModel))
    }

    func test_ttsByName() {
        XCTAssertEqual(verdict("Qwen3-TTS-12Hz-1.7B-Base-bf16"), .incompatible(.speechModel))
    }

    func test_speechByArchitecture() {
        let config: [String: Any] = ["model_type": "gemma4", "architectures": ["Wav2Vec2ForCTC"]]
        XCTAssertEqual(verdict(config: config), .incompatible(.speechModel))
    }

    func test_classifierByArchitecture() {
        let config: [String: Any] = ["model_type": "gemma4", "architectures": ["BertForSequenceClassification"]]
        XCTAssertEqual(verdict(config: config), .incompatible(.classifierModel))
    }

    func test_unsupportedModelType() {
        XCTAssertEqual(verdict(config: ["model_type": "xyz"]), .incompatible(.unsupportedArchitecture("xyz")))
    }

    func test_unknownSupportedSetStillRejectsEmbeddingButAcceptsOddType() {
        XCTAssertEqual(verdict("a-embed", supported: nil), .incompatible(.embeddingModel))
        XCTAssertEqual(verdict(config: ["model_type": "xyz"], supported: nil),
                       .compatible(modelType: "xyz", isInstruct: false))
    }

    func test_missingFiles() {
        XCTAssertEqual(verdict(files: ["model.safetensors", "tokenizer.json"]), .incompatible(.missingConfig))
        XCTAssertEqual(verdict(files: ["config.json", "tokenizer.json"]), .incompatible(.missingWeights))
        XCTAssertEqual(verdict(files: ["config.json", "model.safetensors"]), .incompatible(.missingTokenizer))
    }

    func test_unreadableConfig() {
        XCTAssertEqual(verdict(config: nil), .incompatible(.unreadableConfig))
        XCTAssertEqual(verdict(config: ["architectures": ["X"]]), .incompatible(.unreadableConfig))
    }

    func test_messagesAreOneSentence() {
        XCTAssertEqual(MLXModelCompatibility.Reason.embeddingModel.message, "Embedding model: it can't write text.")
        XCTAssertEqual(MLXModelCompatibility.Reason.unsupportedArchitecture("xyz").message,
                       "Architecture “xyz” isn't supported by the installed mlx-lm.")
    }
}
