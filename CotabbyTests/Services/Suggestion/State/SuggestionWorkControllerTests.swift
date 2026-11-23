import CoreGraphics
import XCTest
@testable import Cotabby

/// Tests for async work identity and cancellation.
///
/// The controller gives the coordinator "latest request wins" semantics. That is the protection
/// against older debounce or generation tasks writing stale results after the user keeps typing.
final class SuggestionWorkControllerTests: XCTestCase {
    private var retainedControllers: [SuggestionWorkController] = []

    override func tearDown() {
        runOnMainActor {
            retainedControllers.forEach { $0.cancelAll() }
            retainedControllers.removeAll()
        }
        super.tearDown()
    }

    func test_replaceDebouncedWorkRunsOnlyLatestOperation() {
        let operationRan = expectation(description: "latest debounce runs")
        let recorder = runOnMainActor { WorkRecorder() }
        var firstID: UInt64 = 0
        var secondID: UInt64 = 0

        runOnMainActor {
            let controller = makeController()
            firstID = controller.replaceDebouncedWork(delayMilliseconds: 20) { workID in
                recorder.record(workID)
            }
            secondID = controller.replaceDebouncedWork(delayMilliseconds: 1) { workID in
                recorder.record(workID)
                operationRan.fulfill()
            }
        }

        wait(for: [operationRan], timeout: 1.0)

        runOnMainActor {
            XCTAssertEqual(firstID, 1)
            XCTAssertEqual(secondID, 2)
            XCTAssertEqual(recorder.workIDs, [2])
        }
    }

    func test_cancelAllPreventsPendingDebouncedOperation() {
        let operationRan = expectation(description: "cancelled debounce should not run")
        operationRan.isInverted = true
        var currentWorkID: UInt64 = 0

        runOnMainActor {
            let controller = makeController()
            _ = controller.replaceDebouncedWork(delayMilliseconds: 1) { _ in
                operationRan.fulfill()
            }
            controller.cancelAll()
            currentWorkID = controller.currentWorkID
        }

        wait(for: [operationRan], timeout: 0.1)
        XCTAssertEqual(currentWorkID, 2)
    }

    func test_replaceGenerationWorkRunsForCurrentWorkID() {
        let generationRan = expectation(description: "current generation runs")

        runOnMainActor {
            let controller = makeController()
            let workID = controller.replaceDebouncedWork(delayMilliseconds: 1_000) { _ in }
            controller.replaceGenerationWork(for: workID) {
                generationRan.fulfill()
            }
        }

        wait(for: [generationRan], timeout: 1.0)
    }

    func test_replaceGenerationWorkRejectsStaleWorkID() {
        let generationRan = expectation(description: "stale generation should not run")
        generationRan.isInverted = true

        runOnMainActor {
            let controller = makeController()
            let staleWorkID = controller.replaceDebouncedWork(delayMilliseconds: 1_000) { _ in }
            controller.cancelAll()
            controller.replaceGenerationWork(for: staleWorkID) {
                generationRan.fulfill()
            }
        }

        wait(for: [generationRan], timeout: 0.1)
    }

    @MainActor
    private func makeController() -> SuggestionWorkController {
        let controller = SuggestionWorkController()
        retainedControllers.append(controller)
        return controller
    }
}

@MainActor
private final class WorkRecorder {
    private(set) var workIDs: [UInt64] = []

    func record(_ workID: UInt64) {
        workIDs.append(workID)
    }
}
