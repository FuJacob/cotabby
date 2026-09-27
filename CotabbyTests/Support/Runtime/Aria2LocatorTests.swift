import XCTest
@testable import Cotabby

/// A `FileManager` whose executability answers come from a fixed set, so locator precedence can be
/// tested without depending on which package managers this machine has installed.
final class StubExecutableFileManager: FileManager, @unchecked Sendable {
    var executablePaths: Set<String> = []

    override func isExecutableFile(atPath path: String) -> Bool {
        executablePaths.contains(path)
    }
}

/// Locks the aria2c discovery order shared by the provisioner and download manager: well-known
/// install locations in a fixed priority, then `PATH`, else nil.
final class Aria2LocatorTests: XCTestCase {
    private func resolve(executable paths: Set<String>) -> String? {
        let stub = StubExecutableFileManager()
        stub.executablePaths = paths
        return Aria2Locator.executableURL(fileManager: stub)?.path
    }

    /// Runs `body` with `PATH` replaced, restoring the original afterwards so later tests (and any
    /// subprocess the host app spawns) see the real search path.
    private func withPATH(_ value: String, perform body: () -> Void) {
        let original = ProcessInfo.processInfo.environment["PATH"]
        setenv("PATH", value, 1)
        defer {
            if let original {
                setenv("PATH", original, 1)
            } else {
                unsetenv("PATH")
            }
        }
        body()
    }

    func test_executableURL_returnsNilWhenNoCandidatesAreExecutable() {
        XCTAssertNil(resolve(executable: []))
    }

    func test_executableURL_prefersWellKnownLocationsInPriorityOrder() {
        // Each row makes every lower-priority location executable too, proving the first wins.
        let priority = [
            "/opt/homebrew/bin/aria2c",
            "/usr/local/bin/aria2c",
            "/usr/bin/aria2c",
            "/opt/local/bin/aria2c"
        ]
        for index in priority.indices {
            let available = Set(priority[index...])
            XCTAssertEqual(resolve(executable: available), priority[index], "available: \(available.sorted())")
        }
    }

    func test_executableURL_fallsBackToPATHInSearchOrder() {
        withPATH("/custom/one:/custom/two:/custom/three") {
            XCTAssertEqual(
                resolve(executable: ["/custom/two/aria2c", "/custom/three/aria2c"]),
                "/custom/two/aria2c"
            )
        }
    }

    func test_executableURL_wellKnownLocationBeatsPATH() {
        withPATH("/custom/one") {
            XCTAssertEqual(
                resolve(executable: ["/custom/one/aria2c", "/opt/local/bin/aria2c"]),
                "/opt/local/bin/aria2c"
            )
        }
    }
}
