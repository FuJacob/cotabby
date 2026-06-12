import ApplicationServices
import XCTest
@testable import Cotabby

/// Tests for `AXTreeDumpWriter`'s gating: the dump is a Chrome-only developer diagnostic, so for
/// any other bundle the call must return without touching the element or the disk.
///
/// Only the gate is exercised. The rendering and write path requires a live Chrome accessibility
/// tree and overwrites `~/Desktop/cotabby-ax-dump.txt`, neither of which a unit test may touch, so
/// that path stays covered by manual `-cotabby-debug` runs against Chrome.
@MainActor
final class AXTreeDumpWriterTests: XCTestCase {
    func test_dumpIfEnabled_isNoOpForNonConfiguredBundles() async {
        // An application element for our own process: structurally valid, but any traversal of it
        // would be observable as latency or AX errors. The gate must reject on the bundle check
        // (or earlier on the debug flag when tests run without -cotabby-debug) before any of that.
        let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)

        AXTreeDumpWriter.dumpIfEnabled(
            focusedElement: element,
            applicationName: "TestApp",
            bundleIdentifier: "com.example.not-chrome",
            focusedElementIdentifier: "field-1"
        )
        // A second call with a fresh identifier must take the same early-out: the identity debounce
        // only applies to the configured bundle.
        AXTreeDumpWriter.dumpIfEnabled(
            focusedElement: element,
            applicationName: "TestApp",
            bundleIdentifier: "com.example.not-chrome",
            focusedElementIdentifier: "field-2"
        )

        var pid: pid_t = 0
        XCTAssertEqual(AXUIElementGetPid(element, &pid), .success)
        XCTAssertEqual(pid, ProcessInfo.processInfo.processIdentifier, "The element must pass through untouched")
    }
}
