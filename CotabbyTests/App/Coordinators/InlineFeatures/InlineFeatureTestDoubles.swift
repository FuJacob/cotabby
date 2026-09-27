import Combine
import CoreGraphics
import XCTest
// `@preconcurrency`: the fakes conform to `@MainActor` protocols whose closure properties (e.g.
// `emojiCaptureKeyDecider`) are not `@Sendable`, which trips a cross-module Swift 6 sendability
// warning on the conformance. The suppression is test-only and does not affect production code.
@preconcurrency @testable import Cotabby

/// Shared fakes for the inline-command tests (`EmojiPickerController`, `MacroController`, and the
/// `InlineCommandCoordinator` that routes between them). Both controllers depend on the same narrow
/// seams (focus, input monitor, text inserter, floating panel), so one set of recording doubles keeps
/// the three suites describing the same world. Names carry an `InlineFeature` prefix because test
/// types share one module namespace.

/// Focus provider whose snapshot the test controls. `publish` drives the controller's focus sink
/// synchronously (a `PassthroughSubject` delivers on `send`), which is how focus-change teardown and
/// caret-following are exercised without Accessibility.
@MainActor
final class InlineFeatureFocusStub: SuggestionFocusProviding {
    private(set) var snapshot: FocusSnapshot
    private let subject = PassthroughSubject<FocusSnapshot, Never>()
    private(set) var refreshCount = 0

    var snapshotPublisher: AnyPublisher<FocusSnapshot, Never> { subject.eraseToAnyPublisher() }

    init(
        precedingText: String = "",
        isSecure: Bool = false,
        focusChangeSequence: UInt64 = 1,
        caretRect: CGRect = CGRect(x: 10, y: 20, width: 2, height: 18)
    ) {
        snapshot = Self.make(
            precedingText: precedingText,
            isSecure: isSecure,
            focusChangeSequence: focusChangeSequence,
            caretRect: caretRect
        )
    }

    func refreshNow() {
        refreshCount += 1
    }

    /// Replaces the current snapshot and pushes it through the publisher.
    func publish(
        precedingText: String = "",
        isSecure: Bool = false,
        focusChangeSequence: UInt64,
        caretRect: CGRect = CGRect(x: 10, y: 20, width: 2, height: 18)
    ) {
        snapshot = Self.make(
            precedingText: precedingText,
            isSecure: isSecure,
            focusChangeSequence: focusChangeSequence,
            caretRect: caretRect
        )
        subject.send(snapshot)
    }

    private static func make(
        precedingText: String,
        isSecure: Bool,
        focusChangeSequence: UInt64,
        caretRect: CGRect
    ) -> FocusSnapshot {
        let context = CotabbyTestFixtures.focusedInputSnapshot(
            caretRect: caretRect,
            precedingText: precedingText,
            isSecure: isSecure,
            focusChangeSequence: focusChangeSequence
        )
        return FocusSnapshot(
            applicationName: "TestApp",
            bundleIdentifier: "com.test.app",
            capability: .supported,
            context: context
        )
    }
}

/// Input-monitor slice with a rebindable word-accept key (Tab, 48, by default) that records every
/// interception toggle, so tests can assert the coordinator's "either feature is capturing" flag.
@MainActor
final class InlineFeatureInputMonitorStub: EmojiInputIntercepting {
    var emojiCaptureKeyDecider: (@MainActor (InputMonitorKeyEvent) -> InputMonitorAcceptTapDecision)?
    var wordAcceptKeyCode: CGKeyCode = 48
    private(set) var captureActiveCalls: [Bool] = []

    func setCaptureInterceptionActive(_ active: Bool) {
        captureActiveCalls.append(active)
    }

    func isWordAcceptKey(_ keyEvent: InputMonitorKeyEvent) -> Bool {
        keyEvent.keyCode == wordAcceptKeyCode
    }
}

/// Records each synthetic delete+insert the controllers request.
@MainActor
final class InlineFeatureRecordingInserter: EmojiTextInserting {
    struct Call: Equatable {
        let deleteCount: Int
        let text: String
    }

    private(set) var calls: [Call] = []

    func replace(deletingUTF16Count: Int, with text: String) -> Bool {
        calls.append(Call(deleteCount: deletingUTF16Count, text: text))
        return true
    }
}

/// Emoji panel fake that records what was shown, so tests can read the presented query, the match
/// glyphs, the caret anchor, and whether the panel is currently hidden.
@MainActor
final class InlineFeatureEmojiPanelStub: EmojiPickerPanelPresenting {
    struct Presentation: Equatable {
        let query: String
        let glyphs: [String]
        let selectedIndex: Int
        let caretRect: CGRect
    }

    var onSelectIndex: ((Int) -> Void)?
    var onClickOutside: (() -> Void)?
    private(set) var presentations: [Presentation] = []
    private(set) var selectedIndexUpdates: [Int] = []
    private(set) var isVisible = false

    func show(query: String, matches: [EmojiMatch], selectedIndex: Int, caretRect: CGRect) {
        presentations.append(Presentation(
            query: query,
            glyphs: matches.map(\.glyph),
            selectedIndex: selectedIndex,
            caretRect: caretRect
        ))
        isVisible = true
    }

    func setSelectedIndex(_ index: Int) {
        selectedIndexUpdates.append(index)
    }

    func hide() {
        isVisible = false
    }
}

/// Macro preview panel fake mirroring `InlineFeatureEmojiPanelStub`.
@MainActor
final class InlineFeaturePreviewPanelStub: InlinePreviewPresenting {
    struct Presentation: Equatable {
        let previewText: String
        let caretRect: CGRect
        let acceptKeyLabel: String?
    }

    var onClick: (() -> Void)?
    var onClickOutside: (() -> Void)?
    private(set) var presentations: [Presentation] = []
    private(set) var isVisible = false

    func show(previewText: String, caretRect: CGRect, acceptKeyLabel: String?) {
        presentations.append(Presentation(
            previewText: previewText,
            caretRect: caretRect,
            acceptKeyLabel: acceptKeyLabel
        ))
        isVisible = true
    }

    func hide() {
        isVisible = false
    }
}

/// Deterministic macro evaluator: a fixed query -> result table, so controller tests do not depend on
/// the real arithmetic/date/unit evaluators (those are covered by their own suites).
struct InlineFeatureMacroTable: MacroEvaluating {
    let results: [String: MacroResult]

    func evaluate(_ query: String) -> MacroResult? {
        results[query]
    }
}

/// Keystroke builders shared by the inline-command suites.
enum InlineFeatureKeys {
    static let tab: CGKeyCode = 48
    static let returnKey: CGKeyCode = 36
    static let escape: CGKeyCode = 53
    static let backspace: CGKeyCode = 51
    static let left: CGKeyCode = 123
    static let right: CGKeyCode = 124
    static let down: CGKeyCode = 125
    static let up: CGKeyCode = 126

    /// A printable keystroke. The controllers drive their query from `characters`, not the key code,
    /// so every character uses the same arbitrary non-special code.
    static let characterKeyCode: CGKeyCode = 41

    static func character(_ character: Character) -> CapturedInputEvent {
        CapturedInputEvent(kind: .textMutation, keyCode: characterKeyCode, characters: String(character), flags: [])
    }

    static func key(_ keyCode: CGKeyCode, flags: CGEventFlags = []) -> CapturedInputEvent {
        CapturedInputEvent(kind: .textMutation, keyCode: keyCode, characters: "", flags: flags)
    }

    static func tapEvent(_ keyCode: CGKeyCode) -> InputMonitorKeyEvent {
        InputMonitorKeyEvent(keyCode: keyCode)
    }
}

/// Enqueues a fence behind any work the controllers deferred with `DispatchQueue.main.async` (the
/// main queue is FIFO) and spins the run loop until it drains, so deferred replaces have run before
/// assertions. This is an ordering fence, not a timed sleep.
@MainActor
func drainInlineFeatureMainQueue() {
    let fence = XCTestExpectation(description: "drain main queue")
    DispatchQueue.main.async { fence.fulfill() }
    _ = XCTWaiter().wait(for: [fence], timeout: 1.0)
}
