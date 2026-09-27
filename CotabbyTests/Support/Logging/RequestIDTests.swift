import XCTest
@testable import Cotabby

/// Locks the correlation-ID format that the structured-logging workflow depends on: `jq` filters,
/// the symptom-to-category debugging map, and cross-file joins between `cotabby.jsonl` and
/// `llm-io.jsonl` all assume a stable `req_` + 8 base32 shape.
final class RequestIDTests: XCTestCase {
    /// Crockford-style alphabet copied from the production contract: no `i`, `l`, `o`, or `u`,
    /// so IDs stay unambiguous when read back from a log line.
    private static let crockfordAlphabet = Set("0123456789abcdefghjkmnpqrstvwxyz")

    func test_generate_producesReqPrefixPlusEightCrockfordCharacters() {
        // Several draws so the alphabet check sees many random 5-bit groups, not just one ID.
        for _ in 0..<64 {
            let id = RequestID.generate()

            XCTAssertTrue(id.hasPrefix("req_"), "Expected req_ prefix, got \(id)")
            let suffix = id.dropFirst(4)
            XCTAssertEqual(suffix.count, 8, "5 random bytes encode to exactly 8 characters, got \(id)")
            XCTAssertTrue(
                suffix.allSatisfy { Self.crockfordAlphabet.contains($0) },
                "\(id) contains a character outside the Crockford base32 alphabet"
            )
        }
    }

    func test_generate_doesNotCollideAcrossManyDraws() {
        // 1,000 draws from a 40-bit space: a duplicate here means the encoder is reusing entropy,
        // not bad luck (the birthday-bound collision chance is below one in a million).
        let ids = Set((0..<1_000).map { _ in RequestID.generate() })

        XCTAssertEqual(ids.count, 1_000)
    }
}
