import XCTest
@testable import Cotabby

/// What a new field inherits from the last settled field in the same host, and what it never does.
final class HostFaceMemoryTests: XCTestCase {
    private func key(
        _ bundle: String = "com.anthropic.claudefordesktop",
        url: String? = nil,
        browser: Bool = false,
        size: CGFloat? = 14,
        caret: CGFloat = 19,
        multiplier: CGFloat = 1
    ) -> HostFaceMemory.Key? {
        HostFaceMemory.Key(
            bundleIdentifier: bundle, urlString: url, isBrowser: browser,
            reportedSize: size, caretHeight: caret, sizeMultiplier: multiplier
        )
    }

    /// Measured 2026-09-10: Claude's composer reports 14 and paints Anthropic Sans at 15.4; a new
    /// field starts in the face the last one settled on instead of at the reported 14.
    func testANewFieldInTheSameHostStartsInTheSettledFace() throws {
        var memory = HostFaceMemory()
        let face = HostFaceMemory.Face(fontName: "AnthropicSansVariable-TextRegular", pointSize: 15.4)
        memory.record(face, for: try XCTUnwrap(key()))
        XCTAssertEqual(memory.face(for: try XCTUnwrap(key())), face)
        XCTAssertEqual(memory.face(for: try XCTUnwrap(key(caret: 19.4))), face, "a caret box within rounding is the same style")
    }

    func testAnotherStyleOrHostKeepsItsOwnFace() throws {
        var memory = HostFaceMemory()
        memory.record(.init(fontName: "A", pointSize: 15.4), for: try XCTUnwrap(key()))
        XCTAssertNil(memory.face(for: try XCTUnwrap(key(size: 16))))
        XCTAssertNil(memory.face(for: try XCTUnwrap(key("com.openai.chat"))))
        XCTAssertNil(memory.face(for: try XCTUnwrap(key(multiplier: 1.2))))
    }

    /// Chromium's caret box wanders by a point from line to line (19 and 20 in the composer replica,
    /// 2026-09-10): with a reported size the caret box does not split the style; without one it is
    /// the only size signal and does, two points at a time.
    func testTheCaretBoxSplitsAStyleOnlyWhenTheHostReportsNoSize() {
        XCTAssertEqual(key(caret: 19), key(caret: 20))
        XCTAssertEqual(key(caret: 19), key(caret: 24), "a reported size names the style")
        XCTAssertEqual(key(size: nil, caret: 19), key(size: nil, caret: 20))
        XCTAssertNotEqual(key(size: nil, caret: 19), key(size: nil, caret: 24))
    }

    func testABrowserKeysOnThePageOrigin() throws {
        var memory = HostFaceMemory()
        let site = try XCTUnwrap(key("com.google.Chrome", url: "http://127.0.0.1:8766/composer.html", browser: true))
        memory.record(.init(fontName: "A", pointSize: 15.4), for: site)
        let samePage = try XCTUnwrap(key("com.google.Chrome", url: "http://127.0.0.1:8766/other.html", browser: true))
        XCTAssertEqual(memory.face(for: samePage)?.fontName, "A")
        XCTAssertNil(memory.face(for: try XCTUnwrap(key("com.google.Chrome", url: "https://example.com/", browser: true))))
        XCTAssertNil(key("com.google.Chrome", url: nil, browser: true), "a browser page with no known origin is not remembered")
    }

    func testTheFirstStylesRecordedAreForgottenPastCapacity() throws {
        var memory = HostFaceMemory()
        for step in 0...HostFaceMemory.capacity {
            memory.record(.init(fontName: "A", pointSize: 10), for: try XCTUnwrap(key(size: CGFloat(10 + step))))
        }
        XCTAssertNil(memory.face(for: try XCTUnwrap(key(size: 10))))
        XCTAssertNotNil(memory.face(for: try XCTUnwrap(key(size: CGFloat(10 + HostFaceMemory.capacity)))))
    }

    /// A paragraph's first line has no line above to measure; the pitch a field of the same style
    /// measured stands in for the caret box (Claude's composer: 23pt lines, a 19pt caret box).
    func testTheLinePitchIsRememberedBesideTheFace() throws {
        var memory = HostFaceMemory()
        let composer = try XCTUnwrap(key())
        XCTAssertNil(memory.pitch(for: composer))
        memory.recordPitch(23.1, for: composer)
        XCTAssertEqual(memory.pitch(for: composer) ?? 0, 23.1, accuracy: 0.001)
        XCTAssertNil(memory.face(for: composer), "a pitch alone remembers no face")
        memory.record(.init(fontName: "A", pointSize: 15.4), for: composer)
        XCTAssertEqual(memory.pitch(for: composer) ?? 0, 23.1, accuracy: 0.001, "recording the face keeps the pitch")
        memory.recordPitch(0, for: composer)
        XCTAssertEqual(memory.pitch(for: composer) ?? 0, 23.1, accuracy: 0.001, "a zero pitch is no measurement")
        XCTAssertNil(memory.pitch(for: try XCTUnwrap(key("com.openai.chat"))))
    }

    func testOnlyASettledFaceIsRememberedAndOnlyAnUnmeasuredOneYields() {
        XCTAssertTrue(HostFaceMemory.isSettled(.pixelMatched, fieldAdoptedSample: false))
        XCTAssertTrue(HostFaceMemory.isSettled(.hostSizeScaledSystem, fieldAdoptedSample: true))
        XCTAssertFalse(HostFaceMemory.isSettled(.hostSizeScaledSystem, fieldAdoptedSample: false))
        XCTAssertFalse(HostFaceMemory.isSettled(.hostSizeSystem, fieldAdoptedSample: true))
        XCTAssertTrue(HostFaceMemory.yieldsToMemory(.hostSizeSystem))
        XCTAssertTrue(HostFaceMemory.yieldsToMemory(.caretDerived))
        XCTAssertTrue(HostFaceMemory.yieldsToMemory(.hostSizeMatchedFamily))
        XCTAssertFalse(HostFaceMemory.yieldsToMemory(.pixelMatched))
        XCTAssertFalse(HostFaceMemory.yieldsToMemory(.hostFace))
    }

    /// Kept across launches: the first field after one starts in the face its host last settled on.
    func testTheMemorySurvivesARestart() throws {
        var memory = HostFaceMemory()
        let claude = try XCTUnwrap(key("com.anthropic.claudefordesktop", size: 14, caret: 19))
        let obsidian = try XCTUnwrap(key("md.obsidian", size: nil, caret: 20))
        XCTAssertTrue(memory.record(.init(fontName: "AnthropicSansVariable-TextRegular", pointSize: 15.336), for: claude))
        XCTAssertFalse(memory.record(.init(fontName: "AnthropicSansVariable-TextRegular", pointSize: 15.336), for: claude), "the same face again changes nothing")
        XCTAssertTrue(memory.recordPitch(23, for: claude))
        XCTAssertTrue(memory.record(.init(fontName: ".AppleSystemUIFont", pointSize: 16), for: obsidian))

        let restored = HostFaceMemory(restoring: memory.encoded())
        XCTAssertEqual(restored.face(for: claude), .init(fontName: "AnthropicSansVariable-TextRegular", pointSize: 15.336))
        XCTAssertEqual(restored.pitch(for: claude), 23)
        XCTAssertEqual(restored.face(for: obsidian), .init(fontName: ".AppleSystemUIFont", pointSize: 16))
        XCTAssertNil(HostFaceMemory(restoring: Data("not json".utf8)).face(for: claude))
        XCTAssertNil(HostFaceMemory(restoring: nil).face(for: claude))
    }

    func testABrowserPagesStyleIsNotKeptAcrossLaunches() throws {
        var memory = HostFaceMemory()
        let page = try XCTUnwrap(key("com.google.Chrome", url: "https://mail.example.com/inbox", browser: true, size: 15))
        let app = try XCTUnwrap(key("md.obsidian", size: nil, caret: 20))
        memory.record(.init(fontName: "Georgia", pointSize: 15), for: page)
        memory.record(.init(fontName: ".AppleSystemUIFont", pointSize: 16), for: app)
        XCTAssertTrue(page.isPageScoped)
        let restored = HostFaceMemory(restoring: memory.encoded())
        XCTAssertNil(restored.face(for: page), "the origin stays out of the saved memory")
        XCTAssertEqual(restored.face(for: app)?.pointSize, 16)
    }
}

