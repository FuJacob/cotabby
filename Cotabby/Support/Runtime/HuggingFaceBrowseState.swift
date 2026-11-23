import Foundation

/// The Hugging Face browse flow as one value: a search (with its pagination) and the repository
/// whose files are expanded underneath it.
///
/// Pagination only exists inside `.results` and the selected repository only exists inside a
/// non-idle detail state, so a new search or a failure cannot leave a stale "has more" flag or a
/// stale selection behind. Completion transitions check that the flow is still waiting for that
/// exact answer, which makes a late response for a superseded request a no-op.
struct HuggingFaceBrowseState: Equatable {
    /// Whether another page can be requested for the current result list.
    enum Page: Equatable {
        case exhausted
        case hasMore
        case loadingMore
    }

    enum SearchState: Equatable {
        case idle
        case searching
        case results([HFModelSearchResult], page: Page)
        case noResults
        case failed(String)
    }

    enum DetailState: Equatable {
        case idle
        case loading(repoId: String)
        case loaded(repoId: String, ggufFiles: [HFRepoFile])
        case failed(repoId: String, message: String)
    }

    static let pageSize = 20

    private(set) var search: SearchState = .idle
    private(set) var detail: DetailState = .idle

    // MARK: - Queries

    var hasMoreResults: Bool {
        switch search {
        case .results(_, page: .hasMore), .results(_, page: .loadingMore):
            return true
        case .idle, .searching, .results(_, page: .exhausted), .noResults, .failed:
            return false
        }
    }

    var isLoadingMore: Bool {
        if case .results(_, page: .loadingMore) = search {
            return true
        }
        return false
    }

    var selectedRepoId: String? {
        switch detail {
        case .idle:
            return nil
        case .loading(let repoId), .loaded(let repoId, _), .failed(let repoId, _):
            return repoId
        }
    }

    /// A page shorter than the page size is the last one; the API has no total count to consult.
    static func page(afterReceiving count: Int) -> Page {
        count >= pageSize ? .hasMore : .exhausted
    }

    // MARK: - Search

    /// A new search replaces the result list, so the expanded repository goes with it.
    mutating func beginSearch() {
        search = .searching
        detail = .idle
    }

    mutating func finishSearch(_ results: [HFModelSearchResult]) {
        guard search == .searching else {
            return
        }
        search = results.isEmpty
            ? .noResults
            : .results(results, page: Self.page(afterReceiving: results.count))
    }

    mutating func failSearch(_ message: String) {
        guard search == .searching else {
            return
        }
        search = .failed(message)
    }

    /// Returns the offset of the next page, or nil when no further page may be requested now.
    mutating func beginLoadMore() -> Int? {
        guard case .results(let results, page: .hasMore) = search else {
            return nil
        }
        search = .results(results, page: .loadingMore)
        return results.count
    }

    mutating func finishLoadMore(_ nextPage: [HFModelSearchResult]) {
        guard case .results(let results, page: .loadingMore) = search else {
            return
        }
        search = .results(results + nextPage, page: Self.page(afterReceiving: nextPage.count))
    }

    mutating func failLoadMore(_ message: String) {
        guard case .results(_, page: .loadingMore) = search else {
            return
        }
        search = .failed(message)
    }

    // MARK: - Detail

    mutating func beginDetail(repoId: String) {
        detail = .loading(repoId: repoId)
    }

    /// Keeps only GGUF files, in a stable human-friendly order. A repository without any is a
    /// failure rather than an empty list, because there is nothing the user can download from it.
    mutating func finishDetail(repoId: String, files: [HFRepoFile]) {
        guard detail == .loading(repoId: repoId) else {
            return
        }
        let ggufFiles = files
            .filter(\.isGGUF)
            .sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        detail = ggufFiles.isEmpty
            ? .failed(repoId: repoId, message: "No GGUF files found in this repository.")
            : .loaded(repoId: repoId, ggufFiles: ggufFiles)
    }

    mutating func failDetail(repoId: String, message: String) {
        guard detail == .loading(repoId: repoId) else {
            return
        }
        detail = .failed(repoId: repoId, message: message)
    }

    mutating func collapseDetail() {
        detail = .idle
    }
}
