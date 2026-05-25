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
    func generateCompose(for request: ComposeRequest) async throws -> ComposeResult
    /// Streaming variant: yields each generated piece through an async stream so the coordinator
    /// can type tokens into the focused field as the model produces them. Engines that cannot
    /// stream natively get the one-shot fallback in the extension below.
    func generateComposeStreaming(for request: ComposeRequest) async throws -> AsyncThrowingStream<String, Error>
    /// Clears backend-local continuation state when the focused editing context is no longer
    /// continuous. Stateless engines may implement this as a no-op.
    func resetCachedGenerationContext() async
}

extension SuggestionGenerating {
    /// One-shot fallback: run `generateCompose`, then emit the full draft as a single chunk.
    /// Engines that can stream natively (Llama) override this to actually emit per token.
    func generateComposeStreaming(for request: ComposeRequest) async throws -> AsyncThrowingStream<String, Error> {
        let result = try await generateCompose(for: request)
        return AsyncThrowingStream { continuation in
            if !result.text.isEmpty {
                continuation.yield(result.text)
            }
            continuation.finish()
        }
    }
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
    func typeDraft(
        _ draft: String,
        shouldContinue: @escaping @MainActor () -> Bool
    ) async -> Bool
}

@MainActor
protocol SuggestionOverlayControlling: AnyObject {
    var state: OverlayState { get }
    var onStateChange: ((OverlayState) -> Void)? { get set }

    func showSuggestion(_ text: String, geometry: SuggestionOverlayGeometry)
    func showComposePreview(_ text: String, geometry: SuggestionOverlayGeometry)
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

/// Behavior-shaped contract for Compose Mode AX context collection.
///
/// The coordinator only needs "collect a normalized surrounding context for this focused field";
/// keeping the contract narrow lets tests substitute a deterministic fake without standing up the
/// real AX tree, while production code still uses the bounded DFS in `ComposeContextCollector`.
@MainActor
protocol ComposeContextCollecting: AnyObject {
    func collect(for context: FocusedInputContext) async throws -> ComposeContextCollectionResult
}

/// What a Compose context collector returns.
///
/// This sits next to the protocol (not on the concrete collector) so test fakes can construct
/// results without depending on the real collector's nested types.
struct ComposeContextCollectionResult: Equatable, Sendable {
    let text: String
    let visitedNodeCount: Int
    let retainedTextCount: Int
    let droppedTextCount: Int

    init(
        text: String,
        visitedNodeCount: Int = 0,
        retainedTextCount: Int = 0,
        droppedTextCount: Int = 0
    ) {
        self.text = text
        self.visitedNodeCount = visitedNodeCount
        self.retainedTextCount = retainedTextCount
        self.droppedTextCount = droppedTextCount
    }
}
