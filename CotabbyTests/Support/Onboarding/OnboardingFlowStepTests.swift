import XCTest
@testable import Cotabby

/// Tests for the pure onboarding flow model: step ordering, linear navigation, progress indices,
/// and window sizing. `WelcomeCoordinator` persists raw values as the wizard's resume point, so
/// several of these pin the numbering scheme itself; if one fails because steps were reordered or
/// inserted, the coordinator's progress key must move to a fresh name at the same time.
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

    func test_comparable_followsCaseOrder() {
        XCTAssertLessThan(WelcomeStep.welcome, .permissions)
        XCTAssertLessThan(WelcomeStep.keybind, .done)
        XCTAssertFalse(WelcomeStep.done < .welcome)
    }

    func test_navigation_isLinearAndTerminalAtBothEnds() {
        // Every step's next is the following case; every step's previous is the prior one.
        for (index, step) in WelcomeStep.allCases.enumerated() {
            if index + 1 < WelcomeStep.allCases.count {
                XCTAssertEqual(step.next, WelcomeStep.allCases[index + 1])
            }
            if index > 0 {
                XCTAssertEqual(step.previous, WelcomeStep.allCases[index - 1])
            }
        }
        XCTAssertNil(WelcomeStep.welcome.previous)
        XCTAssertNil(WelcomeStep.done.next)
    }

    func test_progressIndices_coverOneThroughTotalExactlyOnce() {
        let indices = WelcomeStep.allCases.compactMap(\.progressIndex)

        XCTAssertEqual(indices, Array(1...WelcomeStep.totalProgressSteps))
    }

    func test_terminalSteps_sitOutsideTheCountedFlow() {
        XCTAssertNil(WelcomeStep.welcome.progressIndex)
        XCTAssertNil(WelcomeStep.done.progressIndex)
    }

    func test_windowWidth_isConstantAcrossEveryStep() {
        // The redesign's "one calm surface" invariant: the window only ever morphs vertically.
        for step in WelcomeStep.allCases {
            XCTAssertEqual(step.preferredWindowSize.width, WelcomeStep.windowWidth)
        }
    }

    func test_windowHeights_areAlwaysPositive() {
        for step in WelcomeStep.allCases {
            XCTAssertGreaterThan(step.preferredWindowSize.height, 0)
        }
    }

    func test_resumeFallback_outOfRangeIndicesFailToInitialize() {
        // `WelcomeView` falls back to `.welcome` when the persisted index doesn't resolve; this
        // pins the init behavior that fallback relies on (stale or corrupt values return nil).
        XCTAssertNil(WelcomeStep(rawValue: -1))
        XCTAssertNil(WelcomeStep(rawValue: WelcomeStep.allCases.count))
        XCTAssertEqual(WelcomeStep(rawValue: 0), .welcome)
    }
}
