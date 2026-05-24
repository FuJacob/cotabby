import Foundation

/// Stateless client for the HuggingFace public REST API.
/// Each call creates an ephemeral URLSession — matching the existing networking pattern
/// in ModelDownloadManager — so no shared state or cookies persist between requests.
enum HuggingFaceAPIClient {

    enum APIError: LocalizedError {
        case invalidURL
        case httpError(statusCode: Int)
        case rateLimited
        case decodingFailed(Error)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "Invalid HuggingFace API URL."
            case .httpError(let statusCode):
                return "HuggingFace returned HTTP \(statusCode)."
            case .rateLimited:
                return "Too many requests — please wait a moment and try again."
            case .decodingFailed(let error):
                return "Failed to parse HuggingFace response: \(error.localizedDescription)"
            }
        }
    }

    /// Search for GGUF model repositories sorted by download count.
    static func searchModels(query: String, limit: Int = 20, offset: Int = 0) async throws -> [HFModelSearchResult] {
        guard var components = URLComponents(string: "https://huggingface.co/api/models") else {
            throw APIError.invalidURL
        }
        components.queryItems = [
            URLQueryItem(name: "filter", value: "gguf"),
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "sort", value: "downloads"),
            URLQueryItem(name: "direction", value: "-1"),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset))
        ]
        guard let url = components.url else {
            throw APIError.invalidURL
        }

        let data = try await performRequest(url: url)
        do {
            return try JSONDecoder().decode([HFModelSearchResult].self, from: data)
        } catch {
            throw APIError.decodingFailed(error)
        }
    }

    /// Fetch the file tree for a repository, including exact file sizes from LFS metadata.
    static func fetchRepoFiles(repoId: String) async throws -> [HFRepoFile] {
        guard var components = URLComponents(string: "https://huggingface.co") else {
            throw APIError.invalidURL
        }
        components.path = "/api/models/\(repoId)/tree/main"
        guard let url = components.url else {
            throw APIError.invalidURL
        }

        let data = try await performRequest(url: url)
        do {
            return try JSONDecoder().decode([HFRepoFile].self, from: data)
        } catch {
            throw APIError.decodingFailed(error)
        }
    }

    private static func performRequest(url: URL) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse else {
            return data
        }

        if httpResponse.statusCode == 429 {
            throw APIError.rateLimited
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        return data
    }
}
