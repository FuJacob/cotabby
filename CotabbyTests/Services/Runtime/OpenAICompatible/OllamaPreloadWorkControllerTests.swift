import XCTest
@testable import Cotabby

/// Exercises the concurrency boundary independently from URLSession. The endpoint engine owns this
/// controller for its lifetime; each test supplies short-lived operations that stand in for Ollama's
/// native preload request and records how many actually begin.
@MainActor
final class OllamaPreloadWorkControllerTests: XCTestCase {
    func test_sameModelConcurrentWarmupsShareOneOperationAndAllowLaterRetry() async {
        let controller = OllamaPreloadWorkController()
        let started = expectation(description: "First preload started")
        var invocationCount = 0
        var finishFirst: CheckedContinuation<Void, Never>?

        let first = Task { @MainActor in
            await controller.run(modelName: "model-a") {
                invocationCount += 1
                started.fulfill()
                await withCheckedContinuation { continuation in
                    finishFirst = continuation
                }
            }
        }
        await fulfillment(of: [started], timeout: 1)

        let secondEntered = expectation(description: "Second caller entered the controller")
        let second = Task { @MainActor in
            secondEntered.fulfill()
            await controller.run(modelName: "model-a") {
                invocationCount += 1
            }
        }
        await fulfillment(of: [secondEntered], timeout: 1)
        await Task.yield()
        XCTAssertEqual(invocationCount, 1)

        finishFirst?.resume()
        finishFirst = nil
        await first.value
        await second.value

        await controller.run(modelName: "model-a") {
            invocationCount += 1
        }
        XCTAssertEqual(invocationCount, 2, "Completed flights must not block later retry attempts")
    }

    func test_differentModelsMayPreloadIndependently() async {
        let controller = OllamaPreloadWorkController()
        let bothStarted = expectation(description: "Both model preloads started")
        bothStarted.expectedFulfillmentCount = 2
        var startedModels = Set<String>()
        var continuations: [CheckedContinuation<Void, Never>] = []

        let first = Task { @MainActor in
            await controller.run(modelName: "model-a") {
                startedModels.insert("model-a")
                bothStarted.fulfill()
                await withCheckedContinuation { continuations.append($0) }
            }
        }
        let second = Task { @MainActor in
            await controller.run(modelName: "model-b") {
                startedModels.insert("model-b")
                bothStarted.fulfill()
                await withCheckedContinuation { continuations.append($0) }
            }
        }

        await fulfillment(of: [bothStarted], timeout: 1)
        XCTAssertEqual(startedModels, Set(["model-a", "model-b"]))
        continuations.forEach { $0.resume() }
        continuations.removeAll()
        await first.value
        await second.value
    }
}
