import Foundation
import XCTest

extension XCTestCase {
    /// Creates a uniquely named directory under the system temp location and removes it when the
    /// test finishes, so file-backed suites never see another test's artifacts or leave their own.
    func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CotabbyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}
