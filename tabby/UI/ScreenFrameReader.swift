import AppKit
import SwiftUI

/// Bridges SwiftUI layout into AppKit screen coordinates for cross-window UI.
///
/// SwiftUI's `GeometryReader` is excellent for local layout, but Tabby's permission guidance
/// overlay is an `NSPanel` positioned outside the SwiftUI hierarchy. This representable installs a
/// tiny AppKit view behind a SwiftUI control and reports that control's bounds in global screen
/// coordinates, which gives AppKit an anchor rect without coupling the view to window management.
struct ScreenFrameReader: NSViewRepresentable {
    @Binding var frameInScreen: CGRect

    func makeNSView(context: Context) -> ScreenFrameTrackingView {
        let view = ScreenFrameTrackingView()
        view.onFrameChange = { frame in
            frameInScreen = frame
        }
        return view
    }

    func updateNSView(_ nsView: ScreenFrameTrackingView, context: Context) {
        nsView.onFrameChange = { frame in
            frameInScreen = frame
        }
        nsView.reportFrame()
    }
}

/// Invisible AppKit measuring view used by `ScreenFrameReader`.
///
/// The view reports after window attachment and layout because menu-bar popovers and onboarding
/// windows can move independently. Re-reading the rect protects the overlay animation from stale
/// geometry when the parent window is repositioned before the user clicks.
final class ScreenFrameTrackingView: NSView {
    var onFrameChange: ((CGRect) -> Void)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        reportFrame()
    }

    override func layout() {
        super.layout()
        reportFrame()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        reportFrame()
    }

    func reportFrame() {
        guard let window else {
            return
        }

        let frame = window.convertToScreen(convert(bounds, to: nil))
        DispatchQueue.main.async { [onFrameChange] in
            onFrameChange?(frame)
        }
    }
}
