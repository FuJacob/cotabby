import XCTest
@testable import tabby

final class LlamaBackendRegistryTests: XCTestCase {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private(set) var inits = 0
        private(set) var frees = 0

        func recordInit() {
            lock.lock(); defer { lock.unlock() }
            inits += 1
        }

        func recordFree() {
            lock.lock(); defer { lock.unlock() }
            frees += 1
        }
    }

    private func makeRegistry() -> (LlamaBackendRegistry, Counter) {
        let counter = Counter()
        let registry = LlamaBackendRegistry(
            initBackend: { counter.recordInit() },
            freeBackend: { counter.recordFree() }
        )
        return (registry, counter)
    }

    func test_acquireOnlyInitializesOnFirstReference() {
        let (registry, counter) = makeRegistry()

        registry.acquire()
        registry.acquire()
        registry.acquire()

        XCTAssertEqual(counter.inits, 1)
        XCTAssertEqual(counter.frees, 0)
        XCTAssertEqual(registry.currentReferenceCount, 3)
    }

    func test_releaseOnlyFreesOnLastReference() {
        let (registry, counter) = makeRegistry()

        registry.acquire()
        registry.acquire()
        registry.release()
        XCTAssertEqual(counter.frees, 0, "Backend must stay alive while another holder remains")

        registry.release()
        XCTAssertEqual(counter.frees, 1)
        XCTAssertEqual(registry.currentReferenceCount, 0)
    }

    func test_reacquireAfterFullReleaseReinitializesBackend() {
        let (registry, counter) = makeRegistry()

        registry.acquire()
        registry.release()
        registry.acquire()
        registry.release()

        XCTAssertEqual(counter.inits, 2)
        XCTAssertEqual(counter.frees, 2)
    }

    func test_releaseWithoutAcquireIsSafe() {
        let (registry, counter) = makeRegistry()

        registry.release()
        registry.release()

        XCTAssertEqual(counter.inits, 0)
        XCTAssertEqual(counter.frees, 0)
        XCTAssertEqual(registry.currentReferenceCount, 0)
    }

    func test_concurrentAcquireReleaseKeepsRefCountBalanced() {
        let (registry, counter) = makeRegistry()
        let iterations = 500
        let queue = DispatchQueue(label: "registry.test", attributes: .concurrent)
        let group = DispatchGroup()

        for _ in 0 ..< iterations {
            group.enter()
            queue.async {
                registry.acquire()
                registry.release()
                group.leave()
            }
        }

        group.wait()

        XCTAssertEqual(registry.currentReferenceCount, 0)
        XCTAssertEqual(counter.inits, counter.frees, "Every init must be matched by a free")
        XCTAssertGreaterThan(counter.inits, 0)
    }
}
