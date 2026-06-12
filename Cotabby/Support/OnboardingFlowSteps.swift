import Foundation

/// File overview:
/// Pure sequencing model for the first-run onboarding wizard: the ordered steps, which of them
/// count toward the progress indicator, and the window size each one prefers. Extracted from
/// `WelcomeView` so the flow's shape is unit-testable without SwiftUI.
///
/// Raw values are persisted by `WelcomeCoordinator` as the wizard's resume point, so reordering or
/// inserting cases is a breaking change for stored progress. If the numbering scheme changes,
/// `WelcomeCoordinator` must move to a fresh UserDefaults key rather than reinterpret old indices
/// (see `onboardingProgressStepKey` there).
enum WelcomeStep: Int, CaseIterable, Comparable, Sendable {
    case welcome
    case permissions
    case template
    case personalize
    case keybind
    case done

    static func < (lhs: WelcomeStep, rhs: WelcomeStep) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The flow is strictly linear, so navigation is derived from case order instead of hand-wired
    /// per step. `nil` past either end keeps the terminal steps terminal.
    var next: WelcomeStep? {
        WelcomeStep(rawValue: rawValue + 1)
    }

    var previous: WelcomeStep? {
        WelcomeStep(rawValue: rawValue - 1)
    }

    /// Number of steps shown in the progress indicator (the middle, non-terminal steps).
    static let totalProgressSteps = 4

    /// 1-based position within the progress indicator, or `nil` for the intro/outro steps that
    /// intentionally sit outside the counted flow.
    var progressIndex: Int? {
        switch self {
        case .welcome, .done:
            return nil
        case .permissions:
            return 1
        case .template:
            return 2
        case .personalize:
            return 3
        case .keybind:
            return 4
        }
    }

    /// Product-chosen window sizes. The coordinator clamps the height to the visible screen, and
    /// the scrolling content absorbs any overflow, so these are targets rather than hard
    /// guarantees. Width is constant across the flow on purpose: the window only ever morphs
    /// vertically between steps, which reads as one calm surface instead of a window that jumps
    /// around in both dimensions.
    var preferredWindowSize: NSSize {
        NSSize(width: WelcomeStep.windowWidth, height: preferredWindowHeight)
    }

    /// Single width shared by every step (see `preferredWindowSize`).
    static let windowWidth: CGFloat = 640

    private var preferredWindowHeight: CGFloat {
        switch self {
        case .welcome:
            return 640
        case .permissions:
            return 600
        case .template:
            return 720
        case .personalize:
            return 620
        case .keybind:
            return 580
        case .done:
            return 740
        }
    }
}
