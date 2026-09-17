import XCTest
@testable import Cotabby

/// Byte-level tests for the boundary between constrained native sampling and streamed ghost text.
/// Tokens need not align with either words or Unicode scalars, and replay must stay invisible.
final class TokenHealingBufferTests: XCTestCase {
    func testEmptyReplayStreamsCumulativeText() {
        var buffer = TokenHealingBuffer(replayedPrefix: [])
        XCTAssertTrue(buffer.replayComplete)
        XCTAssertEqual(buffer.append(tokenBytes: Array("Hello".utf8)), "Hello")
        XCTAssertEqual(buffer.append(tokenBytes: Array(" world".utf8)), "Hello world")
        XCTAssertEqual(buffer.text, "Hello world")
    }

    func testLargerVocabularyTokenPublishesOnlyItsUnwrittenSuffix() {
        var buffer = TokenHealingBuffer(replayedPrefix: Array("sched".utf8))
        XCTAssertEqual(buffer.append(tokenBytes: Array("schedule".utf8)), "ule")
        XCTAssertTrue(buffer.replayComplete)
        XCTAssertEqual(buffer.text, "ule")
    }

    func testReplayCanSpanSeveralTokens() {
        var buffer = TokenHealingBuffer(replayedPrefix: Array("sched".utf8))
        XCTAssertNil(buffer.append(tokenBytes: Array("sc".utf8)))
        XCTAssertFalse(buffer.replayComplete)
        XCTAssertNil(buffer.append(tokenBytes: Array("h".utf8)))
        XCTAssertEqual(buffer.text, "")
        XCTAssertEqual(buffer.append(tokenBytes: Array("edule".utf8)), "ule")
        XCTAssertTrue(buffer.replayComplete)
    }

    func testExactReplayPublishesNothingUntilNewTextArrives() {
        var buffer = TokenHealingBuffer(replayedPrefix: Array("sched".utf8))
        XCTAssertNil(buffer.append(tokenBytes: Array("sched".utf8)))
        XCTAssertTrue(buffer.replayComplete)
        XCTAssertFalse(buffer.hasVisibleBytes)
        XCTAssertEqual(buffer.text, "")
        XCTAssertEqual(buffer.append(tokenBytes: Array("ule".utf8)), "ule")
    }

    func testTrailingSpaceReplayPreservesOnlyNewWhitespace() {
        var buffer = TokenHealingBuffer(replayedPrefix: Array(" ".utf8))
        XCTAssertEqual(buffer.append(tokenBytes: Array(" word\n\t".utf8)), "word\n\t")
        XCTAssertEqual(buffer.text, "word\n\t")
    }

    func testMismatchPermanentlyFailsClosed() {
        var buffer = TokenHealingBuffer(replayedPrefix: Array("sched".utf8))
        XCTAssertNil(buffer.append(tokenBytes: Array("sc".utf8)))
        XCTAssertNil(buffer.append(tokenBytes: Array("xanything".utf8)))
        XCTAssertTrue(buffer.hasReplayMismatch)
        XCTAssertFalse(buffer.replayComplete)
        XCTAssertEqual(buffer.text, "")
        XCTAssertNil(buffer.append(tokenBytes: Array("hedule".utf8)))
        XCTAssertNil(buffer.append(tokenBytes: Array(" new text".utf8)))
        XCTAssertEqual(buffer.text, "")
    }

    func testCanonicallyEquivalentTextDoesNotBypassExactByteReplay() {
        var buffer = TokenHealingBuffer(replayedPrefix: Array("é".utf8))
        // Swift String equality treats these as equal; token replay must not. The editor contains
        // the composed bytes, so silently accepting decomposed bytes would violate native state.
        XCTAssertEqual("é", "e\u{301}")
        XCTAssertNil(buffer.append(tokenBytes: Array("e\u{301}clair".utf8)))
        XCTAssertTrue(buffer.hasReplayMismatch)
    }

    func testReplayTokenMayContainOnlyTheLastByteOfAUnicodeScalar() {
        var buffer = TokenHealingBuffer(replayedPrefix: [0xA9])
        XCTAssertEqual(buffer.append(tokenBytes: [0xA9] + Array("clair".utf8)), "clair")
        XCTAssertTrue(buffer.replayComplete)
    }

    func testSplitUTF8AfterReplayIsRetainedUntilComplete() {
        var buffer = TokenHealingBuffer(replayedPrefix: Array("a".utf8))
        XCTAssertFalse(buffer.hasVisibleBytes)
        XCTAssertNil(buffer.append(tokenBytes: [0x61, 0xF0, 0x9F]))
        XCTAssertTrue(buffer.replayComplete)
        XCTAssertTrue(buffer.hasVisibleBytes, "the token contains new output even before it can be displayed")
        XCTAssertEqual(buffer.text, "")
        XCTAssertEqual(buffer.append(tokenBytes: [0x98, 0x80]), "😀")
        XCTAssertFalse(buffer.text.contains("\u{FFFD}"))
    }

    func testSplitScalarKeepsLastCompleteVisibleTextUntilItFinishes() {
        var buffer = TokenHealingBuffer(replayedPrefix: [])
        XCTAssertEqual(buffer.append(tokenBytes: Array("Hi ".utf8)), "Hi ")
        XCTAssertNil(buffer.append(tokenBytes: [0xF0, 0x9F]))
        XCTAssertEqual(buffer.text, "Hi ")
        XCTAssertEqual(buffer.append(tokenBytes: [0x98, 0x80]), "Hi 😀")
    }

    func testInvalidUTF8NeverPublishesReplacementCharacters() {
        var buffer = TokenHealingBuffer(replayedPrefix: [])
        XCTAssertNil(buffer.append(tokenBytes: [0xFF]))
        XCTAssertNil(buffer.append(tokenBytes: Array("text".utf8)))
        XCTAssertEqual(buffer.text, "")
    }

    func testEmptyTokenDoesNotCreateAVisibleUpdate() {
        var buffer = TokenHealingBuffer(replayedPrefix: [])
        XCTAssertNil(buffer.append(tokenBytes: []))
        XCTAssertEqual(buffer.append(tokenBytes: Array("word".utf8)), "word")
        XCTAssertNil(buffer.append(tokenBytes: []))
        XCTAssertEqual(buffer.text, "word")
    }

    func testMaximumCandidateFitsTheReplayAllowanceEvenWithByteFallback() {
        XCTAssertEqual(TokenHealingBuffer.maximumReplayTokens, 16)
        XCTAssertLessThanOrEqual(
            TokenHealingBuffer.maximumHealedTokenBytes,
            TokenHealingBuffer.maximumReplayTokens
        )
        let prefix = [UInt8](repeating: 0x61, count: TokenHealingBuffer.maximumHealedTokenBytes)
        var buffer = TokenHealingBuffer(replayedPrefix: prefix)
        for byte in prefix {
            XCTAssertNil(buffer.append(tokenBytes: [byte]))
        }
        XCTAssertTrue(buffer.replayComplete)
        XCTAssertEqual(buffer.append(tokenBytes: Array("fter".utf8)), "fter")
    }
}
