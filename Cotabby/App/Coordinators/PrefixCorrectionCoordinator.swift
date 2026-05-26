import Combine
import Foundation
import Logging

/// File overview:
/// Owns the settled-pause-driven typo-correction loop. Subscribes to focus snapshots,
/// detects when the user has stopped typing for `settledDuration`, asks the correction
/// engine for a proposed fix, validates it through `PrefixCorrectionFilter`, and writes
/// the accepted result back to the focused field via `PrefixCorrectionWriter`.
///
/// All collaborators are injected by capability — engine, writer, and settings/state
/// queries are closures or narrow protocols. The coordinator owns the state machine,
/// cancellation discipline, and gate logic; everything else can be stubbed.
///
/// Cancellation discipline (mirrors `SuggestionWorkController`):
/// - Each settled event gets a monotonically increasing work ID.
/// - The async correction call may complete after the user has typed more characters.
///   Before writing, the coordinator re-reads the live focus snapshot and drops the
///   result if the prefix changed under it.
/// - `lastSubmittedPrefix` is tracked per-bundle-identifier so a correction that simply
///   re-surfaces (because writing the fix triggered another settled event) is not
///   re-sent to the model — saves a roundtrip and keeps the loop naturally idempotent.
@MainActor
final class PrefixCorrectionCoordinator {
    /// 800ms is a balance between "the user is mid-thought" and "the user has moved on."
    /// Short enough that the fix lands while the user can still see their original typo;
    /// long enough that pause-to-think doesn't trigger a correction mid-sentence.
    static let defaultSettledDuration: TimeInterval = 0.8
    /// Below this character count the model has almost no signal to work with and short
    /// fragments are usually still being typed.
    static let defaultMinimumPrefixCharacterCount = 12
    /// Above this the backspace burst becomes user-visible flicker. The feature is
    /// already opt-in and per-app, so a hard cap is safer than trying to optimize.
    static let defaultMaximumPrefixCharacterCount = 500

    private let focusModel: any SuggestionFocusProviding
    private let correctionEngine: any PrefixCorrecting
    private let writer: PrefixCorrectionWriter
    private let isCorrectionEnabled: @MainActor () -> Bool
    private let isAutocompleteBusy: @MainActor () -> Bool
    private let settledDuration: TimeInterval
    private let minimumPrefixCharacterCount: Int
    private let maximumPrefixCharacterCount: Int

    private var cancellables = Set<AnyCancellable>()
    private var latestWorkID: UInt64 = 0
    private var inflightTask: Task<Void, Never>?
    /// Most recent prefix that was submitted to the engine, keyed by the bundle it came
    /// from. Lets us short-circuit "we just corrected this, the publisher fired again
    /// with the corrected text" without burning another LLM call.
    private var lastSubmittedPrefix: [String: String] = [:]

    /// Debug-only hook fired right after a correction is written, with the original prefix and the
    /// accepted replacement. Set by app composition only when the debug overlay is active; nil
    /// otherwise so production does no extra work.
    var onCorrectionApplied: (@MainActor (_ original: String, _ corrected: String) -> Void)?

    init(
        focusModel: any SuggestionFocusProviding,
        correctionEngine: any PrefixCorrecting,
        writer: PrefixCorrectionWriter,
        isCorrectionEnabled: @escaping @MainActor () -> Bool,
        isAutocompleteBusy: @escaping @MainActor () -> Bool,
        settledDuration: TimeInterval = defaultSettledDuration,
        minimumPrefixCharacterCount: Int = defaultMinimumPrefixCharacterCount,
        maximumPrefixCharacterCount: Int = defaultMaximumPrefixCharacterCount
    ) {
        self.focusModel = focusModel
        self.correctionEngine = correctionEngine
        self.writer = writer
        self.isCorrectionEnabled = isCorrectionEnabled
        self.isAutocompleteBusy = isAutocompleteBusy
        self.settledDuration = settledDuration
        self.minimumPrefixCharacterCount = minimumPrefixCharacterCount
        self.maximumPrefixCharacterCount = maximumPrefixCharacterCount
    }

    func start() {
        guard cancellables.isEmpty else { return }

        focusModel.snapshotPublisher
            .compactMap { snapshot -> SettledKey? in
                guard let context = snapshot.context else { return nil }
                return SettledKey(
                    bundleIdentifier: snapshot.bundleIdentifier,
                    precedingText: context.precedingText,
                    selectionLength: context.selection.length,
                    isSecure: context.isSecure
                )
            }
            .removeDuplicates()
            .debounce(for: .seconds(settledDuration), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.handleSettled()
            }
            .store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
        inflightTask?.cancel()
        inflightTask = nil
    }

    // MARK: - Settled-event handling

    /// One settled event = one attempt. Bumps the work ID immediately so any in-flight
    /// attempt becomes stale, then spawns a fresh Task to drive the engine + filter +
    /// writer pipeline.
    private func handleSettled() {
        latestWorkID &+= 1
        let workID = latestWorkID

        inflightTask?.cancel()

        // Re-read fresh from the focus model rather than trusting whatever the publisher
        // delivered — the snapshot may have moved between debounce-firing and this sink.
        focusModel.refreshNow()
        let snapshot = focusModel.snapshot
        guard let context = snapshot.context else { return }

        guard passesGate(snapshot: snapshot, context: context) else { return }

        let bundleKey = snapshot.bundleIdentifier ?? ""
        if lastSubmittedPrefix[bundleKey] == context.precedingText {
            // Already asked about this exact prefix in this app — nothing to do.
            return
        }
        lastSubmittedPrefix[bundleKey] = context.precedingText

        let originalPrefix = context.precedingText
        let originalLength = originalPrefix.count

        inflightTask = Task { [weak self] in
            guard let self else { return }
            await self.runCorrection(
                workID: workID,
                originalPrefix: originalPrefix,
                originalLength: originalLength
            )
        }
    }

    private func runCorrection(workID: UInt64, originalPrefix: String, originalLength: Int) async {
        let proposal: String?
        do {
            proposal = try await correctionEngine.proposeCorrection(for: originalPrefix)
        } catch is CancellationError {
            return
        } catch SuggestionClientError.cancelled {
            return
        } catch {
            CotabbyLogger.suggestion.debug("Prefix-correction engine error: \(error.localizedDescription)")
            return
        }

        guard !Task.isCancelled, workID == latestWorkID else { return }
        guard let proposal else { return }

        // The user may have typed more characters during the LLM round-trip. If the live
        // prefix no longer matches what we submitted, drop the result — it would clobber
        // characters that didn't exist when the model formed its answer.
        focusModel.refreshNow()
        guard let liveContext = focusModel.snapshot.context,
              liveContext.precedingText == originalPrefix,
              liveContext.selection.length == 0
        else {
            return
        }

        guard let accepted = PrefixCorrectionFilter.acceptedCorrection(
            original: originalPrefix,
            proposed: proposal
        ) else {
            CotabbyLogger.suggestion.debug("Prefix-correction filter rejected proposal")
            return
        }

        // Record the accepted output so the re-trigger from our own write doesn't ask
        // the engine to "correct" already-corrected text.
        let bundleKey = focusModel.snapshot.bundleIdentifier ?? ""
        lastSubmittedPrefix[bundleKey] = accepted

        _ = writer.replacePrefix(originalLength: originalLength, with: accepted)
        onCorrectionApplied?(originalPrefix, accepted)
    }

    // MARK: - Gating

    private func passesGate(snapshot: FocusSnapshot, context: FocusedInputSnapshot) -> Bool {
        guard isCorrectionEnabled() else { return false }
        guard !context.isSecure else { return false }
        guard context.selection.length == 0 else { return false }
        guard TerminalAppDetector.isTerminal(bundleIdentifier: snapshot.bundleIdentifier) == false else {
            return false
        }
        guard !isAutocompleteBusy() else { return false }
        guard context.precedingText.count >= minimumPrefixCharacterCount else { return false }
        guard context.precedingText.count <= maximumPrefixCharacterCount else { return false }
        return correctionEngine.isAvailable
    }

    // MARK: - De-dup key

    /// Compound key used to suppress duplicate settled events from a single sink. Any of
    /// these changing means "the user has done something interesting since last time."
    private struct SettledKey: Equatable {
        let bundleIdentifier: String?
        let precedingText: String
        let selectionLength: Int
        let isSecure: Bool
    }
}
