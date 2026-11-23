import Foundation

/// Codable types matching the HuggingFace REST API response shapes.
/// These are pure value types with no business logic beyond URL construction.

/// One result from `GET /api/models?filter=gguf&search=...&sort=downloads`.
nonisolated struct HFModelSearchResult: Codable, Identifiable, Equatable {
    let id: String
    let downloads: Int
    let likes: Int
}

/// Git LFS metadata the tree API reports for large files. `oid` is the SHA-256 of the file's
/// contents (Hugging Face serves the same value as `X-Linked-ETag` on the download), so it is what a
/// search download is verified against.
nonisolated struct HFLFSPointer: Codable, Equatable {
    let oid: String
    let size: Int64
}

/// One file entry from `GET /api/models/<repoId>/tree/main`.
struct HFRepoFile: Codable, Equatable, Identifiable {
    let path: String
    let size: Int64
    /// Nil for small files kept in plain git, which carry no SHA-256 Cotabby can verify. A `var` so
    /// the memberwise initializer defaults it to nil.
    var lfs: HFLFSPointer?

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
