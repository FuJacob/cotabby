import Combine
import Foundation

/// Drives the two-step HuggingFace browse flow: search for repos, then drill into
/// a repo to list its GGUF files. Owns cancellation and debouncing so the UI layer
/// can bind directly to published state without managing async Tasks.
@MainActor
final class HuggingFaceSearchService: ObservableObject {

    enum SearchState: Equatable {
        case idle
        case searching
        case results([HFModelSearchResult])
        case noResults
        case failed(String)
    }

    enum DetailState: Equatable {
        case idle
        case loading
        case loaded(repoId: String, ggufFiles: [HFRepoFile])
        case failed(String)
    }

    @Published var searchQuery: String = ""
    @Published private(set) var searchState: SearchState = .idle
    @Published private(set) var detailState: DetailState = .idle

    private var searchTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?

    func search() {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }

        searchTask?.cancel()
        detailState = .idle

        searchTask = Task {
            searchState = .searching

            do {
                try await Task.sleep(nanoseconds: 400_000_000)
                let results = try await HuggingFaceAPIClient.searchModels(query: query)
                guard !Task.isCancelled else { return }

                if results.isEmpty {
                    searchState = .noResults
                } else {
                    searchState = .results(results)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                searchState = .failed(error.localizedDescription)
            }
        }
    }

    func fetchFiles(for repoId: String) {
        detailTask?.cancel()

        detailTask = Task {
            detailState = .loading

            do {
                let allFiles = try await HuggingFaceAPIClient.fetchRepoFiles(repoId: repoId)
                guard !Task.isCancelled else { return }

                let ggufFiles = allFiles
                    .filter(\.isGGUF)
                    .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }

                if ggufFiles.isEmpty {
                    detailState = .failed("No GGUF files found in this repository.")
                } else {
                    detailState = .loaded(repoId: repoId, ggufFiles: ggufFiles)
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                detailState = .failed(error.localizedDescription)
            }
        }
    }

    func reset() {
        searchTask?.cancel()
        detailTask?.cancel()
        searchQuery = ""
        searchState = .idle
        detailState = .idle
    }

    func makeDownloadableModel(from file: HFRepoFile, repoId: String) -> DownloadableRuntimeModel {
        DownloadableRuntimeModel(
            filename: file.path,
            displayName: file.path,
            downloadURL: file.downloadURL(repoId: repoId),
            approximateSizeInGigabytes: file.sizeInGigabytes,
            expectedSizeBytes: nil,
            sha256: nil
        )
    }
}
