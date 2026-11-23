import XCTest
@testable import Cotabby

/// Transition tests for the Hugging Face browse flow: search, pagination, and repository detail,
/// including the late-response cases a superseded request produces.
final class HuggingFaceBrowseStateTests: XCTestCase {
    private func results(_ range: Range<Int>) -> [HFModelSearchResult] {
        range.map { HFModelSearchResult(id: "org/model-\($0)", downloads: $0, likes: 0) }
    }

    private var fullPage: [HFModelSearchResult] { results(0..<HuggingFaceBrowseState.pageSize) }

    private func stateWithResults(_ results: [HFModelSearchResult]) -> HuggingFaceBrowseState {
        var state = HuggingFaceBrowseState()
        state.beginSearch()
        state.finishSearch(results)
        return state
    }

    func test_pageRule_aShortPageIsTheLastOne() {
        XCTAssertEqual(HuggingFaceBrowseState.page(afterReceiving: 0), .exhausted)
        XCTAssertEqual(HuggingFaceBrowseState.page(afterReceiving: HuggingFaceBrowseState.pageSize - 1), .exhausted)
        XCTAssertEqual(HuggingFaceBrowseState.page(afterReceiving: HuggingFaceBrowseState.pageSize), .hasMore)
        XCTAssertEqual(HuggingFaceBrowseState.page(afterReceiving: HuggingFaceBrowseState.pageSize + 5), .hasMore)
    }

    // MARK: - Search

    func test_search_resultsNoResultsAndFailure() {
        var state = HuggingFaceBrowseState()
        state.beginSearch()
        XCTAssertEqual(state.search, .searching)

        var withResults = state
        withResults.finishSearch(results(0..<3))
        XCTAssertEqual(withResults.search, .results(results(0..<3), page: .exhausted))
        XCTAssertFalse(withResults.hasMoreResults)

        var empty = state
        empty.finishSearch([])
        XCTAssertEqual(empty.search, .noResults)

        var failed = state
        failed.failSearch("offline")
        XCTAssertEqual(failed.search, .failed("offline"))
    }

    func test_search_aFullPageOffersMore() {
        let state = stateWithResults(fullPage)

        XCTAssertEqual(state.search, .results(fullPage, page: .hasMore))
        XCTAssertTrue(state.hasMoreResults)
        XCTAssertFalse(state.isLoadingMore)
    }

    func test_search_completionIsIgnoredUnlessASearchIsInFlight() {
        var idle = HuggingFaceBrowseState()
        idle.finishSearch(results(0..<3))
        idle.failSearch("offline")
        XCTAssertEqual(idle.search, .idle)

        var settled = stateWithResults(results(0..<3))
        settled.failSearch("late failure")
        settled.finishSearch(results(5..<6))
        XCTAssertEqual(settled.search, .results(results(0..<3), page: .exhausted))
    }

    func test_beginSearch_dropsPaginationAndTheExpandedRepository() {
        var state = stateWithResults(fullPage)
        XCTAssertNotNil(state.beginLoadMore())
        state.beginDetail(repoId: "org/model-1")

        state.beginSearch()

        XCTAssertEqual(state.search, .searching)
        XCTAssertFalse(state.hasMoreResults)
        XCTAssertFalse(state.isLoadingMore)
        XCTAssertEqual(state.detail, .idle)
        XCTAssertNil(state.selectedRepoId)
    }

    func test_failedSearch_leavesNoStalePagination() {
        var state = stateWithResults(fullPage)
        state.beginSearch()
        state.failSearch("offline")

        XCTAssertFalse(state.hasMoreResults)
        XCTAssertNil(state.beginLoadMore())
    }

    // MARK: - Pagination

    func test_loadMore_appendsAndStopsAtAShortPage() {
        var state = stateWithResults(fullPage)

        XCTAssertEqual(state.beginLoadMore(), HuggingFaceBrowseState.pageSize)
        XCTAssertTrue(state.isLoadingMore)
        XCTAssertTrue(state.hasMoreResults, "The button stays visible, showing its spinner, while a page loads")

        let nextPage = results(20..<25)
        state.finishLoadMore(nextPage)
        XCTAssertEqual(state.search, .results(fullPage + nextPage, page: .exhausted))
        XCTAssertNil(state.beginLoadMore())
    }

    func test_loadMore_aFullNextPageOffersAnother() {
        var state = stateWithResults(fullPage)
        XCTAssertNotNil(state.beginLoadMore())
        state.finishLoadMore(results(20..<40))

        XCTAssertEqual(state.beginLoadMore(), 40)
    }

    func test_loadMore_isRefusedWithoutMoreResultsOrWhileOneIsLoading() {
        var idle = HuggingFaceBrowseState()
        XCTAssertNil(idle.beginLoadMore())

        var searching = HuggingFaceBrowseState()
        searching.beginSearch()
        XCTAssertNil(searching.beginLoadMore())

        var exhausted = stateWithResults(results(0..<3))
        XCTAssertNil(exhausted.beginLoadMore())

        var loading = stateWithResults(fullPage)
        XCTAssertNotNil(loading.beginLoadMore())
        XCTAssertNil(loading.beginLoadMore())
    }

    func test_loadMore_failureReplacesTheResults() {
        var state = stateWithResults(fullPage)
        XCTAssertNotNil(state.beginLoadMore())
        state.failLoadMore("offline")

        XCTAssertEqual(state.search, .failed("offline"))
        XCTAssertFalse(state.hasMoreResults)
    }

    func test_loadMore_completionIsIgnoredAfterANewSearchStarted() {
        var state = stateWithResults(fullPage)
        XCTAssertNotNil(state.beginLoadMore())
        state.beginSearch()

        state.finishLoadMore(results(20..<25))
        state.failLoadMore("late failure")

        XCTAssertEqual(state.search, .searching)
    }

    // MARK: - Detail

    func test_detail_keepsOnlyGGUFFilesInNaturalOrder() {
        var state = HuggingFaceBrowseState()
        state.beginDetail(repoId: "org/repo")
        XCTAssertEqual(state.detail, .loading(repoId: "org/repo"))
        XCTAssertEqual(state.selectedRepoId, "org/repo")

        state.finishDetail(repoId: "org/repo", files: [
            HFRepoFile(path: "model-Q10.gguf", size: 3),
            HFRepoFile(path: "README.md", size: 1),
            HFRepoFile(path: "model-Q4.GGUF", size: 2)
        ])

        XCTAssertEqual(
            state.detail,
            .loaded(repoId: "org/repo", ggufFiles: [
                HFRepoFile(path: "model-Q4.GGUF", size: 2),
                HFRepoFile(path: "model-Q10.gguf", size: 3)
            ])
        )
        XCTAssertEqual(state.selectedRepoId, "org/repo")
    }

    func test_detail_aRepositoryWithoutGGUFFilesFails() {
        var state = HuggingFaceBrowseState()
        state.beginDetail(repoId: "org/repo")
        state.finishDetail(repoId: "org/repo", files: [HFRepoFile(path: "README.md", size: 1)])

        XCTAssertEqual(state.detail, .failed(repoId: "org/repo", message: "No GGUF files found in this repository."))
        XCTAssertEqual(state.selectedRepoId, "org/repo", "The failed row stays expanded to show its message")
    }

    func test_detail_failureKeepsTheRepositorySelected() {
        var state = HuggingFaceBrowseState()
        state.beginDetail(repoId: "org/repo")
        state.failDetail(repoId: "org/repo", message: "offline")

        XCTAssertEqual(state.detail, .failed(repoId: "org/repo", message: "offline"))
    }

    func test_detail_aResponseForAnotherRepositoryIsIgnored() {
        var state = HuggingFaceBrowseState()
        state.beginDetail(repoId: "org/first")
        state.beginDetail(repoId: "org/second")

        state.finishDetail(repoId: "org/first", files: [HFRepoFile(path: "a.gguf", size: 1)])
        state.failDetail(repoId: "org/first", message: "late failure")

        XCTAssertEqual(state.detail, .loading(repoId: "org/second"))
    }

    func test_detail_aResponseAfterCollapseIsIgnored() {
        var state = HuggingFaceBrowseState()
        state.beginDetail(repoId: "org/repo")
        state.collapseDetail()
        XCTAssertNil(state.selectedRepoId)

        state.finishDetail(repoId: "org/repo", files: [HFRepoFile(path: "a.gguf", size: 1)])

        XCTAssertEqual(state.detail, .idle)
    }

    func test_detail_doesNotDisturbTheSearchResults() {
        var state = stateWithResults(fullPage)
        state.beginDetail(repoId: "org/model-1")
        state.collapseDetail()

        XCTAssertEqual(state.search, .results(fullPage, page: .hasMore))
    }
}
