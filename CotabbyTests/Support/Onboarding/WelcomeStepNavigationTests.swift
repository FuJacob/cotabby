import XCTest
@testable import Cotabby

/// Tests for the wizard's transition graph. Back and Continue are derived from step order, so
/// these pin the edges the footer follows.
@MainActor
final class WelcomeStepNavigationTests: XCTestCase {
    func test_next_walksTheFlowInOrderAndStopsAtDone() {
        var visited: [WelcomeStep] = []
        var step: WelcomeStep? = .welcome
        while let current = step {
            visited.append(current)
            step = current.next
        }

        XCTAssertEqual(visited, [.welcome, .permissions, .template, .personalize, .keybind, .done])
        XCTAssertNil(WelcomeStep.done.next)
    }

    func test_previous_isTheInverseOfNext() {
        XCTAssertNil(WelcomeStep.welcome.previous)
        for step in WelcomeStep.allCases {
            if let next = step.next {
                XCTAssertEqual(next.previous, step)
            }
        }
    }

    func test_framingPages_areExactlyTheFirstAndLastSteps() {
        XCTAssertEqual(WelcomeStep.allCases.filter(\.isFramingPage), [.welcome, .done])
    }

    func test_everyCountedStepHasBothABackAndAContinueDestination() {
        // The Back/Continue footer is only drawn for these, and relies on both edges existing.
        for step in WelcomeStep.allCases where !step.isFramingPage {
            XCTAssertNotNil(step.previous, "\(step) needs somewhere for Back to go")
            XCTAssertNotNil(step.next, "\(step) needs somewhere for Continue to go")
            XCTAssertNotNil(step.progressIndex, "\(step) should count toward the progress indicator")
        }
        XCTAssertEqual(WelcomeStep.totalProgressSteps, 4)
    }
}
