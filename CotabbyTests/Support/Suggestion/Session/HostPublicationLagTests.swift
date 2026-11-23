import XCTest
@testable import Cotabby

/// Verifies the transitions of the publication lag that are not reconciliation itself: how a
/// typed-through character moves each state, and when typed-input tolerance retires.
@MainActor
final class HostPublicationLagTests: XCTestCase {
    private var session: ActiveSuggestionSession {
        CotabbyTestFixtures.activeSession(fullText: " world again", basePrecedingText: "Hello")
    }

    func test_typingFromSettledOpensAWindowOverTheTypedCharacters() {
        let advanced = session.advancing(by: 2)

        XCTAssertEqual(
            HostPublicationLag.settled.afterTypedAdvance(from: session, to: advanced),
            .awaitingTypedInput(0..<2)
        )
    }

    func test_furtherTypingWidensTheWindowFromItsFirstUnpublishedCharacter() {
        let first = session.advancing(by: 1)
        let second = first.advancing(by: 3)

        XCTAssertEqual(
            HostPublicationLag.awaitingTypedInput(0..<1).afterTypedAdvance(from: first, to: second),
            .awaitingTypedInput(0..<4)
        )
    }

    func test_typingAfterASyntheticInsertKeepsTheInsertWindowAimedAtTheNewPrefix() {
        let accepted = session.advancing(by: 6)
        let typed = accepted.advancing(by: 1)

        XCTAssertEqual(
            HostPublicationLag.awaitingSyntheticInsert(consumedCount: 6).afterTypedAdvance(from: accepted, to: typed),
            .awaitingSyntheticInsert(consumedCount: 7)
        )
    }

    func test_typingThroughTheWholeSuggestionOpensNoTypedWindow() {
        let exhausted = session.advancing(by: session.fullText.count)

        XCTAssertEqual(HostPublicationLag.settled.afterTypedAdvance(from: session, to: exhausted), .settled)
        XCTAssertEqual(
            HostPublicationLag.awaitingTypedInput(0..<2).afterTypedAdvance(from: session.advancing(by: 2), to: exhausted),
            .awaitingTypedInput(0..<2)
        )
    }

    func test_typedWindowRetiresOnceTheFieldContainsTheTypedPrefix() {
        let typed = session.advancing(by: 2)
        let lag = HostPublicationLag.awaitingTypedInput(0..<2)

        let stale = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello ")
        XCTAssertEqual(lag.retiringPublishedTypedInput(in: stale, session: typed), lag)

        let published = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello w")
        XCTAssertEqual(lag.retiringPublishedTypedInput(in: published, session: typed), .settled)
    }

    func test_publicationOfTypedTextDoesNotRetireASyntheticInsertWindow() {
        let accepted = session.advancing(by: 6)
        let lag = HostPublicationLag.awaitingSyntheticInsert(consumedCount: 6)
        let published = CotabbyTestFixtures.focusedInputContext(precedingText: "Hello world")

        XCTAssertEqual(lag.retiringPublishedTypedInput(in: published, session: accepted), lag)
    }
}
