import CoreGraphics
import XCTest
@testable import Cotabby

/// Tests for the focused-context generation buffer.
///
/// `ContextBuffer` is a small type, but it protects a major async invariant: old model results
/// must not be applied after the user changes fields or text.
final class ContextBufferTests: XCTestCase {
    func test_materialize_assignsFirstGenerationAndStoresCurrentContext() {
        runOnMainActor {
            let buffer = makeBuffer()
            let snapshot = CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello")

            let context = buffer.materialize(from: snapshot)

            XCTAssertEqual(context.generation, 1)
            XCTAssertEqual(buffer.currentContext, context)
        }
    }

    func test_materialize_keepsGenerationForIdenticalProcessAndContent() {
        runOnMainActor {
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
    }

    func test_materialize_incrementsGenerationWhenContentChanges() {
        runOnMainActor {
            let buffer = makeBuffer()
            let first = buffer.materialize(from: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello"))
            let second = buffer.materialize(from: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello!"))

            XCTAssertEqual(second.generation, first.generation + 1)
        }
    }

    func test_materialize_incrementsGenerationWhenProcessChanges() {
        runOnMainActor {
            let buffer = makeBuffer()
            let first = buffer.materialize(
                from: CotabbyTestFixtures.focusedInputSnapshot(processIdentifier: 123)
            )
            let second = buffer.materialize(
                from: CotabbyTestFixtures.focusedInputSnapshot(processIdentifier: 456)
            )

            XCTAssertEqual(second.generation, first.generation + 1)
        }
    }

    func test_clearDropsCurrentContextAndAdvancesFutureGeneration() {
        runOnMainActor {
            let buffer = makeBuffer()
            let first = buffer.materialize(from: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello"))

            buffer.clear()

            XCTAssertNil(buffer.currentContext)
            let second = buffer.materialize(from: CotabbyTestFixtures.focusedInputSnapshot(precedingText: "Hello"))
            XCTAssertGreaterThan(second.generation, first.generation)
        }
    }

    @MainActor
    private func makeBuffer() -> ContextBuffer {
        TestLifetime.retain(ContextBuffer())
    }
}
