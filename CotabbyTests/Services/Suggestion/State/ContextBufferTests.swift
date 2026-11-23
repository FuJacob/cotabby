import CoreGraphics
import XCTest
@testable import Cotabby

/// Tests for the focused-context generation buffer.
///
/// `ContextBuffer` is a small type, but it protects a major async invariant: old model results
/// must not be applied after the user changes fields or text.
@MainActor
final class ContextBufferTests: XCTestCase {
    private func makeBuffer() -> ContextBuffer {
        TestLifetime.retain(ContextBuffer())
    }

    func test_materialize_assignsFirstGenerationAndStoresCurrentContext() {
        let buffer = makeBuffer()
        let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello")

        let context = buffer.materialize(from: snapshot)

        XCTAssertEqual(context.generation, 1)
        XCTAssertEqual(buffer.currentContext, context)
    }

    /// AX hands out a fresh element wrapper for the same field on many polls; that churn alone must
    /// not retire an in-flight suggestion for text that never changed.
    func test_materialize_keepsGenerationForIdenticalProcessAndContent() {
        let buffer = makeBuffer()
        let first = buffer.materialize(
            from: CotabbyTestFixtures.focusedInputSnapshot(
                processIdentifier: 123,
                elementIdentifier: "field-a",
                precedingText: "Hello"
            )
        )
        let second = buffer.materialize(
            from: CotabbyTestFixtures.focusedInputSnapshot(
                processIdentifier: 123,
                elementIdentifier: "field-b",
                precedingText: "Hello"
            )
        )

        XCTAssertEqual(second.generation, first.generation)
    }

    func test_materialize_incrementsGenerationWhenContentChanges() {
        let buffer = makeBuffer()
        let first = buffer.materialize(from: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello"))
        let second = buffer.materialize(from: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello!"))

        XCTAssertEqual(second.generation, first.generation + 1)
    }

    func test_materialize_incrementsGenerationWhenProcessChanges() {
        let buffer = makeBuffer()
        let first = buffer.materialize(
            from: CotabbyTestFixtures.focusedInputSnapshot(processIdentifier: 123)
        )
        let second = buffer.materialize(
            from: CotabbyTestFixtures.focusedInputSnapshot(processIdentifier: 456)
        )

        XCTAssertEqual(second.generation, first.generation + 1)
    }

    func test_clearDropsCurrentContextAndAdvancesFutureGeneration() {
        let buffer = makeBuffer()
        let first = buffer.materialize(from: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello"))

        buffer.clear()

        XCTAssertNil(buffer.currentContext)
        let second = buffer.materialize(from: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello"))
        XCTAssertGreaterThan(second.generation, first.generation)
    }

    // MARK: - Session navigation

    func test_identicalDraftInAnotherSessionAdvancesGenerationAndPredictionCacheKey() {
        let buffer = makeBuffer()
        let first = buffer.materialize(from: CotabbyTestFixtures.focusedInputSnapshot())
        let navigated = buffer.materialize(from: CotabbyTestFixtures.focusedInputSnapshot(focusChangeSequence: 2))
        XCTAssertGreaterThan(navigated.generation, first.generation)
        XCTAssertNotEqual(first.suggestionSessionIdentityKey, navigated.suggestionSessionIdentityKey)
        XCTAssertEqual(first.focusedInputIdentityKey, navigated.focusedInputIdentityKey, "Font geometry remains stable")
    }

    func test_surfaceChangeRejectsStaleGenerationEvenBeforeSequenceChanges() {
        let buffer = makeBuffer()
        let first = buffer.materialize(from: CotabbyTestFixtures.focusedInputSnapshot(windowTitle: "This chat"))
        let navigated = buffer.materialize(from: CotabbyTestFixtures.focusedInputSnapshot(windowTitle: "Other chat"))
        XCTAssertGreaterThan(navigated.generation, first.generation)
    }

    /// A poll whose title read timed out is the same session: bumping the generation for it would
    /// retire an in-flight suggestion for text that never changed.
    func test_unreadableSurfaceFactKeepsGeneration() {
        let buffer = makeBuffer()
        let first = buffer.materialize(from: CotabbyTestFixtures.focusedInputSnapshot(windowTitle: "This chat"))
        let blankRead = buffer.materialize(from: CotabbyTestFixtures.focusedInputSnapshot())
        let readable = buffer.materialize(from: CotabbyTestFixtures.focusedInputSnapshot(windowTitle: "This chat"))
        XCTAssertEqual(first.generation, blankRead.generation)
        XCTAssertEqual(first.generation, readable.generation)
    }
}
