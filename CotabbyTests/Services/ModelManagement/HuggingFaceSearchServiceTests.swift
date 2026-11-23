import XCTest
@testable import Cotabby

/// Drives the Hugging Face browse service against stubbed network calls: the pure transitions are
/// covered by `HuggingFaceBrowseStateTests`; these pin that the service requests the right page,
/// publishes the answer, and drops the answer of a request it superseded or cancelled.
@MainActor
final class HuggingFaceSearchServiceTests: XCTestCase {
    func test_search_ignoresBlankQueries() {
        let service = makeService()

        for blank in ["", "   ", "\t"] {
            service.searchQuery = blank
            service.search()
            XCTAssertEqual(service.searchState, .idle, "Blank query \"\(blank)\" must not start a search")
        }
    }

    func test_loadMore_isNoOpWithoutMoreResults() {
        let service = makeService()
        service.searchQuery = "qwen"

        service.loadMore()

        XCTAssertFalse(service.isLoadingMore)
        XCTAssertEqual(service.searchState, .idle)
    }

    func test_reset_clearsTheQuery() {
        let service = makeService()
        service.searchQuery = "gemma"

        service.reset()

        XCTAssertEqual(service.searchQuery, "")
        XCTAssertEqual(service.searchState, .idle)
    }

    func test_search_requestsTheFirstPageAndPublishesResults() async {
        let stub = HuggingFaceStub()
        stub.pages[0] = Self.results(0..<20)
        let service = makeService(stub)
        service.searchQuery = "  qwen "

        service.search()
        XCTAssertEqual(service.searchState, .searching)
        await settle { service.searchState != .searching }

        XCTAssertEqual(stub.searchRequests, [HuggingFaceStub.SearchRequest(query: "qwen", limit: 20, offset: 0)])
        XCTAssertEqual(service.searchState, .results(Self.results(0..<20), page: .hasMore))
        XCTAssertTrue(service.hasMoreResults)
    }

    func test_search_publishesNoResultsAndFailure() async {
        let stub = HuggingFaceStub()
        let service = makeService(stub)
        service.searchQuery = "nothing"

        service.search()
        await settle { service.searchState != .searching }
        XCTAssertEqual(service.searchState, .noResults)

        stub.searchError = HuggingFaceAPIClient.APIError.rateLimited
        service.search()
        await settle { service.searchState != .searching }
        XCTAssertEqual(service.searchState, .failed("Too many requests — please wait a moment and try again."))
    }

    func test_loadMore_requestsTheNextOffsetAndAppends() async {
        let stub = HuggingFaceStub()
        stub.pages[0] = Self.results(0..<20)
        stub.pages[20] = Self.results(20..<23)
        let service = makeService(stub)
        service.searchQuery = "qwen"
        service.search()
        await settle { service.searchState != .searching }

        service.loadMore()
        XCTAssertTrue(service.isLoadingMore)
        service.loadMore()
        await settle { !service.isLoadingMore }

        XCTAssertEqual(stub.searchRequests.map(\.offset), [0, 20], "A second tap while loading must not request the page twice")
        XCTAssertEqual(service.searchState, .results(Self.results(0..<23), page: .exhausted))
        XCTAssertFalse(service.hasMoreResults)
    }

    func test_newSearch_dropsTheAnswerOfTheSearchItReplaced() async {
        let stub = HuggingFaceStub()
        stub.pages[0] = Self.results(0..<3)
        let service = makeService(stub)
        service.searchQuery = "first"
        stub.holdNextSearch = true
        service.search()
        await settle { stub.heldSearch != nil }

        service.searchQuery = "second"
        stub.pages[0] = Self.results(10..<12)
        service.search()
        stub.releaseHeldSearch(with: Self.results(0..<3))
        await settle { service.searchState != .searching }
        await yieldRepeatedly()

        XCTAssertEqual(service.searchState, .results(Self.results(10..<12), page: .exhausted))
    }

    func test_fetchFiles_selectsTheRepositoryAndPublishesItsGGUFFiles() async {
        let stub = HuggingFaceStub()
        stub.files["org/repo"] = [HFRepoFile(path: "README.md", size: 1), HFRepoFile(path: "model.gguf", size: 2)]
        let service = makeService(stub)

        service.fetchFiles(for: "org/repo")
        XCTAssertEqual(service.selectedRepoId, "org/repo")
        XCTAssertEqual(service.detailState, .loading(repoId: "org/repo"))
        await settle { service.detailState != .loading(repoId: "org/repo") }

        XCTAssertEqual(service.detailState, .loaded(repoId: "org/repo", ggufFiles: [HFRepoFile(path: "model.gguf", size: 2)]))

        service.collapseDetail()
        XCTAssertNil(service.selectedRepoId)
        XCTAssertEqual(service.detailState, .idle)
    }

    func test_newSearch_collapsesTheExpandedRepository() async {
        let stub = HuggingFaceStub()
        stub.pages[0] = Self.results(0..<3)
        stub.files["org/model-1"] = [HFRepoFile(path: "model.gguf", size: 2)]
        let service = makeService(stub)
        service.searchQuery = "qwen"
        service.search()
        await settle { service.searchState != .searching }
        service.fetchFiles(for: "org/model-1")
        await settle { service.detailState != .loading(repoId: "org/model-1") }

        service.search()
        await settle { service.searchState != .searching }

        XCTAssertNil(service.selectedRepoId, "A repository in the new result list must not render as already expanded")
        XCTAssertEqual(service.detailState, .idle)
    }

    func test_reset_clearsResultsAndSelection() async {
        let stub = HuggingFaceStub()
        stub.pages[0] = Self.results(0..<20)
        let service = makeService(stub)
        service.searchQuery = "qwen"
        service.search()
        await settle { service.searchState != .searching }
        service.fetchFiles(for: "org/model-1")

        service.reset()
        await yieldRepeatedly()

        XCTAssertEqual(service.searchQuery, "")
        XCTAssertEqual(service.searchState, .idle)
        XCTAssertEqual(service.detailState, .idle)
        XCTAssertFalse(service.hasMoreResults)
        XCTAssertNil(service.selectedRepoId)
    }

    // MARK: - Helpers

    private static func results(_ range: Range<Int>) -> [HFModelSearchResult] {
        range.map { HFModelSearchResult(id: "org/model-\($0)", downloads: $0, likes: 0) }
    }

    private func makeService(_ providedStub: HuggingFaceStub? = nil) -> HuggingFaceSearchService {
        let stub = providedStub ?? HuggingFaceStub()
        let service = HuggingFaceSearchService(
            searchModels: { query, limit, offset in
                try await stub.search(query: query, limit: limit, offset: offset)
            },
            fetchRepoFiles: { repoId in
                try stub.fetch(repoId: repoId)
            }
        )
        return TestLifetime.retain(service)
    }

    /// The service's request tasks run on the main actor, so yielding lets them advance; the
    /// bound only exists to fail instead of hanging when a transition never happens.
    private func settle(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("The browse state did not settle", file: file, line: line)
    }

    private func yieldRepeatedly() async {
        for _ in 0..<50 {
            await Task.yield()
        }
    }
}

/// Stubbed Hugging Face endpoints. One search can be held open so a test can supersede it.
@MainActor
private final class HuggingFaceStub {
    struct SearchRequest: Equatable {
        let query: String
        let limit: Int
        let offset: Int
    }

    var pages: [Int: [HFModelSearchResult]] = [:]
    var files: [String: [HFRepoFile]] = [:]
    var searchError: Error?
    var holdNextSearch = false
    private(set) var searchRequests: [SearchRequest] = []
    private(set) var heldSearch: CheckedContinuation<[HFModelSearchResult], Never>?

    func search(query: String, limit: Int, offset: Int) async throws -> [HFModelSearchResult] {
        searchRequests.append(SearchRequest(query: query, limit: limit, offset: offset))
        if holdNextSearch {
            holdNextSearch = false
            return await withCheckedContinuation { heldSearch = $0 }
        }
        if let searchError {
            throw searchError
        }
        return pages[offset] ?? []
    }

    func releaseHeldSearch(with results: [HFModelSearchResult]) {
        heldSearch?.resume(returning: results)
        heldSearch = nil
    }

    func fetch(repoId: String) throws -> [HFRepoFile] {
        files[repoId] ?? []
    }
}
