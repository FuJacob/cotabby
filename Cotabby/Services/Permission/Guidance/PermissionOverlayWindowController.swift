import AppKit
import Foundation
import QuartzCore

/// File overview:
/// Owns the non-activating overlay that visually anchors Cotabby's drag helper inside System
/// Settings.
///
/// Keeping this as a dedicated window controller follows the same pattern Cotabby already uses for
/// floating AppKit UI in `Services/Presentation`. The rest of the app can ask for "present / update / hide"
/// behavior without learning anything about `NSPanel` configuration or animation timing.
final class PermissionOverlayWindowController: NSWindowController {
    /// Shared with the content view so the panel and its content cannot disagree on size.
    fileprivate static let windowSize = NSSize(width: 540, height: 112)

    /// The fly-in in progress and the display link driving it, or `nil` when the overlay is at
    /// rest. One optional for both, so a running link always has an animation to step and a
    /// finished animation never leaves a link behind.
    private var launch: (animation: PermissionOverlayLaunchAnimation, displayLink: CADisplayLink)?

    init(
        hostApp: PermissionHostApp,
        permission: CotabbyPermissionKind,
        onDismiss: @escaping () -> Void
    ) {
        let window = PermissionOverlayPanel(
            contentRect: NSRect(origin: .zero, size: PermissionOverlayWindowController.windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        configureWindow(window)
        window.contentView = PermissionOverlayContentView(
            hostApp: hostApp,
            permission: permission,
            onDismiss: onDismiss
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func close() {
        endLaunch()
        window?.orderOut(nil)
        super.close()
    }

    func present(from sourceFrameInScreen: CGRect?, settingsFrame: CGRect, visibleFrame: CGRect) {
        endLaunch()
        guard let window else {
            return
        }

        let targetOrigin = anchoredOrigin(for: settingsFrame, visibleFrame: visibleFrame)
        let targetFrame = NSRect(origin: targetOrigin, size: Self.windowSize)

        guard let sourceFrameInScreen, !sourceFrameInScreen.isEmpty else {
            window.alphaValue = 1
            window.setFrame(targetFrame, display: false)
            window.orderFrontRegardless()
            return
        }

        window.alphaValue = PermissionOverlayLaunchAnimation.initialAlpha
        window.setFrame(sourceFrameInScreen, display: false)
        window.orderFrontRegardless()

        let displayLink = window.displayLink(target: self, selector: #selector(displayLinkDidFire(_:)))
        displayLink.add(to: .main, forMode: .common)
        launch = (
            animation: PermissionOverlayLaunchAnimation(
                startTime: CACurrentMediaTime(),
                fromFrame: sourceFrameInScreen,
                toFrame: targetFrame
            ),
            displayLink: displayLink
        )
        stepLaunchAnimation()
    }

    func updatePosition(with settingsFrame: CGRect, visibleFrame: CGRect) {
        guard let window else {
            return
        }

        let origin = anchoredOrigin(for: settingsFrame, visibleFrame: visibleFrame)
        // Mid-flight the animation owns the window's frame; retarget it and let it land there.
        if launch != nil {
            launch?.animation.toFrame.origin = origin
            return
        }

        window.setFrameOrigin(origin)
        window.orderFrontRegardless()
    }

    func hide() {
        endLaunch()
        window?.orderOut(nil)
    }

    private func configureWindow(_ window: NSWindow) {
        window.isOpaque = false
        window.backgroundColor = .clear
        window.level = .statusBar
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        window.animationBehavior = .none
    }

    private func stepLaunchAnimation() {
        guard let launch else {
            return
        }
        guard let window else {
            endLaunch()
            return
        }

        switch launch.animation.step(at: CACurrentMediaTime()) {
        case .inFlight(let alpha, let frame):
            window.alphaValue = alpha
            window.setFrame(frame, display: true)
        case .finished(let frame):
            endLaunch()
            window.alphaValue = 1
            window.setFrame(frame, display: true)
        }
    }

    @objc
    private func displayLinkDidFire(_ displayLink: CADisplayLink) {
        stepLaunchAnimation()
    }

    private func endLaunch() {
        launch?.displayLink.invalidate()
        launch = nil
    }

    /// Anchors the helper over the content area of the Privacy pane rather than the sidebar.
    private func anchoredOrigin(for settingsFrame: CGRect, visibleFrame: CGRect) -> NSPoint {
        let sidebarWidth: CGFloat = 170
        let contentMinX = settingsFrame.minX + sidebarWidth
        let windowSize = Self.windowSize
        let contentWidth = max(settingsFrame.width - sidebarWidth, windowSize.width)
        let preferredX = contentMinX + ((contentWidth - windowSize.width) / 2) - 8
        let preferredY = settingsFrame.minY + 14
        let minX = visibleFrame.minX + 8
        let maxX = visibleFrame.maxX - windowSize.width - 8
        let minY = visibleFrame.minY + 8
        let maxY = visibleFrame.maxY - windowSize.height - 8

        return NSPoint(
            x: min(max(preferredX, minX), maxX),
            y: min(max(preferredY, minY), maxY)
        )
    }
}

private final class PermissionOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class PermissionOverlayContentView: NSView {
    private let onDismiss: () -> Void

    init(
        hostApp: PermissionHostApp,
        permission: CotabbyPermissionKind,
        onDismiss: @escaping () -> Void
    ) {
        self.onDismiss = onDismiss
        super.init(frame: NSRect(origin: .zero, size: PermissionOverlayWindowController.windowSize))
        translatesAutoresizingMaskIntoConstraints = false
        setup(hostApp: hostApp, permission: permission)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setup(hostApp: PermissionHostApp, permission: CotabbyPermissionKind) {
        let materialView = NSVisualEffectView()
        materialView.translatesAutoresizingMaskIntoConstraints = false
        materialView.material = .popover
        materialView.blendingMode = .behindWindow
        materialView.state = .active
        materialView.wantsLayer = true
        materialView.layer?.cornerRadius = 18
        materialView.layer?.masksToBounds = true
        materialView.layer?.borderWidth = 0.5
        materialView.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.18).cgColor
        addSubview(materialView)

        let tintView = NSView()
        tintView.translatesAutoresizingMaskIntoConstraints = false
        tintView.wantsLayer = true
        tintView.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.78).cgColor
        materialView.addSubview(tintView)

        let dismissChrome = NSView()
        dismissChrome.translatesAutoresizingMaskIntoConstraints = false
        dismissChrome.wantsLayer = true
        dismissChrome.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.95).cgColor
        dismissChrome.layer?.cornerRadius = 16
        materialView.addSubview(dismissChrome)

        let dismissButton = NSButton()
        dismissButton.translatesAutoresizingMaskIntoConstraints = false
        dismissButton.isBordered = false
        dismissButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")
        dismissButton.contentTintColor = NSColor.labelColor.withAlphaComponent(0.72)
        dismissButton.target = self
        dismissButton.action = #selector(dismissPressed)
        if let cell = dismissButton.cell as? NSButtonCell {
            cell.imagePosition = .imageOnly
        }
        dismissChrome.addSubview(dismissButton)

        let arrowView = NSImageView()
        arrowView.translatesAutoresizingMaskIntoConstraints = false
        arrowView.image = NSImage(systemSymbolName: "arrow.up", accessibilityDescription: nil)
        arrowView.symbolConfiguration = .init(pointSize: 28, weight: .bold)
        arrowView.contentTintColor = NSColor(calibratedRed: 0.15, green: 0.54, blue: 0.98, alpha: 1)
        materialView.addSubview(arrowView)

        let titleLabel = NSTextField(labelWithAttributedString: title(hostApp: hostApp, permission: permission))
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.maximumNumberOfLines = 1
        titleLabel.lineBreakMode = .byTruncatingTail
        materialView.addSubview(titleLabel)

        let dragSource = PermissionDragSourceView(hostApp: hostApp)
        materialView.addSubview(dragSource)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: PermissionOverlayWindowController.windowSize.width),
            heightAnchor.constraint(equalToConstant: PermissionOverlayWindowController.windowSize.height),

            materialView.leadingAnchor.constraint(equalTo: leadingAnchor),
            materialView.trailingAnchor.constraint(equalTo: trailingAnchor),
            materialView.topAnchor.constraint(equalTo: topAnchor),
            materialView.bottomAnchor.constraint(equalTo: bottomAnchor),

            tintView.leadingAnchor.constraint(equalTo: materialView.leadingAnchor),
            tintView.trailingAnchor.constraint(equalTo: materialView.trailingAnchor),
            tintView.topAnchor.constraint(equalTo: materialView.topAnchor),
            tintView.bottomAnchor.constraint(equalTo: materialView.bottomAnchor),

            dismissChrome.leadingAnchor.constraint(equalTo: materialView.leadingAnchor, constant: 18),
            dismissChrome.topAnchor.constraint(equalTo: materialView.topAnchor, constant: 52),
            dismissChrome.widthAnchor.constraint(equalToConstant: 32),
            dismissChrome.heightAnchor.constraint(equalToConstant: 32),

            dismissButton.centerXAnchor.constraint(equalTo: dismissChrome.centerXAnchor),
            dismissButton.centerYAnchor.constraint(equalTo: dismissChrome.centerYAnchor),
            dismissButton.widthAnchor.constraint(equalToConstant: 14),
            dismissButton.heightAnchor.constraint(equalToConstant: 14),

            arrowView.leadingAnchor.constraint(equalTo: materialView.leadingAnchor, constant: 35),
            arrowView.topAnchor.constraint(equalTo: materialView.topAnchor, constant: 10),
            arrowView.widthAnchor.constraint(equalToConstant: 28),
            arrowView.heightAnchor.constraint(equalToConstant: 28),

            titleLabel.leadingAnchor.constraint(equalTo: arrowView.trailingAnchor, constant: 10),
            titleLabel.centerYAnchor.constraint(equalTo: arrowView.centerYAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: materialView.trailingAnchor, constant: -22),

            dragSource.leadingAnchor.constraint(equalTo: materialView.leadingAnchor, constant: 64),
            dragSource.trailingAnchor.constraint(equalTo: materialView.trailingAnchor, constant: -21),
            dragSource.topAnchor.constraint(equalTo: materialView.topAnchor, constant: 47),
            dragSource.heightAnchor.constraint(equalToConstant: 43)
        ])
    }

    private func title(hostApp: PermissionHostApp, permission: CotabbyPermissionKind) -> NSAttributedString {
        NSAttributedString(
            string: "Drag \(hostApp.displayName) to the list above to allow \(permission.title)",
            attributes: [
                .font: NSFont.systemFont(ofSize: 14, weight: .medium),
                .foregroundColor: NSColor.labelColor.withAlphaComponent(0.82)
            ]
        )
    }

    @objc
    private func dismissPressed() {
        onDismiss()
    }
}
