import Foundation

/// Codable types matching the HuggingFace REST API response shapes.
/// These are pure value types with no business logic beyond URL construction.

/// One result from `GET /api/models?filter=gguf&search=...&sort=downloads`.
nonisolated struct HFModelSearchResult: Codable, Identifiable, Equatable {
    let id: String
    let modelId: String
    let downloads: Int
    let likes: Int
    let tags: [String]
}

/// One file entry from `GET /api/models/<repoId>/tree/main`.
struct HFRepoFile: Codable, Equatable, Identifiable {
    let path: String
    let size: Int64
    let type: String

    var id: String { path }

    var isGGUF: Bool {
        path.lowercased().hasSuffix(".gguf")
    }

    var sizeInGigabytes: Double {
        Double(size) / 1_073_741_824
    }

    var sizeLabel: String {
        if sizeInGigabytes >= 1.0 {
            return String(format: "%.1f GB", sizeInGigabytes)
        }
        let megabytes = Double(size) / 1_048_576
        return String(format: "%.0f MB", megabytes)
    }

    func downloadURL(repoId: String) -> URL? {
        let encodedPath = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
        var components = URLComponents()
        components.scheme = "https"
        components.host = "huggingface.co"
        components.path = "/\(repoId)/resolve/main/\(encodedPath)"
        components.queryItems = [URLQueryItem(name: "download", value: "true")]
        return components.url
    }
}
