import XCTest
@testable import Cotabby

/// The local provider's token budget fits what the cleaner accepts, so Longer is not cut off
/// mid-sentence and previewed as if it were finished.
@MainActor
final class LocalRewriteProviderTests: XCTestCase {
    func test_longerGetsRoomForAFullerMessage() {
        let draft = String(repeating: "a", count: 120)
        let longer = LocalRewriteProvider.tokenBudget(RewriteRequest(selection: draft, action: .longer))
        let formal = LocalRewriteProvider.tokenBudget(RewriteRequest(selection: draft, action: .formal))
        // The cleaner lets Longer reach 120 * 8 + 400 = 1,360 characters, about 340 tokens.
        XCTAssertGreaterThanOrEqual(longer, (120 * 8 + 400) / 4)
        XCTAssertEqual(formal, 120 * 3 / 8 + 48)
    }

    func test_budgetIsCapped() {
        let draft = String(repeating: "a", count: 2_000)
        XCTAssertEqual(LocalRewriteProvider.tokenBudget(RewriteRequest(selection: draft, action: .longer)), 800)
        XCTAssertEqual(LocalRewriteProvider.tokenBudget(RewriteRequest(selection: draft, action: .rewrite)), 798)
    }
}
