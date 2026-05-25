import Foundation

/// File overview:
/// Owns the debounce task, in-flight generation task, and monotonically increasing work id for
/// the suggestion pipeline. `SuggestionCoordinator` decides *when* work should happen; this type
/// owns *how* asynchronous work is replaced, cancelled, and identified as stale.
///
/// That split mirrors a common React pattern: a container owns intent, while a smaller helper owns
/// request lifecycle bookkeeping so stale async completions cannot write old state back into the UI.
@MainActor
final class SuggestionWorkController {
    private var debounceTask: Task<Void, Never>?
    private var generationTask: Task<Void, Never>?
    private var latestWorkID: UInt64 = 0

    var currentWorkID: UInt64 {
        latestWorkID
    }

    /// Replaces any pending debounce/generation work with one fresh debounced operation.
    /// The returned work id becomes the only valid id for future result application.
    @discardableResult
    func replaceDebouncedWork(
        delayMilliseconds: Int,
        operation: @escaping @MainActor (UInt64) async -> Void
    ) -> UInt64 {
        cancelTasks()
        latestWorkID &+= 1
        let workID = latestWorkID

        debounceTask = Task { [weak self] in
            let delayNanoseconds = UInt64(delayMilliseconds) * 1_000_000
            try? await Task.sleep(nanoseconds: delayNanoseconds)

            guard let self, !Task.isCancelled, workID == self.latestWorkID else {
                return
            }

            await operation(workID)
        }

        return workID
    }

    /// Starts one generation task for the current work id. The controller guards against late
    /// starts so the coordinator does not need to keep repeating the same stale-work checks.
    func replaceGenerationWork(
        for workID: UInt64,
        operation: @escaping @MainActor () async -> Void
    ) {
        generationTask?.cancel()
        generationTask = Task { [weak self] in
            guard let self, !Task.isCancelled, workID == self.latestWorkID else {
                return
            }

            await operation()
        }
    }

    /// Cancels all in-flight work and advances the work id so any late completions are rejected.
    func cancelAll() {
        cancelTasks()
        latestWorkID &+= 1
    }

    func isCurrent(_ workID: UInt64) -> Bool {
        workID == latestWorkID
    }

    private func cancelTasks() {
        debounceTask?.cancel()
        generationTask?.cancel()
        debounceTask = nil
        generationTask = nil
    }
}
