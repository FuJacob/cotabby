import XCTest
@testable import Cotabby

/// Round-trip and robustness tests for the on-disk token-profile codec. The cache must reconstruct an
/// identical profile, and must reject any mismatched or malformed data with nil so the runtime rebuilds
/// rather than trusting a bad file.
final class TokenProfileCacheTests: XCTestCase {
    private func makeProfile(byteStrings: [String], eog: Set<Int> = []) -> TokenProfile {
        let bytes = byteStrings.map { Array($0.utf8) }
        return TokenProfile.build(
            vocabSize: bytes.count,
            bytesFor: { bytes[$0] },
            isControl: { bytes[$0].isEmpty },
            isEndOfGeneration: { eog.contains($0) })
    }

    func test_roundTrip_reconstructsIdenticalProfile() {
        // Mix of leading-space, empty (control), multi-byte, and punctuation tokens.
        let profile = makeProfile(byteStrings: ["a", " the", "", "héllo", ".", "\n"], eog: [2])
        let data = TokenProfileCache.encode(profile, fingerprint: 0xABCD_1234)
        let decoded = TokenProfileCache.decode(data, expectedFingerprint: 0xABCD_1234)

        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?.vocabSize, profile.vocabSize)
        for id in 0 ..< profile.vocabSize {
            XCTAssertEqual(decoded?.bytes(for: id), profile.bytes(for: id))
            XCTAssertEqual(decoded?.isEndOfGeneration(id), profile.isEndOfGeneration(id))
            XCTAssertEqual(decoded?.isExcluded(id), profile.isExcluded(id), "derived control flag must match")
            XCTAssertEqual(decoded?.isNewline(id), profile.isNewline(id), "derived newline flag must match")
        }
    }

    func test_decode_returnsNilOnFingerprintMismatch() {
        let data = TokenProfileCache.encode(makeProfile(byteStrings: ["a", "b"]), fingerprint: 1)
        XCTAssertNil(TokenProfileCache.decode(data, expectedFingerprint: 2))
    }

    func test_decode_returnsNilOnTruncatedData() {
        let data = TokenProfileCache.encode(makeProfile(byteStrings: ["hello", "world"]), fingerprint: 7)
        XCTAssertNil(TokenProfileCache.decode(data.dropLast(3), expectedFingerprint: 7))
    }

    func test_decode_returnsNilOnEmptyOrGarbageData() {
        XCTAssertNil(TokenProfileCache.decode(Data(), expectedFingerprint: 0))
        XCTAssertNil(TokenProfileCache.decode(Data([0, 1, 2, 3, 4, 5, 6, 7, 8]), expectedFingerprint: 0))
    }

    func test_roundTrip_emptyProfile() {
        let profile = TokenProfile.build(
            vocabSize: 0, bytesFor: { _ in [] }, isControl: { _ in true }, isEndOfGeneration: { _ in false })
        let data = TokenProfileCache.encode(profile, fingerprint: 99)
        XCTAssertEqual(TokenProfileCache.decode(data, expectedFingerprint: 99)?.vocabSize, 0)
    }
}
