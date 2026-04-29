import Combine
import CoreGraphics
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
}

@MainActor
protocol SuggestionGenerating: AnyObject {
    func generateSuggestion(for request: SuggestionRequest) async throws -> SuggestionResult
    /// Emits normalized, stable suggestion prefixes as they become available.
    ///
    /// Backends that cannot stream yet may use the default implementation below, which preserves
    /// coordinator behavior by yielding a single final update after regular generation completes.
    func streamSuggestion(for request: SuggestionRequest) -> AsyncThrowingStream<SuggestionStreamUpdate, Error>
    /// Clears backend-local continuation state when the focused editing context is no longer
    /// continuous. Stateless engines may implement this as a no-op.
    func resetCachedGenerationContext() async
}

extension SuggestionGenerating {
    func streamSuggestion(for request: SuggestionRequest) -> AsyncThrowingStream<SuggestionStreamUpdate, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { @MainActor in
                do {
                    let result = try await generateSuggestion(for: request)
                    continuation.yield(
                        SuggestionStreamUpdate(
                            generation: result.generation,
                            rawText: result.rawText,
                            text: result.text,
                            latency: result.latency,
                            isFinal: true
                        )
                    )
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }
}

@MainActor
protocol SuggestionSettingsProviding: AnyObject {
    var snapshot: SuggestionSettingsSnapshot { get }
    var snapshotPublisher: AnyPublisher<SuggestionSettingsSnapshot, Never> { get }
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

    func showSuggestion(_ text: String, at caretRect: CGRect, caretQuality: CaretGeometryQuality)
    func hide(reason: String)
}

@MainActor
protocol VisualContextCoordinating: AnyObject {
    var status: VisualContextStatus { get }
    var latestExcerpt: String? { get }
    var onStateChange: ((VisualContextStatus, String?) -> Void)? { get set }
    var onInjectedContextReady: ((String) -> Void)? { get set }

    func startSessionIfNeeded(for snapshotContext: FocusedInputSnapshot)
    func cancel(resetState: Bool)
    func excerpt(for context: FocusedInputContext) -> String?
}
