import CoreGraphics

/// Describes one physical display in both coordinate systems Tabby has to bridge.
///
/// Accessibility and CoreGraphics APIs report rectangles in a top-left-origin display space.
/// AppKit windows use a bottom-left-origin screen space. Keeping both frames together lets the
/// conversion flip Y inside the display that actually owns the rectangle instead of using a
/// fragile union of every connected monitor.
struct DisplayGeometry: Equatable {
    let appKitFrame: CGRect
    let visibleFrame: CGRect
    let coreGraphicsBounds: CGRect
    let backingScaleFactor: CGFloat
}

/// Pure display-coordinate conversion shared by AX geometry and tests.
///
/// This type intentionally knows nothing about `NSScreen`; callers pass snapshots of display
/// geometry in. That keeps the math testable for external-monitor arrangements that are awkward
/// to reproduce in CI, such as a secondary display above the primary display.
enum DisplayCoordinateConverter {
    static func appKitRect(
        fromCoreGraphicsRect rect: CGRect,
        displays: [DisplayGeometry]
    ) -> CGRect? {
        guard let display = bestDisplay(
            for: rect,
            displays: displays,
            keyPath: \.coreGraphicsBounds
        ) else {
            return nil
        }

        return appKitRect(fromCoreGraphicsRect: rect, on: display)
    }

    static func appKitRectsFromPixelRect(
        _ rect: CGRect,
        displays: [DisplayGeometry]
    ) -> [CGRect] {
        displays.compactMap { display in
            guard display.backingScaleFactor > 0 else { return nil }

            let pixelBounds = CGRect(
                x: display.coreGraphicsBounds.minX * display.backingScaleFactor,
                y: display.coreGraphicsBounds.minY * display.backingScaleFactor,
                width: display.coreGraphicsBounds.width * display.backingScaleFactor,
                height: display.coreGraphicsBounds.height * display.backingScaleFactor
            )

            let midpoint = CGPoint(x: rect.midX, y: rect.midY)
            guard pixelBounds.intersects(rect) || pixelBounds.contains(midpoint) else {
                return nil
            }

            let pointRect = CGRect(
                x: display.coreGraphicsBounds.minX
                    + (rect.minX - pixelBounds.minX) / display.backingScaleFactor,
                y: display.coreGraphicsBounds.minY
                    + (rect.minY - pixelBounds.minY) / display.backingScaleFactor,
                width: rect.width / display.backingScaleFactor,
                height: rect.height / display.backingScaleFactor
            )

            return appKitRect(fromCoreGraphicsRect: pointRect, on: display)
        }
    }

    private static func appKitRect(
        fromCoreGraphicsRect rect: CGRect,
        on display: DisplayGeometry
    ) -> CGRect {
        let localX = rect.minX - display.coreGraphicsBounds.minX
        let localY = rect.minY - display.coreGraphicsBounds.minY

        return CGRect(
            x: display.appKitFrame.minX + localX,
            y: display.appKitFrame.maxY - localY - rect.height,
            width: rect.width,
            height: rect.height
        )
    }

    private static func bestDisplay(
        for rect: CGRect,
        displays: [DisplayGeometry],
        keyPath: KeyPath<DisplayGeometry, CGRect>
    ) -> DisplayGeometry? {
        let midpoint = CGPoint(x: rect.midX, y: rect.midY)

        if let containingDisplay = displays.first(where: {
            $0[keyPath: keyPath].contains(midpoint)
        }) {
            return containingDisplay
        }

        return displays
            .filter { $0[keyPath: keyPath].intersects(rect) }
            .max { lhs, rhs in
                intersectionArea(lhs[keyPath: keyPath], rect)
                    < intersectionArea(rhs[keyPath: keyPath], rect)
            }
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }
}
