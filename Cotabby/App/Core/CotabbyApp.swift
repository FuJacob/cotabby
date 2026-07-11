import AppKit

/// File overview:
/// Declares Cotabby's AppKit entry point. `AppDelegate` owns the long-lived dependency graph and
/// `MenuBarController` owns the status item/popover, so launch never has to instantiate SwiftUI's
/// `App`/`Scene` graph. That boundary matters for macOS 14 and early macOS 15 releases, where an
/// Xcode 26-built `MenuBarExtra(.window)` can abort inside AttributeGraph before AppKit delivers a
/// lifecycle callback (issue #767).
///
/// The enum has no instances. Its one static delegate reference keeps the weak `NSApplication`
/// delegate alive until the run loop exits.
@main
enum CotabbyApp {
    private static var appDelegate: AppDelegate?

    @MainActor
    static func main() {
        let application = NSApplication.shared
        let delegate = AppDelegate()
        appDelegate = delegate
        application.delegate = delegate
        application.run()
    }
}
