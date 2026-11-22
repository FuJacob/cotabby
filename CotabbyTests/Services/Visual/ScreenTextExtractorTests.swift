import CoreGraphics
import XCTest
@testable import Cotabby

/// Direct tests for the Vision-backed OCR service boundary.
///
/// Screenshot-context tests usually stub OCR so they can focus on orchestration. This file exists
/// separately because the crash happened inside `ScreenTextExtractor`'s callback-to-async bridge,
/// which only runs when the real Vision request path is exercised.
final class ScreenTextExtractorTests: XCTestCase {
    func test_extractText_tinyImagesReturnNoRecognizedTextWithoutCrashing() async throws {
        let extractor = ScreenTextExtractor()

        for dimension in [1, 2] {
            let image = try makeSolidImage(width: dimension, height: dimension)
            await assertNoRecognizedText(from: image, extractor: extractor)
        }
    }

    func test_extractText_blankNormalImageReturnsNoRecognizedText() async throws {
        let image = try makeSolidImage(width: 128, height: 128)

        await assertNoRecognizedText(from: image, extractor: ScreenTextExtractor())
    }

    // MARK: - OCRWorkGate
    //
    // These pin the fix for a production hang: one Vision request wedged inside TextRecognition,
    // every later OCR pass parked its own GCD thread behind it, and after ~44 of them the process
    // hit libdispatch's thread limit, which starved AppKit's activation callbacks (the menu bar
    // popover stopped dismissing and stopped taking clicks). The gate must keep a wedged pass to one
    // thread and must never let a caller wait on it forever.
    //
    // Timing rule for these tests: the caller's timeout clock starts when `run` is called, but the
    // gate's running deadline only starts when the work actually begins on the serial queue, which
    // can be arbitrarily late on a loaded machine. So a test never infers gate state from elapsed
    // time since the call; it waits for the work to report that it started, and waits out the
    // running deadline measured from that start. Every blocked pass is released in `defer`, so an
    // early failure cannot leave the gate's thread parked for the rest of the run.

    func test_gate_returnsTheWorkResult() async throws {
        let gate = OCRWorkGate(label: "test.ocr.result")
        let value = try await gate.run(timeout: 5) { 42 }
        XCTAssertEqual(value, 42)
    }

    func test_gate_timesOutACallerWhoseWorkIsStuck() async throws {
        let gate = OCRWorkGate(label: "test.ocr.timeout")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }

        let startedAt = Date()
        do {
            _ = try await gate.run(timeout: 0.2) { release.wait(); return 1 }
            XCTFail("A stuck pass must not keep its caller waiting.")
        } catch OCRWorkGate.Failure.timedOut {
            XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
        }
    }

    func test_gate_failsFastWhileAPassIsWedgedInsteadOfQueueingAnotherThread() async throws {
        let gate = OCRWorkGate(label: "test.ocr.wedged")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let wedgedStart = LockedDate()
        let secondRan = LockedFlag()
        // Long enough that the queue starts the pass before its caller gives up (work whose caller
        // already timed out is skipped, and then nothing would be wedged).
        let wedgedTimeout: TimeInterval = 0.5

        let wedged = Task {
            try await gate.run(timeout: wedgedTimeout) { wedgedStart.set(Date()); release.wait(); return 1 }
        }
        let startedAt = try await waitForStart(of: wedgedStart)
        // The gate stamps its deadline just before calling the work, so the deadline is at most
        // `startedAt + wedgedTimeout`; past that instant the pass is overrunning by construction.
        try await waitUntil(startedAt.addingTimeInterval(wedgedTimeout + 0.05))

        let refusedAt = Date()
        do {
            _ = try await gate.run(timeout: 5) { secondRan.set(); return 2 }
            XCTFail("While a pass is past its timeout, new passes must be refused.")
        } catch OCRWorkGate.Failure.busy {
            XCTAssertLessThan(Date().timeIntervalSince(refusedAt), 1, "Refusal must not wait out the timeout.")
        }

        // Once the wedged pass finally returns, the gate admits work again, and the refused pass
        // never ran late.
        release.signal()
        _ = try? await wedged.value
        let value = try await waitForAdmission(gate)
        XCTAssertEqual(value, 3)
        XCTAssertFalse(secondRan.isSet)
    }

    func test_gate_skipsQueuedWorkWhoseCallerAlreadyGaveUp() async throws {
        let gate = OCRWorkGate(label: "test.ocr.abandoned")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let firstStart = LockedDate()
        let queuedRan = LockedFlag()

        // A long pass (well inside its timeout) occupies the serial queue. Waiting for it to start
        // guarantees the next item really queues behind it rather than running first.
        let first = Task { try await gate.run(timeout: 30) { firstStart.set(Date()); release.wait(); return 1 } }
        _ = try await waitForStart(of: firstStart)

        // A second caller queues behind it and times out before its turn. The first pass cannot
        // finish until released, so this caller's turn cannot come early however slow the machine.
        do {
            _ = try await gate.run(timeout: 0.1) { queuedRan.set(); return 2 }
            XCTFail("Expected the queued caller to time out.")
        } catch OCRWorkGate.Failure.timedOut {}

        release.signal()
        _ = try await first.value
        _ = try await gate.run(timeout: 5) { 0 } // drains the queue past the abandoned item
        XCTAssertFalse(queuedRan.isSet, "Work for a caller that already gave up must not run.")
    }

    func test_gate_cancellingTheCallerStopsItsWait() async throws {
        let gate = OCRWorkGate(label: "test.ocr.cancel")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        let workStart = LockedDate()

        let task = Task { try await gate.run(timeout: 30) { workStart.set(Date()); release.wait(); return 1 } }
        // Cancel only once the pass is running, so this exercises a caller waiting on live work
        // rather than one cancelled before it reached the gate.
        _ = try await waitForStart(of: workStart)
        task.cancel()

        let cancelledAt = Date()
        do {
            _ = try await task.value
            XCTFail("Expected cancellation.")
        } catch is CancellationError {
            XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 2)
        }
    }

    private func waitForAdmission(_ gate: OCRWorkGate) async throws -> Int {
        for _ in 0..<100 {
            if let value = try? await gate.run(timeout: 5, { 3 }) { return value }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        throw OCRWorkGate.Failure.busy
    }

    /// Polls (without blocking a cooperative thread) until gated work records that it started.
    /// Bounded so a pass the gate never started fails the test instead of hanging it.
    private func waitForStart(
        of start: LockedDate,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> Date {
        let giveUpAt = Date().addingTimeInterval(10)
        while Date() < giveUpAt {
            if let startedAt = start.value { return startedAt }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        return try XCTUnwrap(start.value, "Gated work never started on the gate's queue.", file: file, line: line)
    }

    /// Sleeps until wall-clock time is strictly past `instant`; a single sleep can wake early.
    private func waitUntil(_ instant: Date) async throws {
        while Date() <= instant {
            let remaining = max(instant.timeIntervalSinceNow, 0.001)
            try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
    }

    private func assertNoRecognizedText(
        from image: CGImage,
        extractor: ScreenTextExtractor,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await extractor.extractText(from: image)
            XCTFail("Expected OCR to report no recognized text.", file: file, line: line)
        } catch ScreenTextExtractionError.noRecognizedText {
            // Expected: blank or degenerate screenshots should be treated as unavailable context.
        } catch {
            XCTFail("Expected noRecognizedText, got \(error).", file: file, line: line)
        }
    }

    private func makeSolidImage(width: Int, height: Int) throws -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = try XCTUnwrap(
            CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        )
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }
}

/// Thread-safe flag for observing whether gated work ran on the gate's queue.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

/// Thread-safe slot for the moment gated work started, written on the gate's queue and read by
/// the test's polling loop.
private final class LockedDate: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Date?

    var value: Date? { lock.lock(); defer { lock.unlock() }; return stored }
    func set(_ date: Date) { lock.lock(); stored = date; lock.unlock() }
}
