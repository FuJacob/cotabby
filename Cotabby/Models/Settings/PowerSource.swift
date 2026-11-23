import Foundation

/// The two power states a per-power-source profile can be configured for.
enum PowerSource: CaseIterable {
    case battery
    case pluggedIn

    init(isPluggedIn: Bool) {
        self = isPluggedIn ? .pluggedIn : .battery
    }
}

extension PowerProfile {
    /// Assembles a profile from the three values persisted for one power source. The model
    /// filename and endpoint model name are both kept whichever engine is active, so switching a
    /// source to another engine and back restores the model it had.
    init(engine: SuggestionEngineKind, modelFilename: String, endpointModelName: String) {
        switch engine {
        case .appleIntelligence:
            self = .appleIntelligence
        case .llamaOpenSource:
            self = .llama(filename: modelFilename)
        case .openAICompatible:
            self = .openAICompatible(modelName: endpointModelName)
        }
    }

    /// True for a power source the user has never configured. The persisted default is the Open
    /// Source engine with no model chosen, which no explicit choice can produce: picking a model
    /// stores its filename, and picking another engine changes the engine.
    var isUnconfigured: Bool {
        if case .llama(let filename) = self {
            return filename.isEmpty
        }
        return false
    }
}
