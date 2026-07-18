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
    @Published private(set) var hasMoreResults: Bool = false
    @Published private(set) var isLoadingMore: Bool = false

    @Published private(set) var selectedRepoId: String?

    private var searchTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var loadMoreTask: Task<Void, Never>?
    private var accumulatedResults: [HFModelSearchResult] = []

    private static let pageSize = 20

    func search() {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }

        searchTask?.cancel()
        loadMoreTask?.cancel()
        detailState = .idle
        accumulatedResults = []

        searchTask = Task {
            searchState = .searching

            do {
                let results = try await HuggingFaceAPIClient.searchModels(
                    query: query, limit: Self.pageSize, offset: 0
                )
                guard !Task.isCancelled else { return }

                if results.isEmpty {
                    searchState = .noResults
                    hasMoreResults = false
                } else {
                    accumulatedResults = results
                    searchState = .results(results)
                    hasMoreResults = results.count >= Self.pageSize
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                searchState = .failed(error.localizedDescription)
            }
        }
    }

    func loadMore() {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, hasMoreResults, !isLoadingMore else { return }

        loadMoreTask?.cancel()
        loadMoreTask = Task {
            isLoadingMore = true
            defer { isLoadingMore = false }

            do {
                let nextPage = try await HuggingFaceAPIClient.searchModels(
                    query: query, limit: Self.pageSize, offset: accumulatedResults.count
                )
                guard !Task.isCancelled else { return }

                accumulatedResults.append(contentsOf: nextPage)
                searchState = .results(accumulatedResults)
                hasMoreResults = nextPage.count >= Self.pageSize
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                hasMoreResults = false
                searchState = .failed(error.localizedDescription)
            }
        }
    }

    func fetchFiles(for repoId: String) {
        detailTask?.cancel()
        selectedRepoId = repoId

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

    func collapseDetail() {
        detailTask?.cancel()
        detailState = .idle
        selectedRepoId = nil
    }

    func reset() {
        searchTask?.cancel()
        detailTask?.cancel()
        loadMoreTask?.cancel()
        searchQuery = ""
        searchState = .idle
        detailState = .idle
        selectedRepoId = nil
        hasMoreResults = false
        isLoadingMore = false
        accumulatedResults = []
    }

    func makeDownloadableModel(from file: HFRepoFile, repoId: String) -> DownloadableRuntimeModel? {
        // HuggingFace repo paths can include subdirectories (e.g. "gguf/model-Q4.gguf").
        // Use only the leaf filename so the download lands flat in Tabby's model directory.
        let leafFilename = (file.path as NSString).lastPathComponent
        guard let url = file.downloadURL(repoId: repoId) else { return nil }
        return DownloadableRuntimeModel(
            filename: leafFilename,
            displayName: leafFilename,
            downloadURL: url,
            approximateSizeInGigabytes: file.sizeInGigabytes,
            expectedSizeBytes: nil,
            sha256: nil
        )
    }
}
