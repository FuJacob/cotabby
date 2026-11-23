import Combine
import Foundation

/// Drives the two-step HuggingFace browse flow: search for repos, then drill into
/// a repo to list its GGUF files. Owns the request tasks and their cancellation so the UI layer
/// can bind directly to published state without managing async Tasks.
@MainActor
final class HuggingFaceSearchService: ObservableObject {
    typealias SearchState = HuggingFaceBrowseState.SearchState
    typealias DetailState = HuggingFaceBrowseState.DetailState
    typealias SearchModels = @MainActor (_ query: String, _ limit: Int, _ offset: Int) async throws -> [HFModelSearchResult]
    typealias FetchRepoFiles = @MainActor (_ repoId: String) async throws -> [HFRepoFile]

    @Published var searchQuery: String = ""
    @Published private var browseState = HuggingFaceBrowseState()

    var searchState: SearchState { browseState.search }
    var detailState: DetailState { browseState.detail }
    var hasMoreResults: Bool { browseState.hasMoreResults }
    var isLoadingMore: Bool { browseState.isLoadingMore }
    var selectedRepoId: String? { browseState.selectedRepoId }

    private let searchModels: SearchModels
    private let fetchRepoFiles: FetchRepoFiles
    private var searchTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var loadMoreTask: Task<Void, Never>?

    /// The two network calls are injectable so the browse transitions can be driven in tests
    /// without reaching the public Hugging Face API.
    init(
        searchModels: @escaping SearchModels = { query, limit, offset in
            try await HuggingFaceAPIClient.searchModels(query: query, limit: limit, offset: offset)
        },
        fetchRepoFiles: @escaping FetchRepoFiles = { repoId in
            try await HuggingFaceAPIClient.fetchRepoFiles(repoId: repoId)
        }
    ) {
        self.searchModels = searchModels
        self.fetchRepoFiles = fetchRepoFiles
    }

    func search() {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }

        searchTask?.cancel()
        loadMoreTask?.cancel()
        detailTask?.cancel()
        browseState.beginSearch()

        searchTask = Task {
            do {
                let results = try await searchModels(query, HuggingFaceBrowseState.pageSize, 0)
                guard !Task.isCancelled else { return }
                browseState.finishSearch(results)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                browseState.failSearch(error.localizedDescription)
            }
        }
    }

    func loadMore() {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, let offset = browseState.beginLoadMore() else { return }

        loadMoreTask = Task {
            do {
                let nextPage = try await searchModels(query, HuggingFaceBrowseState.pageSize, offset)
                guard !Task.isCancelled else { return }
                browseState.finishLoadMore(nextPage)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                browseState.failLoadMore(error.localizedDescription)
            }
        }
    }

    func fetchFiles(for repoId: String) {
        detailTask?.cancel()
        browseState.beginDetail(repoId: repoId)

        detailTask = Task {
            do {
                let allFiles = try await fetchRepoFiles(repoId)
                guard !Task.isCancelled else { return }
                browseState.finishDetail(repoId: repoId, files: allFiles)
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled else { return }
                browseState.failDetail(repoId: repoId, message: error.localizedDescription)
            }
        }
    }

    func collapseDetail() {
        detailTask?.cancel()
        browseState.collapseDetail()
    }

    func reset() {
        searchTask?.cancel()
        detailTask?.cancel()
        loadMoreTask?.cancel()
        searchQuery = ""
        browseState = HuggingFaceBrowseState()
    }

    /// Whether a listed repository file can be downloaded, and why not when it can't. The browser
    /// shows refused files with their reason instead of hiding them, so a repo's list never looks
    /// silently incomplete.
    enum DownloadOffer: Equatable {
        case available(DownloadableRuntimeModel)
        case unavailable(reason: String)
    }

    static func downloadOffer(for file: HFRepoFile, repoId: String) -> DownloadOffer {
        switch RuntimeModelCatalog.curatedFilenameMatch(filePath: file.path, huggingFaceRepoID: repoId) {
        case .curatedSource(let curatedModel):
            // The same file a curated row installs: offer the pinned catalog entry, so it verifies
            // against the reviewed commit and shares that row's transfer state.
            return .available(curatedModel)
        case .otherSource(let curatedDisplayName):
            return .unavailable(
                reason: "Same filename as Cotabby's \(curatedDisplayName) model, so it can't be installed from this repository."
            )
        case .notCurated:
            break
        }

        // Fail closed: without the LFS oid there is no SHA-256 to verify the bytes against.
        guard let lfs = file.lfs, ModelFileValidator.isSHA256Hex(lfs.oid) else {
            return .unavailable(reason: "Hugging Face lists no checksum for this file, so Cotabby can't verify it.")
        }
        guard let url = file.downloadURL(repoId: repoId) else {
            return .unavailable(reason: "Cotabby couldn't build a download link for this file.")
        }

        // HuggingFace repo paths can include subdirectories (e.g. "gguf/model-Q4.gguf").
        // Use only the leaf filename so the download lands flat in Cotabby's model directory.
        let leafFilename = (file.path as NSString).lastPathComponent
        return .available(
            DownloadableRuntimeModel(
                filename: leafFilename,
                displayName: leafFilename,
                downloadURL: url,
                approximateSizeInGigabytes: file.sizeInGigabytes,
                expectedSizeBytes: lfs.size,
                sha256: lfs.oid.lowercased()
            )
        )
    }
}
