import AppKit
import Foundation

/// Starts a bounded helper before terminating Cotabby. AppKit's localization and string catalogs
/// are cached for the process lifetime, so applying the new preference requires a true relaunch.
/// Keeping process creation here lets the Settings view report spawn failures and avoids a second
/// app instance racing the old process's native runtime teardown.
@MainActor
struct ApplicationRelauncher {
    typealias HelperLauncher = (URL, [String]) throws -> Void
    typealias ApplicationTerminator = () -> Void

    private let helperLauncher: HelperLauncher
    private let applicationTerminator: ApplicationTerminator

    init(
        helperLauncher: @escaping HelperLauncher,
        applicationTerminator: @escaping ApplicationTerminator
    ) {
        self.helperLauncher = helperLauncher
        self.applicationTerminator = applicationTerminator
    }

    init() {
        helperLauncher = Self.launchHelper
        applicationTerminator = { NSApplication.shared.terminate(nil) }
    }

    /// Returns only after the helper process has spawned successfully. The old app terminates
    /// afterward, while the helper waits for this PID before opening the same bundle URL.
    func restart(
        applicationBundleURL: URL = Bundle.main.bundleURL,
        processIdentifier: Int32 = ProcessInfo.processInfo.processIdentifier,
        debugLoggingEnabled: Bool = CotabbyDebugOptions.isEnabled
    ) throws {
        let plan = try ApplicationRelaunchPlan(
            processIdentifier: processIdentifier,
            applicationBundleURL: applicationBundleURL,
            debugLoggingEnabled: debugLoggingEnabled
        )
        try helperLauncher(ApplicationRelaunchPlan.executableURL, plan.processArguments)
        applicationTerminator()
    }

    private static func launchHelper(executableURL: URL, arguments: [String]) throws {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}
