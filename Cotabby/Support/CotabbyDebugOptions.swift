import Foundation

/// File overview:
/// Centralizes Cotabby's developer-only runtime switches.
///
/// A single launch argument is easier to reason about than separate feature flags because every
/// privacy-sensitive diagnostic path has one obvious gate. Passing `-cotabby-debug` means the
/// developer intentionally opted into local debugging artifacts such as overlays, detailed service
/// logs, and screenshot/OCR captures.
enum CotabbyDebugOptions {
    static let launchArgument = "-cotabby-debug"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }

    /// Writes a diagnostic line only when the explicit debug launch argument is present.
    ///
    /// Keep this for metadata, not raw user content. Full prompts, OCR text, and screenshots are
    /// sensitive enough that call sites should make an intentional artifact decision instead of
    /// accidentally leaking them through normal stdout.
    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else {
            return
        }

        print(message())
    }
}
