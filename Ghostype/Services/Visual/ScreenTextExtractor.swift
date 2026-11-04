import CoreGraphics
import Foundation
import Logging
@preconcurrency import Vision

/// File overview:
/// Runs OCR over a captured window screenshot and returns a reading-order text excerpt.
/// This is the bridge between raw image capture and the existing text-only local LLM runtime.
///
/// We deliberately downsample very large screenshots before OCR. The goal is not archival fidelity;
/// it is bounded semantic extraction for autocomplete context. This pass favors useful text
/// recovery over minimum latency because refresh runs independently of prediction generation.

struct ExtractedScreenText: Sendable {
    let text: String
    let lineCount: Int
    /// Per-line OCR text paired with Vision's recognition confidence, in reading order. Carries the
    /// confidence that the joined `text` discards, so `OCRTextHygiene.dropLowConfidence` can filter on
    /// real values instead of a synthesized constant. Defaults to empty for callers (and tests) that
    /// only supply joined text.
    let lines: [OCRTextHygiene.OCRLine]

    init(text: String, lineCount: Int, lines: [OCRTextHygiene.OCRLine] = []) {
        self.text = text
        self.lineCount = lineCount
        self.lines = lines
    }
}

/// Test seam for screenshot OCR.
///
/// `ScreenshotContextGenerator` owns orchestration, while this protocol lets tests inject
/// deterministic OCR without depending on Vision, Screen Recording permission, or real pixels.
protocol ScreenTextExtracting {
    func extractText(from image: CGImage) async throws -> ExtractedScreenText
}

enum ScreenTextExtractionError: LocalizedError {
    case noRecognizedText
    case ocrFailed(String)
    /// OCR is still busy with an earlier pass that overran its time, or this pass ran out of time.
    case ocrUnavailable

    var errorDescription: String? {
        switch self {
        case .noRecognizedText:
            return "No usable visible text was recognized in the screenshot."
        case let .ocrFailed(message):
            return "Screenshot OCR failed: \(message)"
        case .ocrUnavailable:
            return "Screenshot OCR is busy with an earlier pass that has not finished."
        }
    }
}

/// Runs blocking Vision OCR one pass at a time, process-wide, and bounds how long a caller waits.
///
/// Why this exists: `VNImageRequestHandler.perform` blocks its thread until Vision returns, and
/// Vision can wedge (a pass was seen parked forever on a semaphore inside TextRecognition). Before
/// this gate every OCR pass took its own GCD worker, so each later pass queued behind the wedged
/// one inside Vision and held another thread. After a few hours 44 threads were parked, libdispatch
/// hit its 90-thread limit, and AppKit's own background callbacks stopped getting threads: the menu
/// bar popover no longer heard that the app was deactivated, so it would not close and its buttons
/// stopped answering.
///
/// The gate holds three invariants:
/// - Vision runs only on one serial queue, so a wedged pass costs exactly one thread.
/// - A caller waits at most `timeout` (or until its task is cancelled), never forever.
/// - Once the running pass has overrun its deadline, new callers are refused at once (`busy`)
///   instead of queueing behind something that may never return. Work whose caller already gave up
///   is skipped when its turn comes, so a backlog never runs stale OCR late.
///
/// Lifetime: `ScreenTextExtractor.sharedGate` lives for the whole process; tests build their own.
final class OCRWorkGate: @unchecked Sendable {
    enum Failure: Error, Equatable {
        /// The pass currently running overran its deadline; OCR is unavailable until it returns.
        case busy
        /// This caller's wait ran out before its pass finished.
        case timedOut
    }

    private let queue: DispatchQueue
    private let lock = NSLock()
    /// Deadline of the pass executing on `queue` right now; nil while the queue is idle.
    private var runningDeadline: Date?

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    func run<T: Sendable>(
        timeout: TimeInterval,
        _ work: @escaping @Sendable () throws -> T
    ) async throws -> T {
        if isWedged() {
            throw Failure.busy
        }

        let call = GatedCall<T>()
        // The timer lives on Swift's cooperative pool, not on GCD: it must still fire when the
        // thing it guards against (a starved dispatch pool) is happening.
        let timer = Task {
            guard (try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))) != nil else { return }
            call.settle(.failure(Failure.timedOut))
        }
        defer { timer.cancel() }

        queue.async { [self] in
            // The caller timed out or was cancelled while this item waited its turn.
            guard !call.isSettled else { return }
            setRunningDeadline(Date().addingTimeInterval(timeout))
            let result = Result { try work() }
            setRunningDeadline(nil)
            call.settle(result)
        }

        // `withTaskCancellationHandler` lets a cancelled caller (the user moved to another field)
        // stop waiting right away; the Vision pass itself cannot be interrupted and simply finishes
        // or stays wedged on the gate's one thread.
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                call.install(continuation)
            }
        } onCancel: {
            call.settle(.failure(CancellationError()))
        }
    }

    private func isWedged() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let runningDeadline else { return false }
        return Date() > runningDeadline
    }

    private func setRunningDeadline(_ deadline: Date?) {
        lock.lock()
        runningDeadline = deadline
        lock.unlock()
    }
}

/// One caller's pending result. Three parties race to settle it (the work, the timer, task
/// cancellation) and a checked continuation must resume exactly once, so the first outcome wins
/// and later ones are dropped. Cancellation can also fire before the continuation is installed;
/// the outcome is then held and delivered on install.
private final class GatedCall<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var outcome: Result<T, Error>?

    var isSettled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return outcome != nil
    }

    func install(_ continuation: CheckedContinuation<T, Error>) {
        lock.lock()
        if let outcome {
            lock.unlock()
            continuation.resume(with: outcome)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func settle(_ result: Result<T, Error>) {
        lock.lock()
        guard outcome == nil else {
            lock.unlock()
            return
        }
        outcome = result
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: result)
    }
}

struct ScreenTextExtractor: ScreenTextExtracting {
    /// Vision cannot produce useful text from near-zero-sized request images. Treating those as
    /// empty OCR keeps degenerate screenshots on the same unavailable-context path as blank windows.
    private static let minimumOCRImageDimension = 4

    /// One gate for every OCR caller in the process (screen context builds a new extractor per
    /// pass, so the gate cannot live on the instance).
    static let sharedGate = OCRWorkGate(label: "com.jasshans.ghostype.ocr")

    /// A warm accurate pass takes well under two seconds, but the first one in a process loads
    /// Vision's text models and was measured at 31 s on a busy machine. The timeout only frees a
    /// waiting caller (OCR is background context, so a long wait costs nothing visible); the thread
    /// bound that prevents starvation comes from the gate's serial queue, not from this number.
    static let ocrTimeoutSeconds: TimeInterval = 60

    let maxImageDimension: Int
    let maxRecognizedCharacters: Int

    init(
        maxImageDimension: Int = VisualContextConfiguration.default.maxImageDimension,
        maxRecognizedCharacters: Int = VisualContextConfiguration.default.maxRecognizedCharacters
    ) {
        self.maxImageDimension = maxImageDimension
        self.maxRecognizedCharacters = maxRecognizedCharacters
    }

    /// Performs OCR asynchronously so the main actor is not blocked by Vision processing.
    func extractText(from image: CGImage) async throws -> ExtractedScreenText {
        let startedAt = Date()
        // Resizing a full Retina window is CPU work too; do not do it on the caller's main actor.
        let preparedImage = await Task.detached(priority: .utility) {
            downsampledImageIfNeeded(image)
        }.value
        try Task.checkCancellation()
        let wasDownsampled = preparedImage.width != image.width || preparedImage.height != image.height

        log(
            "ocr-start input=\(image.width)x\(image.height) prepared=\(preparedImage.width)x\(preparedImage.height) " +
                "downsampled=\(wasDownsampled)"
        )

        guard preparedImage.width >= Self.minimumOCRImageDimension,
              preparedImage.height >= Self.minimumOCRImageDimension else {
            log(
                "ocr-skipped-too-small input=\(image.width)x\(image.height) " +
                    "prepared=\(preparedImage.width)x\(preparedImage.height)"
            )
            throw ScreenTextExtractionError.noRecognizedText
        }

        let maxRecognizedCharacters = self.maxRecognizedCharacters
        let recognizedLines: [OCRTextHygiene.OCRLine]
        do {
            // `perform` is synchronous and Vision has filled `results` by the time it returns, so
            // the pass is one blocking call on the gate's single thread (see `OCRWorkGate`).
            recognizedLines = try await Self.sharedGate.run(timeout: Self.ocrTimeoutSeconds) {
                let request = VNRecognizeTextRequest()
                // Accurate OCR is slower, but visual context refresh is throttled independently
                // of typing and the result can materially improve autocomplete relevance. Language
                // correction is on for the same reason: it cuts garbled recognitions at the
                // source, which matters because this text conditions the prompt and the
                // downstream hygiene filters can only drop junk, not repair it.
                // "Lighter screen reading" (Speed) trades that for the fast recognizer, which runs
                // several times quicker and wakes the CPU for less time per capture.
                let light = SpeedSettings.isLightScreenReadingEnabled(.standard)
                request.recognitionLevel = light ? .fast : .accurate
                request.usesLanguageCorrection = !light
                request.minimumTextHeight = 0.008

                try VNImageRequestHandler(cgImage: preparedImage, options: [:]).perform([request])

                // Keep each line's confidence (from its top candidate) so the hygiene pass can drop
                // the recognizer's weakest guesses; the joined `text` below is for logging and the
                // window-title fallback only.
                return (request.results ?? [])
                    .sorted {
                        if Swift.abs($0.boundingBox.minY - $1.boundingBox.minY) > 0.02 {
                            return $0.boundingBox.minY > $1.boundingBox.minY
                        }

                        return $0.boundingBox.minX < $1.boundingBox.minX
                    }
                    .compactMap { observation -> OCRTextHygiene.OCRLine? in
                        guard let candidate = observation.topCandidates(1).first else { return nil }
                        let trimmed = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmed.isEmpty else { return nil }
                        return OCRTextHygiene.OCRLine(
                            text: trimmed, confidence: candidate.confidence, boundingBox: observation.boundingBox
                        )
                    }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch OCRWorkGate.Failure.busy {
            log("ocr-refused-busy elapsed_ms=\(Self.elapsedMilliseconds(since: startedAt))")
            throw ScreenTextExtractionError.ocrUnavailable
        } catch OCRWorkGate.Failure.timedOut {
            log("ocr-timed-out elapsed_ms=\(Self.elapsedMilliseconds(since: startedAt))")
            throw ScreenTextExtractionError.ocrUnavailable
        } catch {
            log("ocr-failed elapsed_ms=\(Self.elapsedMilliseconds(since: startedAt)) reason=\(error.localizedDescription)")
            throw ScreenTextExtractionError.ocrFailed(error.localizedDescription)
        }

        let joinedText = recognizedLines.map(\.text).joined(separator: "\n")
        let cappedText = String(joinedText.prefix(maxRecognizedCharacters))

        guard !cappedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            log("ocr-empty elapsed_ms=\(Self.elapsedMilliseconds(since: startedAt)) lines=\(recognizedLines.count)")
            throw ScreenTextExtractionError.noRecognizedText
        }

        log(
            "ocr-success elapsed_ms=\(Self.elapsedMilliseconds(since: startedAt)) lines=\(recognizedLines.count) " +
                "chars=\(cappedText.count) preview=\(preview(cappedText))"
        )
        return ExtractedScreenText(text: cappedText, lineCount: recognizedLines.count, lines: recognizedLines)
    }

    private static func elapsedMilliseconds(since startedAt: Date) -> Int {
        Int(Date().timeIntervalSince(startedAt) * 1000)
    }

    /// Keeps OCR latency bounded on very large Retina windows by scaling the image to a reasonable
    /// max dimension before text recognition.
    nonisolated private func downsampledImageIfNeeded(_ image: CGImage) -> CGImage {
        let width = image.width
        let height = image.height
        let largestDimension = max(width, height)

        guard largestDimension > maxImageDimension else {
            return image
        }

        let scale = CGFloat(maxImageDimension) / CGFloat(largestDimension)
        let targetWidth = max(Int(CGFloat(width) * scale), 1)
        let targetHeight = max(Int(CGFloat(height) * scale), 1)
        let colorSpace = image.colorSpace ?? CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: nil,
            width: targetWidth,
            height: targetHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }

        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        return context.makeImage() ?? image
    }

    private func log(_ message: String) {
        // OCR log messages include preview text from the user's screen. Route them through
        // the debug gate so they only appear when the developer explicitly opts in.
        CotabbyDebugOptions.log(message)
    }

    private func preview(_ text: String) -> String {
        let compact = text.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if compact.count <= 80 {
            return compact
        }

        let cut = compact.index(compact.startIndex, offsetBy: 80)
        return "\(compact[..<cut])..."
    }
}
