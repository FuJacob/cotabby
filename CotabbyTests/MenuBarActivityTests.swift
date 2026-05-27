import XCTest
@testable import Cotabby

/// Verifies which pipeline states collapse into the single menu-bar busy signal. The debounce timing
/// lives in `MenuBarActivityModel`; these cover only the pure classification, which is the part most
/// likely to drift as the underlying state enums gain cases.
final class MenuBarActivityTests: XCTestCase {
    func test_allPipelinesIdleIsNotBusy() {
        XCTAssertFalse(MenuBarActivity.isBusy(runtime: .idle, completion: .idle, visual: .idle))
    }

    func test_runtimeStartingOrLoadingIsBusy() {
        XCTAssertTrue(MenuBarActivity.isBusy(runtime: .starting("…"), completion: .idle, visual: .idle))
        XCTAssertTrue(MenuBarActivity.isBusy(runtime: .loading("…"), completion: .idle, visual: .idle))
    }

    func test_runtimeReadyIdleFailedAreNotBusy() {
        XCTAssertFalse(MenuBarActivity.isBusy(runtime: .ready("…"), completion: .idle, visual: .idle))
        XCTAssertFalse(MenuBarActivity.isBusy(runtime: .failed("…"), completion: .idle, visual: .idle))
    }

    func test_completionGeneratingIsBusy() {
        XCTAssertTrue(MenuBarActivity.isBusy(runtime: .idle, completion: .generating, visual: .idle))
    }

    func test_completionDebouncingIsNotBusy() {
        // Debouncing means "still typing", not "working" — surfacing it would strobe the menu bar.
        XCTAssertFalse(MenuBarActivity.isBusy(runtime: .idle, completion: .debouncing, visual: .idle))
    }

    func test_completionTerminalStatesAreNotBusy() {
        XCTAssertFalse(MenuBarActivity.isBusy(runtime: .idle, completion: .disabled("…"), visual: .idle))
        XCTAssertFalse(
            MenuBarActivity.isBusy(runtime: .idle, completion: .ready(text: "x", latency: 0), visual: .idle)
        )
        XCTAssertFalse(MenuBarActivity.isBusy(runtime: .idle, completion: .failed("…"), visual: .idle))
    }

    func test_visualCaptureExtractSummarizeAreBusy() {
        XCTAssertTrue(MenuBarActivity.isBusy(runtime: .idle, completion: .idle, visual: .capturing))
        XCTAssertTrue(MenuBarActivity.isBusy(runtime: .idle, completion: .idle, visual: .extractingText))
        XCTAssertTrue(MenuBarActivity.isBusy(runtime: .idle, completion: .idle, visual: .summarizingText))
    }

    func test_visualTerminalStatesAreNotBusy() {
        XCTAssertFalse(MenuBarActivity.isBusy(runtime: .idle, completion: .idle, visual: .ready))
        XCTAssertFalse(MenuBarActivity.isBusy(runtime: .idle, completion: .idle, visual: .unavailable("…")))
        XCTAssertFalse(MenuBarActivity.isBusy(runtime: .idle, completion: .idle, visual: .failed("…")))
    }

    func test_anyBusyPipelineWinsOverIdleOthers() {
        XCTAssertTrue(MenuBarActivity.isBusy(runtime: .loading("…"), completion: .debouncing, visual: .ready))
    }
}
