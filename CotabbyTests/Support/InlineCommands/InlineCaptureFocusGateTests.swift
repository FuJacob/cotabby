import XCTest
@testable import Cotabby

/// Tests for where an inline-command capture may open and when an open capture still belongs to
/// its field.
@MainActor
final class InlineCaptureFocusGateTests: XCTestCase {
    private func snapshot(
        capability: FocusCapability = .supported,
        context: FocusedInputSnapshot?
    ) -> FocusSnapshot {
        FocusSnapshot(
            applicationName: "TestApp",
            bundleIdentifier: "com.test.app",
            capability: capability,
            context: context
        )
    }

    // MARK: - Opening

    func test_triggerableContext_isTheContextOfASupportedPlainField() {
        let context = CotabbyTestFixtures.focusedInputSnapshot(focusChangeSequence: 7)
        XCTAssertEqual(InlineCaptureFocusGate.triggerableContext(in: snapshot(context: context)), context)
    }

    func test_triggerableContext_isNilForSecureUnsupportedOrUnresolvedFocus() {
        let secure = CotabbyTestFixtures.focusedInputSnapshot(isSecure: true)
        XCTAssertNil(InlineCaptureFocusGate.triggerableContext(in: snapshot(context: secure)))

        let plain = CotabbyTestFixtures.focusedInputSnapshot()
        XCTAssertNil(InlineCaptureFocusGate.triggerableContext(
            in: snapshot(capability: .unsupported("No focused text input"), context: plain)
        ))

        XCTAssertNil(InlineCaptureFocusGate.triggerableContext(in: snapshot(context: nil)))
    }

    // MARK: - Continuing

    func test_continuingContext_followsTheSameFocusSequence() {
        let context = CotabbyTestFixtures.focusedInputSnapshot(focusChangeSequence: 7)
        XCTAssertEqual(
            InlineCaptureFocusGate.continuingContext(in: snapshot(context: context), focusChangeSequence: 7),
            context
        )
    }

    func test_continuingContext_endsWhenTheFieldChangesGoesSecureOrDisappears() {
        let moved = CotabbyTestFixtures.focusedInputSnapshot(focusChangeSequence: 8)
        XCTAssertNil(InlineCaptureFocusGate.continuingContext(in: snapshot(context: moved), focusChangeSequence: 7))

        let secure = CotabbyTestFixtures.focusedInputSnapshot(isSecure: true, focusChangeSequence: 7)
        XCTAssertNil(InlineCaptureFocusGate.continuingContext(in: snapshot(context: secure), focusChangeSequence: 7))

        XCTAssertNil(InlineCaptureFocusGate.continuingContext(in: snapshot(context: nil), focusChangeSequence: 7))
    }

    func test_continuingContext_doesNotRequireASupportedCapability() {
        // Capability can flicker while the user types into a field that already has a capture; only
        // a different field or a secure one ends it.
        let context = CotabbyTestFixtures.focusedInputSnapshot(focusChangeSequence: 7)
        XCTAssertEqual(
            InlineCaptureFocusGate.continuingContext(
                in: snapshot(capability: .unsupported("Missing caret bounds."), context: context),
                focusChangeSequence: 7
            ),
            context
        )
    }
}
