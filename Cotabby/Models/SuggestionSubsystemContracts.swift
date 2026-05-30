import Combine
import Foundation

/// File overview:
/// Defines the behavior-shaped contracts that `SuggestionCoordinator` depends on.
///
/// These protocols are intentionally narrow. The goal is not "abstract everything"; the goal is
/// to describe the coordinator's collaborators by the capabilities it actually needs:
/// permission reads, focus snapshots, input events, suggestion generation, text insertion, and
/// legacy visual-context lifecycle callbacks.
///
/// This is a high-leverage maintainability move because `SuggestionCoordinator` is the app's
/// largest orchestration type. Depending on contracts instead of concrete classes makes the data
/// flow easier to understand today and gives a natural seam for tests later without changing
/// runtime behavior now.
@MainActor
protocol SuggestionPermissionProviding: AnyObject {
    var inputMonitoringGranted: Bool { get }
    var screenRecordingGranted: Bool { get }
    var inputMonitoringGrantedPublisher: AnyPublisher<Bool, Never> { get }
    var screenRecordingGrantedPublisher: AnyPublisher<Bool, Never> { get }
}

@MainActor
protocol SuggestionFocusProviding: AnyObject {
    var snapshot: FocusSnapshot { get }
    var snapshotPublisher: AnyPublisher<FocusSnapshot, Never> { get }

    func refreshNow()
}

@MainActor
protocol SuggestionInputMonitoring: AnyObject {
    var onEvent: ((CapturedInputEvent) -> Bool)? { get set }
    var onSuppressedSyntheticInput: (() -> Void)? { get set }

    /// Fail-open preflight for the active accept tap. The tap only routes a matching key into the
    /// coordinator when this closure returns `true` at event time. The coordinator still performs
    /// full session validation before the tap consumes the original key.
    var shouldConsumeAcceptKeyProvider: @MainActor @Sendable () -> Bool { get set }

    /// Drives the lifecycle of the active accept-key tap. The coordinator turns this on while
    /// a suggestion overlay is visible and off otherwise, so Cotabby only sits in the synchronous
    /// keystroke path during the brief windows it actually needs to consume the accept key.
    func setAcceptInterceptionActive(_ active: Bool)
}

@MainActor
protocol SuggestionGenerating: AnyObject {
    func generateSuggestion(for request: SuggestionRequest) async throws -> SuggestionResult
    /// Clears backend-local continuation state when the focused editing context is no longer
    /// continuous. Stateless engines may implement this as a no-op.
    func resetCachedGenerationContext() async
    /// Best-effort warmup hook the coordinator calls after focus arrives on an editable surface.
    /// Engines that benefit from prefix caching or weight loading (Apple Foundation Models) use it
    /// to prime the next request; engines that do not (llama already keeps its KV cache hot) can
    /// rely on the default no-op extension. Failures are intentionally swallowed by implementations
    /// because prewarming is opportunistic.
    func prewarm(for request: SuggestionRequest) async
}

extension SuggestionGenerating {
    func prewarm(for request: SuggestionRequest) async {}
}

@MainActor
protocol SuggestionSettingsProviding: AnyObject {
    var snapshot: SuggestionSettingsSnapshot { get }
    var snapshotPublisher: AnyPublisher<SuggestionSettingsSnapshot, Never> { get }
}

@MainActor
protocol ClipboardContextProviding: AnyObject {
    func currentContext() -> String?
    var currentChangeCount: Int { get }
}

@MainActor
protocol ClipboardRelevanceFiltering: AnyObject {
    /// Returns `clipboard` when it should be injected into the prompt, or `nil` to drop it.
    ///
    /// `precedingText` should be the same bounded window the downstream distiller will see,
    /// so the relevance gate and per-line distillation evaluate overlap consistently.
    func filter(
        clipboard: String?,
        pasteboardChangeCount: Int,
        precedingText: String
    ) -> String?
}

@MainActor
protocol SuggestionInserting: AnyObject {
    var lastErrorMessage: String? { get }

    func insert(_ suggestion: String) -> Bool
}

@MainActor
protocol SuggestionOverlayControlling: AnyObject {
    var state: OverlayState { get }
    var onStateChange: ((OverlayState) -> Void)? { get set }

    func showSuggestion(_ text: String, geometry: SuggestionOverlayGeometry)
    func hide(reason: String)
}

@MainActor
protocol VisualContextCoordinating: AnyObject {
    var status: VisualContextStatus { get }
    var latestExcerpt: String? { get }
    var onStateChange: ((VisualContextStatus, String?) -> Void)? { get set }
    var onInjectedContextReady: ((FocusedInputIdentity) -> Void)? { get set }

    func startSessionIfNeeded(for snapshotContext: FocusedInputSnapshot)
    func cancel(resetState: Bool)
    func excerpt(for context: FocusedInputContext) -> String?
}
