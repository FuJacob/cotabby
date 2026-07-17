import XCTest
import CryptoKit
@testable import Cotabby

/// Tests for the size + SHA-256 validation that runs against staged downloads
/// before they're promoted to the install location.
///
/// The streaming SHA-256 path is exercised against a multi-chunk fixture so
/// the chunked-read loop is actually executed by at least one test — without
/// that, the implementation could regress to a single-shot read and pass the
/// happy-path tests anyway.
final class ModelFileValidatorTests: XCTestCase {

    private var fixtures: [URL] = []

    override func tearDown() {
        fixtures.forEach { try? FileManager.default.removeItem(at: $0) }
        fixtures.removeAll()
        super.tearDown()
    }

    // MARK: - validateSize

    func test_validateSize_passesWhenSizeMatches() throws {
        let url = try makeFixture(contents: Data(repeating: 0xAB, count: 100))
        XCTAssertNoThrow(try ModelFileValidator.validateSize(of: url, expectedBytes: 100))
    }

    func test_validateSize_throwsSizeMismatchWhenLargerThanExpected() throws {
        let url = try makeFixture(contents: Data(repeating: 0xAB, count: 200))
        XCTAssertThrowsError(try ModelFileValidator.validateSize(of: url, expectedBytes: 100)) { error in
            guard case ModelFileValidator.ValidationError.sizeMismatch(let expected, let actual) = error else {
                XCTFail("Expected sizeMismatch, got \(error)")
                return
            }
            XCTAssertEqual(expected, 100)
            XCTAssertEqual(actual, 200)
        }
    }

    func test_validateSize_throwsSizeMismatchWhenSmallerThanExpected() throws {
        let url = try makeFixture(contents: Data(repeating: 0xAB, count: 50))
        XCTAssertThrowsError(try ModelFileValidator.validateSize(of: url, expectedBytes: 100))
    }

    func test_validateSize_isNoOpWhenExpectedNil() throws {
        let url = try makeFixture(contents: Data())
        XCTAssertNoThrow(try ModelFileValidator.validateSize(of: url, expectedBytes: nil))
    }

    func test_validateSize_throwsFileUnreadableWhenFileMissing() {
        let phantom = FileManager.default.temporaryDirectory
            .appendingPathComponent("validator-test-phantom-\(UUID().uuidString)")
        XCTAssertThrowsError(try ModelFileValidator.validateSize(of: phantom, expectedBytes: 100)) { error in
            guard case ModelFileValidator.ValidationError.fileUnreadable = error else {
                XCTFail("Expected fileUnreadable, got \(error)")
                return
            }
        }
    }

    // MARK: - validateCompleteness

    func test_validateCompleteness_passesWhenSizeMatchesDeclaredLength() throws {
        let url = try makeFixture(contents: Data(repeating: 0xAB, count: 100))
        XCTAssertNoThrow(try ModelFileValidator.validateCompleteness(of: url, declaredContentLength: 100))
    }

    func test_validateCompleteness_throwsOnTruncatedBody() throws {
        let url = try makeFixture(contents: Data(repeating: 0xAB, count: 60))
        XCTAssertThrowsError(try ModelFileValidator.validateCompleteness(of: url, declaredContentLength: 100)) { error in
            guard case ModelFileValidator.ValidationError.sizeMismatch = error else {
                XCTFail("Expected sizeMismatch, got \(error)")
                return
            }
        }
    }

    func test_validateCompleteness_noOpsWhenLengthUnknown() throws {
        let url = try makeFixture(contents: Data(repeating: 0xAB, count: 60))
        XCTAssertNoThrow(try ModelFileValidator.validateCompleteness(of: url, declaredContentLength: -1))
        XCTAssertNoThrow(try ModelFileValidator.validateCompleteness(of: url, declaredContentLength: 0))
    }

    // MARK: - validateSHA256

    func test_validateSHA256_passesForKnownChecksum() throws {
        // SHA-256 of "hello" — pinned so the test would fail if the
        // implementation accidentally hashed something different (e.g.,
        // appended a trailing newline).
        let url = try makeFixture(contents: Data("hello".utf8))
        XCTAssertNoThrow(try ModelFileValidator.validateSHA256(
            of: url,
            expectedSHA256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        ))
    }

    func test_validateSHA256_acceptsUppercaseExpected() throws {
        let url = try makeFixture(contents: Data("hello".utf8))
        XCTAssertNoThrow(try ModelFileValidator.validateSHA256(
            of: url,
            expectedSHA256: "2CF24DBA5FB0A30E26E83B2AC5B9E29E1B161E5C1FA7425E73043362938B9824"
        ))
    }

    func test_validateSHA256_throwsChecksumMismatchOnBadHash() throws {
        let url = try makeFixture(contents: Data("hello".utf8))
        XCTAssertThrowsError(try ModelFileValidator.validateSHA256(
            of: url,
            expectedSHA256: String(repeating: "0", count: 64)
        )) { error in
            guard case ModelFileValidator.ValidationError.checksumMismatch = error else {
                XCTFail("Expected checksumMismatch, got \(error)")
                return
            }
        }
    }

    func test_validateSHA256_isNoOpWhenExpectedNil() throws {
        let url = try makeFixture(contents: Data("anything".utf8))
        XCTAssertNoThrow(try ModelFileValidator.validateSHA256(of: url, expectedSHA256: nil))
    }

    /// Streaming guard — exercises the multi-chunk read loop. Without this,
    /// a regression to a single read(upToCount:) of the entire file would
    /// pass every other test in this suite.
    func test_validateSHA256_handlesFileLargerThanChunkSize() throws {
        // 3 MB file (>1 MB chunk) of repeating bytes. Computed via CryptoKit
        // here so the test is self-checking — the goal isn't to verify
        // CryptoKit, it's to verify the streaming read produces the same
        // hash as a single-shot computation.
        let bytes = Data(repeating: 0x42, count: 3 * 1024 * 1024)
        let url = try makeFixture(contents: bytes)
        let expected = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertNoThrow(try ModelFileValidator.validateSHA256(of: url, expectedSHA256: expected))
    }

    func test_validateSHA256_throwsFileUnreadableWhenFileMissing() {
        let phantom = FileManager.default.temporaryDirectory
            .appendingPathComponent("validator-test-phantom-\(UUID().uuidString)")
        XCTAssertThrowsError(try ModelFileValidator.validateSHA256(
            of: phantom,
            expectedSHA256: String(repeating: "a", count: 64)
        )) { error in
            guard case ModelFileValidator.ValidationError.fileUnreadable = error else {
                XCTFail("Expected fileUnreadable, got \(error)")
                return
            }
        }
    }

    // MARK: - Helpers

    private func makeFixture(contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("validator-test-\(UUID().uuidString)")
        try contents.write(to: url)
        fixtures.append(url)
        return url
    }
}
