import XCTest
@testable import Cotabby

/// Locks the correlation-ID format that the structured-logging workflow depends on: `jq` filters,
/// the symptom-to-category debugging map, and cross-file joins between `cotabby.jsonl` and
/// `llm-io.jsonl` all assume a stable `req_` + 8 base32 shape.
final class RequestIDTests: XCTestCase {
    /// Crockford-style alphabet copied from the production contract: no `i`, `l`, `o`, or `u`,
    /// so IDs stay unambiguous when read back from a log line.
    private static let crockfordAlphabet = Set("0123456789abcdefghjkmnpqrstvwxyz")

    func test_generate_producesPrefixedTwelveCharacterID() {
        let id = RequestID.generate()

        XCTAssertTrue(id.hasPrefix("req_"), "Expected req_ prefix, got \(id)")
        XCTAssertEqual(id.count, 12, "Expected req_ plus exactly 8 base32 characters, got \(id)")
    }

    func test_generate_usesOnlyCrockfordBase32Characters() {
        for _ in 0..<64 {
            let suffix = RequestID.generate().dropFirst(4)

            XCTAssertEqual(suffix.count, 8)
            for character in suffix {
                XCTAssertTrue(
                    Self.crockfordAlphabet.contains(character),
                    "Character \(character) is outside the Crockford base32 alphabet"
                )
            }
        }
    }

    func test_generate_doesNotCollideAcrossManyDraws() {
        // 1,000 draws from a 40-bit space: a duplicate here means the encoder is reusing entropy,
        // not bad luck (the birthday-bound collision chance is below one in a million).
        let ids = Set((0..<1_000).map { _ in RequestID.generate() })

        XCTAssertEqual(ids.count, 1_000)
    }

    func test_metadataRequestID_buildsTheSingleStampedField() {
        // OSLogHandler's metadata property gives us a typed `Logger.Metadata` context without the
        // test target needing its own swift-log dependency.
        var handler = OSLogHandler(label: "com.cotabby.test-request-id")
        handler.metadata = .requestID("req_a3f9k2lq")

        XCTAssertEqual(handler.metadata.count, 1)
        XCTAssertEqual(handler.metadata["request_id"], .string("req_a3f9k2lq"))
    }
}
