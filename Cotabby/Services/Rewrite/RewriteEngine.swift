import Foundation

/// File overview:
/// Runs one rewrite on the provider the user chose in Settings → Rewrite, and returns text ready to
/// replace the selection (`RewriteOutputCleaner`). The single place that maps the preference to a
/// provider, so the coordinator and the popup's disclosure always agree on where the text goes.
/// Built by `CotabbyAppEnvironment`, used by `SelectionRewriteCoordinator`.
@MainActor
final class RewriteEngine {
    private let local: RewriteProviding
    private let api: RewriteProviding
    private let preferences: @MainActor () -> RewritePreferences

    init(local: RewriteProviding, api: RewriteProviding, preferences: @escaping @MainActor () -> RewritePreferences) {
        self.local = local
        self.api = api
        self.preferences = preferences
    }

    nonisolated deinit {}

    /// Read per rewrite rather than cached, so a provider change in Settings applies to the next one.
    var activeProvider: RewriteProviding { preferences().provider == .api ? api : local }

    func rewrite(_ request: RewriteRequest, onPartial: @escaping @MainActor (String) -> Void) async throws -> String {
        guard request.selection.count <= SelectionRewriteEligibility.maximumCharacters else { throw RewriteError.selectionTooLong }
        let provider = activeProvider
        guard provider.isAvailable else { throw RewriteError.noProvider }
        let raw = try await provider.rewrite(request, onPartial: onPartial)
        guard let cleaned = RewriteOutputCleaner.clean(raw, selection: request.selection, action: request.action) else {
            throw RewriteError.unusableOutput
        }
        return cleaned
    }
}
