import Foundation

/// The scheme, host, and port that identify one OpenAI-compatible server.
///
/// Why this exists as its own type: the endpoint receives the user's text and API key, so Cotabby
/// must be able to answer "is this the same server?" exactly. Raw URL strings answer it badly:
/// `HTTPS://Models.Example.com/v1/` and `https://models.example.com:443` name the same server, while
/// `http://host` and `https://host` do not. Keeping the normalization in one value means every check
/// that compares servers agrees on the answer. It is created for one comparison and owned by nothing.
nonisolated struct OpenAICompatibleEndpointOrigin: Equatable, Sendable {
    let scheme: String
    let host: String
    let port: Int

    /// Nil for anything that is not an absolute HTTP(S) URL with a host, so a caller can only ever
    /// treat an unparseable URL as "not the same server".
    init?(url: URL) {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let defaultPort = Self.defaultPorts[scheme],
              let rawHost = components.host else {
            return nil
        }
        // Foundation may or may not keep the brackets around an IPv6 literal depending on the API
        // that produced the URL; strip them so both spellings compare equal.
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        guard !host.isEmpty else { return nil }

        self.scheme = scheme
        self.host = host
        port = components.port ?? defaultPort
    }

    /// Stable text form with an explicit port, for example `https://models.example.com:443` or
    /// `http://[::1]:11434`. Two origins are equal exactly when their serialized forms are equal.
    var serialized: String {
        let hostComponent = host.contains(":") ? "[\(host)]" : host
        return "\(scheme)://\(hostComponent):\(port)"
    }

    private static let defaultPorts = ["http": 80, "https": 443]
}
