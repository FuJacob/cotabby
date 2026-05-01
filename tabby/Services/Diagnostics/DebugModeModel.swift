import Combine
import Foundation

/// File overview:
/// Owns the single debug-mode flag that gates Tabby's in-app diagnostics.
///
/// This model is intentionally separate from suggestion settings. Suggestion settings are product
/// behavior; debug mode is operator behavior. Debug mode is resolved once from the Xcode scheme's
/// launch argument so it cannot drift at runtime.
@MainActor
final class DebugModeModel: ObservableObject {
    static let launchArgument = "-tabby-debug"

    @Published private(set) var state: DebugModeState

    init(
        arguments: [String] = ProcessInfo.processInfo.arguments
    ) {
        let enabledByLaunchArgument = arguments.contains(Self.launchArgument)
        state = DebugModeState(
            isEnabled: enabledByLaunchArgument,
            launchArgument: Self.launchArgument
        )
    }

    var isEnabled: Bool {
        state.isEnabled
    }
}
