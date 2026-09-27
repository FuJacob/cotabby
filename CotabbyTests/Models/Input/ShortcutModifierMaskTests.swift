import CoreGraphics
import Foundation
import XCTest
@testable import Cotabby

/// Tests for the four-bit shortcut modifier mask: reduction from raw `CGEventFlags` (which carry
/// unrelated caps-lock/fn/keypad bits that must not affect shortcut equality) and the custom scalar
/// Codable form that per-app shortcut overrides persist in UserDefaults.
final class ShortcutModifierMaskTests: XCTestCase {
    func test_eventFlags_mapsEachHonoredModifierToItsBit() {
        let cases: [(flags: CGEventFlags, expected: ShortcutModifierMask, name: String)] = [
            (.maskCommand, .command, "command"),
            (.maskShift, .shift, "shift"),
            (.maskAlternate, .option, "option"),
            (.maskControl, .control, "control"),
            ([.maskCommand, .maskShift, .maskAlternate, .maskControl], [.command, .shift, .option, .control], "all four"),
            ([], [], "no modifiers")
        ]

        for testCase in cases {
            XCTAssertEqual(ShortcutModifierMask(eventFlags: testCase.flags), testCase.expected, testCase.name)
        }
    }

    func test_eventFlags_discardsBitsThatMustNotParticipateInShortcutEquality() {
        // Caps lock, fn, and numeric-pad markers ride along on ordinary key presses; if they leaked
        // into the mask, Tab with caps lock on would stop matching the Tab accept binding.
        let noisy: CGEventFlags = [.maskShift, .maskAlphaShift, .maskSecondaryFn, .maskNumericPad]

        XCTAssertEqual(ShortcutModifierMask(eventFlags: noisy), .shift)
    }

    func test_codable_encodesAsBareScalarRawValue() throws {
        let mask: ShortcutModifierMask = [.command, .option]

        let data = try JSONEncoder().encode(mask)

        // command (1 << 0) | option (1 << 2) == 5, stored as a plain number rather than a keyed object.
        XCTAssertEqual(String(decoding: data, as: UTF8.self), "5")
    }

    func test_codable_decodesPersistedScalar() throws {
        let decoded = try JSONDecoder().decode(ShortcutModifierMask.self, from: Data("10".utf8))

        // 10 == shift (1 << 1) | control (1 << 3).
        XCTAssertEqual(decoded, [.shift, .control])
    }
}
