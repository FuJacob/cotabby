import Foundation

/// File overview:
/// Decides whether the configured endpoint may receive a request, and what the approval record
/// should be after launch.
///
/// Why this lives in `Support/`: the server URL and the selected engine are plain UserDefaults keys,
/// which any process running as the same user can rewrite. The approval record is kept in the
/// Keychain instead, and a request is only allowed when the configured server matches it. Keeping
/// that comparison and the one-time upgrade rule pure means `SuggestionSettingsModel` only moves
/// values between the Keychain and memory, and tests can pin every case without a Keychain.

/// What the Keychain says about which endpoint server the user approved with Connect.
nonisolated enum OpenAICompatibleOriginApproval: Equatable, Sendable {
    /// A record exists but names no server: a fresh install, an upgrade that had no endpoint in use,
    /// or a settings reset. Nothing may be sent until the user presses Connect.
    case nothingApproved
    /// The serialized `OpenAICompatibleEndpointOrigin` the user approved.
    case approved(origin: String)

    /// Sentinel stored for `.nothingApproved`. A serialized origin always starts with a scheme, so
    /// it can never collide. Storing a sentinel rather than deleting the record matters: a missing
    /// record is what triggers the one-time upgrade adoption, and that must never run twice.
    static let noneRecord = "none"

    init(record: String) {
        self = record == Self.noneRecord ? .nothingApproved : .approved(origin: record)
    }

    var record: String {
        switch self {
        case .nothingApproved: return Self.noneRecord
        case .approved(let origin): return origin
        }
    }
}

enum OpenAICompatibleOriginApprovalPolicy {
    /// The approval to use after launch, plus the record to write back when none existed yet.
    struct Restoration: Equatable {
        let approval: OpenAICompatibleOriginApproval
        let recordToPersist: String?
    }

    /// `storedRecord` is nil only when the Keychain has no record at all, which happens once: on the
    /// first launch of a build that knows about approvals. An existing endpoint user then adopts the
    /// server they already have configured so the upgrade does not silently stop their suggestions.
    /// Everyone else gets the `.nothingApproved` sentinel, so a later rewrite of the defaults cannot
    /// make this adoption run again.
    static func restore(
        storedRecord: String?,
        configuredBaseURL: String,
        endpointInUse: Bool
    ) -> Restoration {
        if let storedRecord {
            return Restoration(approval: OpenAICompatibleOriginApproval(record: storedRecord), recordToPersist: nil)
        }

        let approval: OpenAICompatibleOriginApproval
        if endpointInUse, let origin = origin(forBaseURL: configuredBaseURL) {
            approval = .approved(origin: origin)
        } else {
            approval = .nothingApproved
        }
        return Restoration(approval: approval, recordToPersist: approval.record)
    }

    /// Whether `configuration` points at the approved server. Path, case, a default port, and a
    /// trailing slash do not matter; scheme, host, and port do.
    static func allows(
        _ configuration: OpenAICompatibleEndpointConfiguration,
        approval: OpenAICompatibleOriginApproval
    ) -> Bool {
        guard case .approved(let approvedOrigin) = approval,
              let origin = OpenAICompatibleEndpointOrigin(url: configuration.baseURL) else {
            return false
        }
        return origin.serialized == approvedOrigin
    }

    /// The serialized origin for a base URL as the user typed it, validated by the same rules a
    /// request uses. Nil for a URL Cotabby would refuse to call anyway.
    static func origin(forBaseURL baseURLString: String) -> String? {
        guard let configuration = try? OpenAICompatibleEndpointConfiguration(
            baseURLString: baseURLString,
            modelName: "",
            apiMode: .chatCompletions
        ) else {
            return nil
        }
        return OpenAICompatibleEndpointOrigin(url: configuration.baseURL)?.serialized
    }

    /// Whether an upgrading user relies on the endpoint: selected now, or reached through a power
    /// profile. A power-profile user would otherwise lose suggestions the next time the power
    /// source switches the engine.
    static func endpointInUse(
        selectedEngine: SuggestionEngineKind,
        isPowerBasedModelSwitchingEnabled: Bool,
        batteryEngine: SuggestionEngineKind,
        pluggedInEngine: SuggestionEngineKind
    ) -> Bool {
        if selectedEngine == .openAICompatible { return true }
        guard isPowerBasedModelSwitchingEnabled else { return false }
        return batteryEngine == .openAICompatible || pluggedInEngine == .openAICompatible
    }
}
