import Foundation

/// File overview:
/// Low-level actor that owns the MLX model lifecycle: loading weights from a local directory,
/// tokenizing prompts, running inference, and releasing GPU/memory resources on shutdown.
///
/// This mirrors `LlamaRuntimeCore`'s role but targets Apple's MLX framework for Apple Silicon.
/// All mutable native state is isolated inside this actor so concurrent generation requests
/// are serialized without external locks.

#if canImport(MLX)
import MLX
import MLXLLM
import MLXLMCommon
#endif

/// Metadata returned after a successful model load.
struct PreparedMLXRuntime: Equatable, Sendable {
    let modelDirectoryURL: URL
    let modelDisplayName: String
}

actor MLXRuntimeCore {
    private var isShutdown = false

    #if canImport(MLX)
    private var loadedModel: MLXLMCommon.ModelContainer?
    #endif

    /// Loads an MLX model from a local directory containing config.json and safetensors weights.
    func prepare(modelDirectoryURL: URL) async throws -> PreparedMLXRuntime {
        #if canImport(MLX)
        isShutdown = false
        let modelName = modelDirectoryURL.lastPathComponent

        let configuration = ModelConfiguration(directory: modelDirectoryURL)
        let container = try await MLXLMCommon.ModelFactory.shared.loadContainer(
            configuration: configuration
        )
        loadedModel = container

        return PreparedMLXRuntime(
            modelDirectoryURL: modelDirectoryURL,
            modelDisplayName: RuntimeModelCatalog.displayName(for: modelName)
        )
        #else
        throw LlamaRuntimeError.unavailable(
            "MLX framework is not available. Add the mlx-swift SPM dependency to enable MLX inference."
        )
        #endif
    }

    /// Generates text from a prompt using the loaded MLX model.
    func generate(
        prompt: String,
        maxTokens: Int,
        temperature: Float
    ) async throws -> String {
        #if canImport(MLX)
        guard let container = loadedModel else {
            throw LlamaRuntimeError.unavailable("No MLX model is loaded.")
        }

        let result = try await container.perform { (model, tokenizer) in
            let promptTokens = tokenizer.encode(text: prompt)
            var generatedTokens: [Int] = []

            let generateParameters = GenerateParameters(temperature: temperature)
            try MLXLMCommon.generate(
                input: LMInput(tokens: MLXArray(promptTokens)),
                parameters: generateParameters,
                model: model,
                tokenizer: tokenizer,
                extraEOSTokens: nil
            ) { tokens in
                generatedTokens.append(contentsOf: tokens.map { Int($0) })
                if generatedTokens.count >= maxTokens {
                    return .stop
                }
                return .more
            }

            return tokenizer.decode(tokens: generatedTokens)
        }

        return result
        #else
        throw LlamaRuntimeError.unavailable(
            "MLX framework is not available."
        )
        #endif
    }

    /// Releases the loaded model and frees GPU/unified memory.
    func shutdown() {
        isShutdown = true
        #if canImport(MLX)
        loadedModel = nil
        #endif
    }
}
