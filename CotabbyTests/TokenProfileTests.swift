import XCTest
@testable import Cotabby

/// Pure-function tests for per-token constrained-decoding metadata. Engine data is supplied through
/// stub closures, so every assertion is deterministic and no runtime is involved.
final class TokenProfileTests: XCTestCase {

    /// One token's stub data; a small struct rather than a tuple keeps the table readable and avoids
    /// a large-tuple lint warning.
    private struct Stub {
        let bytes: [UInt8]
        let control: Bool
        let eog: Bool
    }

    /// Builds a profile from a literal table of stub entries indexed by token id.
    private func makeProfile(_ table: [Stub]) -> TokenProfile {
        TokenProfile.build(
            vocabSize: table.count,
            bytesFor: { table[$0].bytes },
            isControl: { table[$0].control },
            isEndOfGeneration: { table[$0].eog }
        )
    }

    private func bytes(_ string: String) -> [UInt8] {
        Array(string.utf8)
    }

    func test_build_recordsVocabSizeAndBytes() {
        let profile = makeProfile([
            Stub(bytes: bytes("the"), control: false, eog: false),
            Stub(bytes: bytes(" dog"), control: false, eog: false)
        ])
        XCTAssertEqual(profile.vocabSize, 2)
        XCTAssertEqual(profile.bytes(for: 0), bytes("the"))
        XCTAssertEqual(profile.bytes(for: 1), bytes(" dog"))
    }

    func test_build_emptyVocab_producesEmptyProfile() {
        let profile = TokenProfile.build(
            vocabSize: 0,
            bytesFor: { _ in [] },
            isControl: { _ in false },
            isEndOfGeneration: { _ in false }
        )
        XCTAssertEqual(profile.vocabSize, 0)
    }

    func test_controlToken_isExcluded() {
        let profile = makeProfile([
            Stub(bytes: bytes("hi"), control: false, eog: false),
            Stub(bytes: bytes("<|end|>"), control: true, eog: false)
        ])
        XCTAssertFalse(profile.isExcluded(0))
        XCTAssertTrue(profile.isExcluded(1))
    }

    func test_endOfGenerationFlag_isReported() {
        let profile = makeProfile([
            Stub(bytes: bytes("word"), control: false, eog: false),
            Stub(bytes: bytes("</s>"), control: true, eog: true)
        ])
        XCTAssertFalse(profile.isEndOfGeneration(0))
        XCTAssertTrue(profile.isEndOfGeneration(1))
    }

    func test_whitespaceOnly_classification() {
        let profile = makeProfile([
            Stub(bytes: bytes(" "), control: false, eog: false),
            Stub(bytes: bytes("\t \n"), control: false, eog: false),
            Stub(bytes: bytes(" x"), control: false, eog: false),
            Stub(bytes: [], control: false, eog: false)
        ])
        XCTAssertTrue(profile.isWhitespaceOnly(0))
        XCTAssertTrue(profile.isWhitespaceOnly(1))
        // A space followed by a letter is not whitespace-only.
        XCTAssertFalse(profile.isWhitespaceOnly(2))
        // Empty bytes are not whitespace-only.
        XCTAssertFalse(profile.isWhitespaceOnly(3))
    }

    func test_newline_classification() {
        let profile = makeProfile([
            Stub(bytes: bytes("\n"), control: false, eog: false),
            Stub(bytes: bytes("a\nb"), control: false, eog: false),
            Stub(bytes: bytes("plain"), control: false, eog: false)
        ])
        XCTAssertTrue(profile.isNewline(0))
        // Newline embedded among other bytes still counts.
        XCTAssertTrue(profile.isNewline(1))
        XCTAssertFalse(profile.isNewline(2))
    }

    func test_outOfRangeID_isDefensive() {
        let profile = makeProfile([
            Stub(bytes: bytes("only"), control: false, eog: false)
        ])
        // Out-of-range queries must never crash and must be treated as excluded / negative so a stray
        // id can never be selected or misclassified.
        XCTAssertEqual(profile.bytes(for: 5), [])
        XCTAssertEqual(profile.bytes(for: -1), [])
        XCTAssertTrue(profile.isExcluded(5))
        XCTAssertTrue(profile.isExcluded(-1))
        XCTAssertFalse(profile.isEndOfGeneration(5))
        XCTAssertFalse(profile.isNewline(5))
        XCTAssertFalse(profile.isWhitespaceOnly(5))
    }

    func test_continuesWordMidStream_acceptsWordCharactersAndRejectsBreakers() {
        let profile = makeProfile([
            Stub(bytes: bytes("rrow"), control: false, eog: false),    // 0: letters
            Stub(bytes: bytes("3rd"), control: false, eog: false),     // 1: leading digit
            Stub(bytes: bytes("'t"), control: false, eog: false),      // 2: apostrophe (don't)
            Stub(bytes: bytes("-op"), control: false, eog: false),     // 3: hyphen (co-op)
            Stub(bytes: bytes("中文"), control: false, eog: false),      // 4: CJK letter
            Stub(bytes: bytes(" word"), control: false, eog: false),   // 5: leading space
            Stub(bytes: bytes(".rrow"), control: false, eog: false),   // 6: leading period
            Stub(bytes: bytes("!stop"), control: false, eog: false),   // 7: leading punctuation
            Stub(bytes: bytes("→x"), control: false, eog: false),      // 8: non-ASCII symbol
            Stub(bytes: [], control: true, eog: false)                 // 9: empty / control
        ])
        for id in [0, 1, 2, 3, 4] {
            XCTAssertTrue(profile.continuesWordMidStream(id), "id \(id) should continue a word")
        }
        for id in [5, 6, 7, 8, 9] {
            XCTAssertFalse(profile.continuesWordMidStream(id), "id \(id) should not continue a word")
        }
        XCTAssertFalse(profile.continuesWordMidStream(-1))
    }
}
