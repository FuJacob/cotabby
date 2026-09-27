import AppKit
import XCTest
@testable import Cotabby

/// Pins `ShortcutModifierMask(nsEventFlags:)`, the bridge the key recorder uses to turn AppKit
/// modifier flags into the stored 4-bit mask. It must agree with the `CGEventFlags` bridge that the
/// input monitor uses at match time, or a recorded shortcut would never match the live keystroke.
final class ShortcutModifierMaskNSEventFlagsTests: XCTestCase {
    func test_eachModifierMapsToItsMaskBit() {
        let cases: [(name: String, flags: NSEvent.ModifierFlags, expected: ShortcutModifierMask)] = [
            ("command", .command, .command),
            ("shift", .shift, .shift),
            ("option", .option, .option),
            ("control", .control, .control),
            ("all four", [.command, .shift, .option, .control], [.command, .shift, .option, .control])
        ]
        for testCase in cases {
            XCTAssertEqual(ShortcutModifierMask(nsEventFlags: testCase.flags), testCase.expected, testCase.name)
        }
    }

    func test_nonShortcutFlagsAreDropped() {
        // Caps Lock, Fn, and the numeric-pad bit ride along on real events but are not part of a
        // stored shortcut, so they must not leak into the mask.
        XCTAssertEqual(ShortcutModifierMask(nsEventFlags: [.capsLock, .function, .numericPad]), [])
        XCTAssertEqual(ShortcutModifierMask(nsEventFlags: [.option, .capsLock]), .option)
    }

    func test_agreesWithTheCGEventFlagsBridge() {
        let pairs: [(ns: NSEvent.ModifierFlags, cg: CGEventFlags)] = [
            (.command, .maskCommand),
            (.shift, .maskShift),
            (.option, .maskAlternate),
            (.control, .maskControl),
            ([.command, .option], [.maskCommand, .maskAlternate])
        ]
        for pair in pairs {
            XCTAssertEqual(
                ShortcutModifierMask(nsEventFlags: pair.ns),
                ShortcutModifierMask(eventFlags: pair.cg),
                "\(pair.ns) vs \(pair.cg)"
            )
        }
    }
}
