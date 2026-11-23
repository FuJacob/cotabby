import XCTest
@testable import Cotabby

final class ChromiumPrimingPolicyTests: XCTestCase {
    // MARK: - Whether to prime

    func test_aProcessNeverSeenIsPrimed() {
        for isActivationEdge in [false, true] {
            for isElectronEditor in [false, true] {
                XCTAssertTrue(ChromiumPrimingPolicy.shouldPrime(
                    state: nil, isActivationEdge: isActivationEdge, isElectronEditor: isElectronEditor
                ))
            }
        }
    }

    /// A browser primed once stays primed: no write per poll, and none per app switch either.
    func test_aPrimedBrowserIsNotPrimedAgain() {
        XCTAssertFalse(ChromiumPrimingPolicy.shouldPrime(state: .primed, isActivationEdge: false, isElectronEditor: false))
        XCTAssertFalse(ChromiumPrimingPolicy.shouldPrime(state: .primed, isActivationEdge: true, isElectronEditor: false))
    }

    /// VS Code can accept the first write and stay dormant; re-asserting on activation wakes it.
    func test_aPrimedElectronEditorIsReassertedOnlyOnActivation() {
        XCTAssertTrue(ChromiumPrimingPolicy.shouldPrime(state: .primed, isActivationEdge: true, isElectronEditor: true))
        XCTAssertFalse(ChromiumPrimingPolicy.shouldPrime(state: .primed, isActivationEdge: false, isElectronEditor: true))
    }

    func test_anUnsupportedProcessIsNeverRetried() {
        for isActivationEdge in [false, true] {
            for isElectronEditor in [false, true] {
                XCTAssertFalse(ChromiumPrimingPolicy.shouldPrime(
                    state: .unsupported, isActivationEdge: isActivationEdge, isElectronEditor: isElectronEditor
                ))
            }
        }
    }

    // MARK: - Fallbacks

    private func fallbacks(
        chromium: Bool = false, codex: Bool = false, disabled: Bool = false
    ) -> [ChromiumPrimingPolicy.Fallback] {
        ChromiumPrimingPolicy.fallbacksAfterManualAccessibilityUnsupported(
            isChromiumBrowser: chromium, isCodexDesktop: codex, isEnhancedUserInterfaceDisabled: disabled
        )
    }

    func test_aChromiumBrowserFallsBackToEnhancedUserInterface() {
        XCTAssertEqual(fallbacks(chromium: true), [.enhancedUserInterface])
    }

    func test_theKillSwitchRemovesTheBrowserFallback() {
        XCTAssertEqual(fallbacks(chromium: true, disabled: true), [])
    }

    /// The kill switch is about window managers and browsers; Codex has no other way to be read.
    func test_codexFallsBackToAReadBackEvenWithTheKillSwitchOn() {
        XCTAssertEqual(fallbacks(codex: true), [.enhancedUserInterfaceConfirmedByReadBack])
        XCTAssertEqual(fallbacks(codex: true, disabled: true), [.enhancedUserInterfaceConfirmedByReadBack])
    }

    func test_anOrdinaryElectronAppHasNoFallback() {
        XCTAssertEqual(fallbacks(), [])
        XCTAssertEqual(fallbacks(disabled: true), [])
    }

    func test_theBrowserFallbackIsTriedBeforeTheReadBack() {
        XCTAssertEqual(fallbacks(chromium: true, codex: true), [.enhancedUserInterface, .enhancedUserInterfaceConfirmedByReadBack])
    }
}
