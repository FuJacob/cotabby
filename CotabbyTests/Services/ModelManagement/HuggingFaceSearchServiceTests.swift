import XCTest
@testable import Cotabby

/// Locks the Hugging Face browse state machine's local transitions: a blank query never reaches
/// the network, pagination is gated on a previous page, and reset clears the query. Paths that call
/// the public Hugging Face API are deliberately not exercised here.
@MainActor
final class HuggingFaceSearchServiceTests: XCTestCase {
    /// Production @MainActor classes can crash the app-hosted runner when deallocated (back-deploy
    /// executor shim); quarantine them for the process lifetime.
    private static var retained: [AnyObject] = []

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

    private func makeService() -> HuggingFaceSearchService {
        let service = HuggingFaceSearchService()
        Self.retained.append(service)
        return service
    }
}
