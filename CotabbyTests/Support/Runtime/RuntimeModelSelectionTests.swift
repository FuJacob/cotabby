import XCTest
@testable import Cotabby

final class RuntimeModelSelectionTests: XCTestCase {
    private func options(_ filenames: [String]) -> [RuntimeModelOption] {
        filenames.map { RuntimeModelOption(filename: $0, url: URL(fileURLWithPath: "/tmp/models/\($0)")) }
    }

    func test_resolve_table() {
        let cases: [(name: String, candidates: [String?], available: [String], expected: String?)] = [
            ("nothing installed", ["a.gguf"], [], nil),
            ("no candidates falls back to first", [], ["a.gguf", "b.gguf"], "a.gguf"),
            ("nil candidate falls back to first", [nil], ["a.gguf", "b.gguf"], "a.gguf"),
            ("installed candidate is kept", ["b.gguf"], ["a.gguf", "b.gguf"], "b.gguf"),
            ("missing candidate falls back to first", ["gone.gguf"], ["a.gguf", "b.gguf"], "a.gguf"),
            ("first installed candidate wins", ["b.gguf", "a.gguf"], ["a.gguf", "b.gguf"], "b.gguf"),
            ("missing candidate yields to the next one", ["gone.gguf", "b.gguf"], ["a.gguf", "b.gguf"], "b.gguf"),
            ("nil candidate yields to the next one", [nil, "b.gguf"], ["a.gguf", "b.gguf"], "b.gguf"),
            ("matching is exact", ["B.gguf"], ["a.gguf", "b.gguf"], "a.gguf")
        ]
        for testCase in cases {
            XCTAssertEqual(
                RuntimeModelSelection.resolve(candidates: testCase.candidates, available: options(testCase.available)),
                testCase.expected,
                testCase.name
            )
        }
    }
}
