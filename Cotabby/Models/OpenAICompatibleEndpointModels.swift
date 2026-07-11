import Foundation

/// File overview:
/// Defines the transport-independent values shared by Settings, the endpoint client, and routing.
/// Keeping URL policy and connection state here means SwiftUI never needs to understand HTTP paths,
/// IP ranges, or OpenAI response envelopes.

/// Which OpenAI-compatible text-generation route Cotabby calls.
nonisolated enum OpenAICompatibleAPIMode: String, CaseIterable, Codable, Identifiable, Sendable {
    case completions
    case chatCompletions

    var id: String { rawValue }

    var displayLabel: String {
        switch self {
        case .completions: return "Completions"
        case .chatCompletions: return "Chat Completions"
        }
    }

    var route: String {
        switch self {
        case .completions: return "completions"
        case .chatCompletions: return "chat/completions"
        }
    }
}

/// One model identifier returned by `GET /v1/models`.
nonisolated struct OpenAICompatibleModelOption: Decodable, Equatable, Identifiable, Sendable {
    let id: String
    let ownedBy: String?

    private enum CodingKeys: String, CodingKey {
        case id
        case ownedBy = "owned_by"
    }
}

/// Chooses the durable model identifier after endpoint discovery finishes.
///
/// The connection model owns the fetched catalog, while `SuggestionSettingsModel` owns the user's
/// saved selection. Keeping the reconciliation rule in this pure type avoids teaching the SwiftUI
/// pane how to compare those two sources of truth and makes first-connection behavior testable.
/// The resolver lives for only the duration of the static call; no object owns it.
nonisolated enum OpenAICompatibleModelSelectionResolver {
    /// Preserve a still-available choice; otherwise use the endpoint's first model. The API client
    /// sorts its catalog before publishing it, so this fallback is stable rather than random.
    /// An empty catalog returns nil so manual identifiers survive endpoints that cannot list models.
    static func preferredSelection(
        currentSelection: String,
        discoveredModels: [OpenAICompatibleModelOption]
    ) -> String? {
        guard let firstModel = discoveredModels.first else { return nil }

        let current = currentSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        if let matchingModel = discoveredModels.first(where: { $0.id == current }) {
            return matchingModel.id
        }

        return firstModel.id
    }
}

/// Privacy classification for the configured server host.
nonisolated enum OpenAICompatibleHostScope: Equatable, Sendable {
    case loopback
    case localNetwork
    case publicInternet
}

/// A validated base URL plus the endpoint-specific model and request mode.
///
/// This value is created at the boundary before every discovery or generation request. That makes
/// malformed URLs fail deterministically and prevents model discovery from normalizing a URL
/// differently than generation does.
nonisolated struct OpenAICompatibleEndpointConfiguration: Equatable, Sendable {
    static let defaultBaseURLString = "http://127.0.0.1:11434/v1"

    let baseURL: URL
    let modelName: String
    let apiMode: OpenAICompatibleAPIMode
    let hostScope: OpenAICompatibleHostScope

    init(
        baseURLString: String,
        modelName: String,
        apiMode: OpenAICompatibleAPIMode
    ) throws {
        let candidate = baseURLString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: candidate),
              let rawScheme = components.scheme,
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw OpenAICompatibleEndpointError.invalidBaseURL
        }

        let scheme = rawScheme.lowercased()
        guard scheme == "http" || scheme == "https" else {
            throw OpenAICompatibleEndpointError.invalidBaseURL
        }

        components.scheme = scheme
        components.path = Self.normalizedBasePath(components.path)
        guard let normalizedURL = components.url else {
            throw OpenAICompatibleEndpointError.invalidBaseURL
        }

        let scope = Self.hostScope(for: host)
        if scheme == "http", scope == .publicInternet {
            throw OpenAICompatibleEndpointError.insecurePublicHTTP
        }

        baseURL = normalizedURL
        self.modelName = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiMode = apiMode
        hostScope = scope
    }

    func apiURL(path: String) -> URL {
        baseURL.appendingPathComponent(path, isDirectory: false)
    }

    var privacyWarning: String? {
        switch hostScope {
        case .loopback:
            return nil
        case .localNetwork:
            return "Cotabby will send typed text and any enabled context to this server on your local network."
        case .publicInternet:
            return "This server is outside your Mac. Typed text and any enabled context will leave your device."
        }
    }

    private static func normalizedBasePath(_ rawPath: String) -> String {
        var path = rawPath
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        if path.isEmpty || path == "/" {
            return "/v1"
        }
        return path
    }

    static func hostScope(for rawHost: String) -> OpenAICompatibleHostScope {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if host == "localhost" || host.hasSuffix(".localhost") || host == "::1" {
            return .loopback
        }

        if let octets = ipv4Octets(host) {
            if octets[0] == 127 { return .loopback }
            if octets[0] == 10
                || (octets[0] == 172 && (16...31).contains(octets[1]))
                || (octets[0] == 192 && octets[1] == 168)
                || (octets[0] == 169 && octets[1] == 254) {
                return .localNetwork
            }
            return .publicInternet
        }

        // A single-label DNS name is not proof of LAN scope: DNS may resolve it publicly.
        if host.hasSuffix(".local") || host.hasPrefix("fc") || host.hasPrefix("fd")
            || (host.hasPrefix("fe") && (host.dropFirst(2).first.map { "89ab".contains($0) } ?? false)) {
            return .localNetwork
        }

        return .publicInternet
    }

    private static func ipv4Octets(_ host: String) -> [Int]? {
        let pieces = host.split(separator: ".", omittingEmptySubsequences: false)
        guard pieces.count == 4 else { return nil }
        let octets = pieces.compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return nil }
        return octets
    }
}

nonisolated enum OpenAICompatibleEndpointError: LocalizedError, Equatable {
    case invalidBaseURL
    case insecurePublicHTTP
    case emptyModelName

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL:
            return "Enter an HTTP or HTTPS base URL without credentials, a query, or a fragment."
        case .insecurePublicHTTP:
            return "Public endpoints must use HTTPS. HTTP is limited to this Mac or the local network."
        case .emptyModelName:
            return "Choose or enter a model before generating suggestions."
        }
    }
}

/// UI-facing state for the latest endpoint model-discovery request.
enum OpenAICompatibleConnectionState: Equatable {
    case idle
    case connecting
    case ready(modelCount: Int)
    case failed(String)

    var summary: String {
        switch self {
        case .idle: return "Not connected"
        case .connecting: return "Connecting…"
        case .ready(let count): return count == 1 ? "Connected · 1 model" : "Connected · \(count) models"
        case .failed(let message): return message
        }
    }

    var failureDetail: String? {
        guard case .failed(let message) = self else { return nil }
        return message
    }
}

/// Narrow credential boundary so production uses Keychain while tests use an in-memory fake.
@MainActor
protocol OpenAICompatibleCredentialStoring: AnyObject {
    func readAPIKey() throws -> String?
    func saveAPIKey(_ apiKey: String?) throws
    func deleteAPIKey() throws
}

/// Process-local credential store used by isolated settings tests and previews.
/// The app composition root explicitly injects the Keychain implementation.
@MainActor
final class InMemoryOpenAICompatibleCredentialStore: OpenAICompatibleCredentialStoring {
    private var apiKey: String?

    init(apiKey: String? = nil) {
        self.apiKey = apiKey
    }

    // Xcode 26.0–26.3 can generate an invalid isolated deinitializer for a class stored behind a
    // protocol existential in a MainActor-isolated owner. An explicit deinitializer avoids that
    // Swift runtime bug; this can be removed once CI no longer supports those toolchains.
    deinit {}

    func readAPIKey() throws -> String? { apiKey }

    func saveAPIKey(_ apiKey: String?) throws {
        let value = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.apiKey = value?.isEmpty == false ? value : nil
    }

    func deleteAPIKey() throws {
        apiKey = nil
    }
}
