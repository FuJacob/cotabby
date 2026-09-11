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
        // A stand-in sized along its own line by the caret's advance is the host's size.
        XCTAssertTrue(HostFaceMemory.isSettled(.hostAdvanceFitted, fieldAdoptedSample: false))
        XCTAssertFalse(HostFaceMemory.yieldsToMemory(.hostAdvanceFitted))
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

    /// An earlier version kept browser pages' styles in the preferences (the dev app's held a test
    /// page's, 2026-09-11): restoring drops them, so an origin neither comes back into use nor is
    /// written out again, while the app's own styles restore as saved.
    func testAPageStyleLeftByAnEarlierVersionIsDroppedOnRestore() throws {
        let stored = """
        [{"key":{"host":"com.google.Chrome|127.0.0.1:8766","reportedSize":56,"caretHeight":-1,"sizeMultiplier":100},\
        "face":{"fontName":".AppleSystemUIFont","pointSize":15.7}},\
        {"key":{"host":"com.anthropic.claudefordesktop","reportedSize":-1,"caretHeight":10,"sizeMultiplier":100},\
        "face":{"fontName":"AnthropicSansVariable-TextRegular","pointSize":15.1585}}]
        """
        let restored = HostFaceMemory(restoring: Data(stored.utf8))
        let page = try XCTUnwrap(key("com.google.Chrome", url: "http://127.0.0.1:8766/composer.html", browser: true, size: 14))
        XCTAssertNil(restored.face(for: page))
        let claude = try XCTUnwrap(key(size: nil, caret: 19))
        XCTAssertEqual(restored.face(for: claude)?.pointSize, 15.1585)
        XCTAssertNil(restored.face(for: claude)?.advanceMeasured, "a style saved before the mark existed has none")
        let written = String(decoding: try XCTUnwrap(restored.encoded()), as: UTF8.self)
        XCTAssertFalse(written.contains("127.0.0.1"))
    }

    /// The entries found in the dev app's memory 2026-09-11: 72pt for Obsidian's 16pt text (one-line
    /// runs three lines apart) and 12.5pt for Claude's 15.3pt (a capital's top bar read as a
    /// baseline) are misreads; restoring drops those pitches, keeps their faces, and keeps Claude's
    /// real 22pt.
    func testAPitchNoTextOfItsSizeHasIsDroppedOnRestore() throws {
        let stored = """
        [{"pitch":72,"key":{"sizeMultiplier":100,"reportedSize":-1,"host":"md.obsidian","caretHeight":10},\
        "face":{"fontName":".AppleSystemUIFont","pointSize":15.997890573500335,"advanceMeasured":true}},\
        {"pitch":12.5,"key":{"sizeMultiplier":100,"reportedSize":-1,"host":"com.anthropic.claudefordesktop","caretHeight":8},\
        "face":{"advanceMeasured":true,"fontName":"AnthropicSansVariable-TextRegular","pointSize":15.32483523774129}},\
        {"pitch":22,"key":{"sizeMultiplier":100,"reportedSize":-1,"host":"com.anthropic.claudefordesktop","caretHeight":10},\
        "face":{"advanceMeasured":true,"fontName":"AnthropicSansVariable-TextRegular","pointSize":15.32483523774129}}]
        """
        let restored = HostFaceMemory(restoring: Data(stored.utf8))
        let obsidian = try XCTUnwrap(key("md.obsidian", size: nil, caret: 20))
        XCTAssertNil(restored.pitch(for: obsidian))
        XCTAssertNotNil(restored.face(for: obsidian), "the face stays")
        XCTAssertNil(restored.pitch(for: try XCTUnwrap(key(size: nil, caret: 16))))
        XCTAssertEqual(restored.pitch(for: try XCTUnwrap(key(size: nil, caret: 19))), 22)
    }

    func testAPitchIsPlausibleFromLineHeightOneToDoubleSpacing() {
        XCTAssertTrue(HostFaceMemory.isPlausiblePitch(22, pointSize: 15.325), "Claude's composer")
        XCTAssertTrue(HostFaceMemory.isPlausiblePitch(24, pointSize: 16), "Obsidian")
        XCTAssertTrue(HostFaceMemory.isPlausiblePitch(14, pointSize: 12), "TextEdit")
        XCTAssertTrue(HostFaceMemory.isPlausiblePitch(16, pointSize: 16), "line-height 1")
        XCTAssertTrue(HostFaceMemory.isPlausiblePitch(38, pointSize: 16), "double spacing")
        XCTAssertFalse(HostFaceMemory.isPlausiblePitch(72, pointSize: 16))
        XCTAssertFalse(HostFaceMemory.isPlausiblePitch(12.5, pointSize: 15.325))
        XCTAssertFalse(HostFaceMemory.isPlausiblePitch(20, pointSize: 0))
    }

    /// A size measured from the host's own caret advance keeps that mark across a launch, so the next
    /// field's short-strip match does not replace it (see `OverlayController.applyingHostAdvance`).
    func testAnAdvanceMeasuredSizeKeepsItsMarkAcrossALaunch() throws {
        var memory = HostFaceMemory()
        let claude = try XCTUnwrap(key(size: nil, caret: 19))
        memory.record(.init(fontName: "AnthropicSansVariable-TextRegular", pointSize: 15.345, advanceMeasured: true), for: claude)
        let restored = HostFaceMemory(restoring: memory.encoded())
        XCTAssertEqual(restored.face(for: claude)?.advanceMeasured, true)
        XCTAssertEqual(restored.face(for: claude)?.pointSize ?? 0, 15.345, accuracy: 0.0001)
    }
}

