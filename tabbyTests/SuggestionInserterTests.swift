import ApplicationServices
import XCTest
@testable import tabby

@MainActor
final class SuggestionInserterTests: XCTestCase {
    func test_replacePreviousCharacters_buffersWholePlanBeforeSuppression() {
        var operationLog: [String] = []
        let inserter = SuggestionInserter(
            registerSuppression: { count in
                operationLog.append("register:\(count)")
            },
            makeKeyboardEvent: { keyCode, keyDown in
                operationLog.append("make:\(keyCode):\(keyDown ? "down" : "up")")
                return CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown)
            },
            postEvent: { _ in
                operationLog.append("post")
            }
        )

        XCTAssertTrue(inserter.replacePreviousCharacters(count: 2, with: "the"))

        let registerIndex = try! XCTUnwrap(operationLog.firstIndex(of: "register:3"))
        XCTAssertEqual(registerIndex, 6)
        XCTAssertTrue(operationLog[..<registerIndex].allSatisfy { $0.hasPrefix("make:") })
        XCTAssertTrue(operationLog[(registerIndex + 1)...].allSatisfy { $0 == "post" })
        XCTAssertEqual(operationLog[(registerIndex + 1)...].count, 6)
    }

    func test_replacePreviousCharacters_doesNotRegisterSuppressionWhenBackspaceEventCreationFails() {
        var didRegisterSuppression = false
        var postCount = 0
        var creationCallCount = 0
        let inserter = SuggestionInserter(
            registerSuppression: { _ in
                didRegisterSuppression = true
            },
            makeKeyboardEvent: { keyCode, keyDown in
                creationCallCount += 1
                guard creationCallCount != 3 else {
                    return nil
                }
                return CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown)
            },
            postEvent: { _ in
                postCount += 1
            }
        )

        XCTAssertFalse(inserter.replacePreviousCharacters(count: 2, with: "the"))
        XCTAssertFalse(didRegisterSuppression)
        XCTAssertEqual(postCount, 0)
        XCTAssertEqual(inserter.lastErrorMessage, "Unable to create a synthetic Backspace event.")
    }

    func test_replacePreviousCharacters_doesNotRegisterSuppressionWhenUnicodeEventCreationFails() {
        var didRegisterSuppression = false
        var postCount = 0
        var creationCallCount = 0
        let inserter = SuggestionInserter(
            registerSuppression: { _ in
                didRegisterSuppression = true
            },
            makeKeyboardEvent: { keyCode, keyDown in
                creationCallCount += 1
                guard creationCallCount != 5 else {
                    return nil
                }
                return CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown)
            },
            postEvent: { _ in
                postCount += 1
            }
        )

        XCTAssertFalse(inserter.replacePreviousCharacters(count: 2, with: "the"))
        XCTAssertFalse(didRegisterSuppression)
        XCTAssertEqual(postCount, 0)
        XCTAssertEqual(inserter.lastErrorMessage, "Unable to create a synthetic keyboard event.")
    }
}
