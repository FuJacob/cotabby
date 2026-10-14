import CoreGraphics
import Foundation

/// File overview:
/// Values shared by the selection-rewrite subsystem: what the user asked for and the user's Rewrite
/// settings. Pure data; the coordinator, engine and prompt builder pass them
/// between each other so none of them owns another's state.

/// One rewrite the popup offers. `custom` carries the user's own instruction.
nonisolated enum RewriteAction: Equatable, Hashable, Sendable {
    case fixOnly, rewrite, shorter, longer
    case family, friendly, closeFriend, formal, customer
    case custom(String)

    /// The popup's buttons: who the text is for. `custom` comes from the instruction box instead.
    /// Typo fixing is the tick box, not a button.
    static let tones: [RewriteAction] = [.family, .friendly, .closeFriend, .formal, .customer]
    /// Offered on the preview once a tone was chosen: they reshape that result, keeping its tone.
    static let refinements: [RewriteAction] = [.shorter, .longer]

    var label: String {
        switch self {
        case .fixOnly: return "Fix only"
        case .rewrite: return "Rewrite"
        case .shorter: return "Shorter"
        case .longer: return "Longer"
        case .family: return "Family"
        case .friendly: return "Friendly"
        case .closeFriend: return "Close friend"
        case .formal: return "Formal"
        case .customer: return "Customer"
        case .custom: return "Custom"
        }
    }
}

/// What the user picked in Settings → Rewrite → Rewrite Model. Every local engine reuses the model
/// already set up for autocomplete (there is no rewrite-only model); `sameAsAutocomplete` follows
/// whichever engine autocomplete is on and is turned into one of the concrete cases by
/// `RewriteProviderResolver`. Raw values are persisted; the earlier `local` ("Apple Intelligence,
/// else Cotabby's model") is migrated by `RewritePreferencesStore`, not decoded here.
nonisolated enum RewriteProviderKind: String, CaseIterable, Sendable {
    case sameAsAutocomplete, appleIntelligence, openSource, localEndpoint, mlx, api
}

/// The cloud services a rewrite can use with the user's own API key. Claude goes through Anthropic's
/// Messages API (`AnthropicMessagesClient`); every other service through its OpenAI-compatible
/// endpoint. `custom` is any compatible URL the user types (a self-hosted gateway, Ollama, a proxy).
nonisolated enum RewriteCloudProvider: String, CaseIterable, Sendable {
    case anthropic, openAI, gemini, mistral, groq, openRouter, xAI, deepSeek, custom

    var displayName: String {
        switch self {
        case .anthropic: return "Claude (Anthropic)"
        case .openAI: return "OpenAI (GPT)"
        case .gemini: return "Google Gemini"
        case .mistral: return "Mistral"
        case .groq: return "Groq"
        case .openRouter: return "OpenRouter"
        case .xAI: return "xAI (Grok)"
        case .deepSeek: return "DeepSeek"
        case .custom: return "Custom endpoint"
        }
    }

    /// The service's API root; nil for `custom`, whose URL the user enters.
    var baseURL: String? {
        switch self {
        case .anthropic: return "https://api.anthropic.com/v1"
        case .openAI: return "https://api.openai.com/v1"
        case .gemini: return "https://generativelanguage.googleapis.com/v1beta/openai"
        case .mistral: return "https://api.mistral.ai/v1"
        case .groq: return "https://api.groq.com/openai/v1"
        case .openRouter: return "https://openrouter.ai/api/v1"
        case .xAI: return "https://api.x.ai/v1"
        case .deepSeek: return "https://api.deepseek.com/v1"
        case .custom: return nil
        }
    }

    /// Models offered before the live list is loaded. Only stable names are listed; "Load models"
    /// asks the service for its current list.
    var suggestedModels: [String] {
        switch self {
        case .anthropic: return ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-1"]
        case .mistral: return ["mistral-large-latest", "mistral-small-latest"]
        case .deepSeek: return ["deepseek-chat"]
        default: return []
        }
    }

    /// The model used until the user picks one; empty where no name is stable enough to assume.
    var defaultModel: String { suggestedModels.first ?? "" }

    /// The Keychain item that holds this service's key, so switching services keeps every key. Apart
    /// from autocomplete's endpoint item, so a rewrite key never changes autocomplete.
    var keychainSuffix: String { "rewrite-endpoint.\(rawValue)" }
}

/// The Rewrite settings, as one snapshot the coordinator and engine read per rewrite.
nonisolated struct RewritePreferences: Equatable, Sendable {
    /// The master switch. Off: no selection is armed, so there is no wand, no ⌃⌥R key tap and no
    /// selection work at all.
    var isEnabled: Bool
    var provider: RewriteProviderKind
    /// Which cloud service the API provider uses.
    var cloudProvider: RewriteCloudProvider
    /// The URL for `custom`; the named services carry their own.
    var apiBaseURL: String
    /// The chosen model per service (by `RewriteCloudProvider.rawValue`), so switching keeps each choice.
    var modelsByProvider: [String: String]
    /// The popup's "Fix spelling & grammar" tick box: every action except Fix only also corrects
    /// mistakes when it is on. Remembered between rewrites.
    var fixesMistakes: Bool
    var showsButtonOnSelection: Bool
    var shortcutKeyCode: CGKeyCode
    var shortcutModifiers: UInt32
    var shortcutLabel: String

    static let defaults = RewritePreferences(
        isEnabled: true,
        provider: .sameAsAutocomplete,
        cloudProvider: .anthropic,
        apiBaseURL: "",
        modelsByProvider: [:],
        fixesMistakes: true,
        showsButtonOnSelection: true,
        shortcutKeyCode: 15, // kVK_ANSI_R
        shortcutModifiers: ShortcutModifierMask.control.rawValue | ShortcutModifierMask.option.rawValue,
        shortcutLabel: "⌃⌥R"
    )

    /// The model for the current service: the user's choice, else the service's default.
    var apiModelName: String {
        get { modelsByProvider[cloudProvider.rawValue] ?? cloudProvider.defaultModel }
        set { modelsByProvider[cloudProvider.rawValue] = newValue }
    }

    /// The API root the current service is reached at.
    var effectiveBaseURL: String { cloudProvider.baseURL ?? apiBaseURL }

    /// Whether a model list requested for `service` at `baseURL` still belongs to these settings.
    /// The user may switch service or edit the URL while the list loads; its result, or its error,
    /// must not then appear under the new one.
    func isModelListSource(service: RewriteCloudProvider, baseURL: String) -> Bool {
        cloudProvider == service && effectiveBaseURL == baseURL
    }
}

/// One rewrite to run: the selected text and the action, plus what the popup knows about them.
nonisolated struct RewriteRequest: Equatable, Sendable {
    let selection: String
    let action: RewriteAction
    /// The selection's language by its English name ("Turkish"), when `RewriteLanguageDetector`
    /// could tell; the prompt then requires it instead of hoping the model keeps the language.
    var language: String?
    /// The "Fix spelling & grammar" tick box at the time of the rewrite.
    var fixesMistakes: Bool = true
    /// Set when Shorter or Longer refines an earlier result: the tone (or custom instruction) that
    /// produced it, which the refinement keeps. `selection` is then that result, not the user's text.
    var tone: RewriteAction?
}

/// Where a popup's rewrites go, resolved once when the popup opens: the concrete provider and what
/// the disclosure says about it. Every run from that popup (the first action, Retry, Shorter, Longer)
/// goes to this destination, so the host the popup named is the host that receives the text.
nonisolated struct RewriteDestination: Equatable, Sendable {
    /// The resolved provider; never `sameAsAutocomplete`.
    let kind: RewriteProviderKind
    let sendsOffDevice: Bool
    let hostName: String?
    /// The server's full base URL (scheme, host, port, path) for a provider that talks to one over
    /// the network, nil otherwise. Not shown; it lets the engine notice a change the host alone
    /// would miss, such as another port on the same machine.
    let endpointURL: String?

    init(kind: RewriteProviderKind, sendsOffDevice: Bool, hostName: String?, endpointURL: String? = nil) {
        self.kind = kind
        self.sendsOffDevice = sendsOffDevice
        self.hostName = hostName
        self.endpointURL = endpointURL
    }

    /// The popup's line naming the host the selected text goes to; nil when it stays on this Mac.
    /// A Local Endpoint is the endpoint set up in Engine & Model, which the line says, because the
    /// user may know that host as autocomplete's rather than as a rewrite destination.
    var disclosure: String? {
        guard sendsOffDevice, let hostName else { return nil }
        if kind == .localEndpoint {
            return "The selected text is sent to \(hostName), the endpoint set up in Engine & Model."
        }
        return "The selected text is sent to \(hostName)."
    }
}

nonisolated enum RewriteError: LocalizedError, Equatable {
    case noProvider
    /// A named cloud service with no key saved; carries the service's display name.
    case missingAPIKey(String)
    case unusableOutput
    case selectionTooLong
    /// The chosen provider cannot run (MLX not ready, no model, ...); the text says why.
    case unavailable(String)
    /// Settings changed where the text would go after the popup named a destination.
    case destinationChanged

    var errorDescription: String? {
        switch self {
        case .noProvider: return "Set up a rewrite model in Settings → Rewrite."
        case .missingAPIKey(let service): return "Add your \(service) API key in Settings → Rewrite."
        case .unusableOutput: return "Couldn't rewrite this — try again."
        case .selectionTooLong: return "Selection too long to rewrite."
        case .unavailable(let reason): return reason
        case .destinationChanged: return "Rewrite settings changed. Close this popup and open it again."
        }
    }
}
