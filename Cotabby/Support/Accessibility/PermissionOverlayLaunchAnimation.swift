import CoreGraphics
import Foundation

/// The fly-in that carries the guided-permission helper from the onboarding control it was
/// launched from into its place over System Settings.
///
/// A value exists only while the animation is running, so "animating" cannot disagree with the
/// frames and start time it needs. The math is pure: the window controller supplies a clock
/// reading and applies the returned frame, which keeps timing and path testable without a window.
nonisolated struct PermissionOverlayLaunchAnimation: Equatable {
    nonisolated enum Step: Equatable {
        case inFlight(alpha: CGFloat, frame: CGRect)
        /// The animation is over; the overlay belongs at `frame`, fully opaque.
        case finished(frame: CGRect)
    }

    static let duration: TimeInterval = 0.72
    static let initialAlpha: CGFloat = 0.9
    private static let springResponse: Double = 0.72

    let startTime: TimeInterval
    let fromFrame: CGRect
    /// Where the overlay lands. Mutable because System Settings can move while the overlay is
    /// still in flight; retargeting bends the remaining path instead of snapping at the end.
    var toFrame: CGRect

    func step(at now: TimeInterval) -> Step {
        let elapsed = max(0, now - startTime)
        guard elapsed < Self.duration else {
            return .finished(frame: toFrame)
        }
        let progress = Self.springProgress(at: elapsed)
        return .inFlight(
            alpha: Self.initialAlpha + ((1 - Self.initialAlpha) * progress),
            frame: Self.curvedFrame(from: fromFrame, to: toFrame, progress: progress)
        )
    }

    /// A critically damped spring, so the overlay feels deliberate rather than floaty.
    private static func springProgress(at elapsed: TimeInterval) -> CGFloat {
        let omega = (2 * Double.pi) / springResponse
        let progress = 1 - exp(-omega * elapsed) * (1 + (omega * elapsed))
        return min(max(progress, 0), 1)
    }

    /// Uses a quadratic Bezier path so the helper appears to travel from the onboarding control
    /// into the destination settings pane, rather than simply scaling in place.
    private static func curvedFrame(from: CGRect, to: CGRect, progress: CGFloat) -> CGRect {
        let size = CGSize(
            width: from.size.width + ((to.size.width - from.size.width) * progress),
            height: from.size.height + ((to.size.height - from.size.height) * progress)
        )

        let startCenter = CGPoint(x: from.midX, y: from.midY)
        let endCenter = CGPoint(x: to.midX, y: to.midY)
        let midPoint = CGPoint(
            x: (startCenter.x + endCenter.x) * 0.5,
            y: max(startCenter.y, endCenter.y)
        )
        let distance = hypot(endCenter.x - startCenter.x, endCenter.y - startCenter.y)
        let lift = min(140, max(44, distance * 0.18))
        let controlPoint = CGPoint(x: midPoint.x, y: midPoint.y + lift)
        let inverse = 1 - progress
        let center = CGPoint(
            x: (inverse * inverse * startCenter.x) + (2 * inverse * progress * controlPoint.x) + (progress * progress * endCenter.x),
            y: (inverse * inverse * startCenter.y) + (2 * inverse * progress * controlPoint.y) + (progress * progress * endCenter.y)
        )

        return CGRect(
            x: center.x - (size.width * 0.5),
            y: center.y - (size.height * 0.5),
            width: size.width,
            height: size.height
        )
    }
}
