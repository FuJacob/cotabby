import XCTest
@testable import Cotabby

/// Tests for the pure onboarding flow model: the persisted step numbering, the transition graph the
/// Back/Continue footer follows, and the progress indices. `OnboardingProgress` persists raw values
/// as the wizard's resume point, so several of these pin the numbering scheme itself; if one fails
/// because steps were reordered or inserted, the progress key must move to a fresh name at the same
/// time.
final class OnboardingFlowStepTests: XCTestCase {
    func test_rawValues_pinThePersistedNumberingScheme() {
        // These exact indices are what `cotabbyOnboardingProgressStep2` stores on disk.
        XCTAssertEqual(WelcomeStep.welcome.rawValue, 0)
        XCTAssertEqual(WelcomeStep.permissions.rawValue, 1)
        XCTAssertEqual(WelcomeStep.template.rawValue, 2)
        XCTAssertEqual(WelcomeStep.personalize.rawValue, 3)
        XCTAssertEqual(WelcomeStep.keybind.rawValue, 4)
        XCTAssertEqual(WelcomeStep.done.rawValue, 5)
        XCTAssertEqual(WelcomeStep.allCases.count, 6)
    }

    func test_next_walksTheFlowInOrderAndStopsAtDone() {
        var visited: [WelcomeStep] = []
        var step: WelcomeStep? = .welcome
        while let current = step {
            visited.append(current)
            step = current.next
        }

        XCTAssertEqual(visited, [.welcome, .permissions, .template, .personalize, .keybind, .done])
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

    func test_progressIndices_countOnlyTheMiddleStepsInOrder() {
        // Intro and outro sit outside the counted flow; the middle steps number 1...total.
        XCTAssertEqual(WelcomeStep.allCases.map(\.progressIndex), [nil, 1, 2, 3, 4, nil])
        XCTAssertEqual(WelcomeStep.allCases.compactMap(\.progressIndex).count, WelcomeStep.totalProgressSteps)
    }
}
