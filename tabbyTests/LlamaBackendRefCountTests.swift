import XCTest
@testable import tabby

final class LlamaBackendRefCountTests: XCTestCase {
    func test_acquireRunsInitOnlyOnFirstReference() {
        let counter = RefCountProbe()
        let registry = LlamaBackendRegistry(
            initBackend: { counter.bumpInit() },
            freeBackend: { counter.bumpFree() }
        )

        registry.acquire()
        registry.acquire()
        registry.acquire()

        XCTAssertEqual(counter.initCount, 1)
        XCTAssertEqual(counter.freeCount, 0)
        XCTAssertEqual(registry.currentReferenceCount, 3)
    }

    func test_releaseRunsFreeOnlyOnLastReference() {
        let counter = RefCountProbe()
        let registry = LlamaBackendRegistry(
            initBackend: { counter.bumpInit() },
            freeBackend: { counter.bumpFree() }
        )

        registry.acquire()
        registry.acquire()
        registry.release()
        XCTAssertEqual(counter.freeCount, 0)

        registry.release()
        XCTAssertEqual(counter.freeCount, 1)
        XCTAssertEqual(registry.currentReferenceCount, 0)
    }

    func test_reacquireAfterFullReleaseReinitializes() {
        let counter = RefCountProbe()
        let registry = LlamaBackendRegistry(
            initBackend: { counter.bumpInit() },
            freeBackend: { counter.bumpFree() }
        )

        registry.acquire()
        registry.release()
        registry.acquire()
        registry.release()

        XCTAssertEqual(counter.initCount, 2)
        XCTAssertEqual(counter.freeCount, 2)
    }

    func test_releaseWithoutAcquireIsNoop() {
        let counter = RefCountProbe()
        let registry = LlamaBackendRegistry(
            initBackend: { counter.bumpInit() },
            freeBackend: { counter.bumpFree() }
        )

        registry.release()
        registry.release()

        XCTAssertEqual(counter.initCount, 0)
        XCTAssertEqual(counter.freeCount, 0)
        XCTAssertEqual(registry.currentReferenceCount, 0)
    }
}

final class RefCountProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var inits = 0
    private var frees = 0

    var initCount: Int {
        lock.lock(); defer { lock.unlock() }
        return inits
    }

    var freeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return frees
    }

    func bumpInit() {
        lock.lock(); defer { lock.unlock() }
        inits += 1
    }

    func bumpFree() {
        lock.lock(); defer { lock.unlock() }
        frees += 1
    }
}
