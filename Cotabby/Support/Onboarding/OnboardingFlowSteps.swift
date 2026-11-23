import Foundation

/// File overview:
/// Pure sequencing model for the first-run onboarding wizard: the ordered steps, the edges between
/// them, which of them count toward the progress indicator, and the window size each one prefers.
/// Extracted from `WelcomeView` so the flow's shape is unit-testable without SwiftUI.
///
/// The flow is strictly linear, so case order is the whole transition graph: Back and Continue are
/// `previous` and `next`. A view never names a neighbouring step, which means inserting or
/// reordering a step is a change to this enum alone.
///
/// Raw values are persisted as the wizard's resume point (see `OnboardingProgress`), so reordering
/// or inserting cases is a breaking change for stored progress. If the numbering scheme changes,
/// `OnboardingProgress.furthestStepKey` must move to a fresh UserDefaults key rather than
/// reinterpret old indices.
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

    /// The step Back returns to, or `nil` on the first step.
    var previous: WelcomeStep? {
        WelcomeStep(rawValue: rawValue - 1)
    }

    /// The step Continue advances to, or `nil` on the last step.
    var next: WelcomeStep? {
        WelcomeStep(rawValue: rawValue + 1)
    }

    /// The intro and outro pages frame the flow rather than being steps in it: they carry their
    /// own single call-to-action instead of the Back/Continue footer and sit outside the progress
    /// indicator.
    var isFramingPage: Bool {
        previous == nil || next == nil
    }

    /// The steps the progress indicator counts, in order.
    private static let progressSteps = allCases.filter { !$0.isFramingPage }

    /// Number of steps shown in the progress indicator.
    static var totalProgressSteps: Int {
        progressSteps.count
    }

    /// 1-based position within the progress indicator, or `nil` for the framing pages.
    var progressIndex: Int? {
        Self.progressSteps.firstIndex(of: self).map { $0 + 1 }
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
