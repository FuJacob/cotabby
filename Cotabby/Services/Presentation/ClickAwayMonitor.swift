import AppKit

/// File overview:
/// Watches for a mouse-down outside an interactive overlay panel, so the picker or preview it
/// belongs to can dismiss itself.
///
/// Two monitors are needed because AppKit splits the events: the global monitor sees clicks in
/// every other application (by definition outside the panel) and never Cotabby's own, while the
/// local monitor sees Cotabby's own clicks, including those on the panel itself, which it lets
/// through. Owning the pair as one object means a controller holds a single optional: its
/// "visible" state and its installed monitors cannot disagree.
@MainActor
final class ClickAwayMonitor {
    private var globalMonitor: Any?
    private var localMonitor: Any?

    /// `panel` is held weakly: the monitor must not keep an overlay's window alive.
    init(panel: NSPanel, onClickOutside: @escaping () -> Void) {
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { _ in
            onClickOutside()
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak panel] event in
            if event.window !== panel {
                onClickOutside()
            }
            return event
        }
    }

    /// Must be called before the monitor is released: AppKit keeps calling a monitor's handler
    /// until it is removed, whatever happens to the object that installed it.
    func remove() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
    }
}
