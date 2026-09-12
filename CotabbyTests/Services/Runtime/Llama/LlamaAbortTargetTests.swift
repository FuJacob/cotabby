import Foundation
import XCTest
@testable import Cotabby

/// The bookkeeping between a cancelled generation's task and the native prompt decode. The
/// engine's abort flag is set once per sequence, so two properties matter: every abort that
/// reaches a sequence is reported by the `withdraw` ending its publication (the core then discards
/// that sequence), and no abort reaches a sequence once it is withdrawn (the core keeps that
/// sequence for the next request's prefix reuse).
final class LlamaAbortTargetTests: XCTestCase {
    func testAnAbortWithNothingPublishedReachesNothing() {
        let target = LlamaAbortTarget()
        var cancelled: [Int32] = []
        target.abort { cancelled.append($0) }
        XCTAssertEqual(cancelled, [])
        XCTAssertFalse(target.withdraw())
    }

    func testAnAbortReachesThePublishedSequenceAndItsWithdrawReportsIt() {
        let target = LlamaAbortTarget()
        var cancelled: [Int32] = []
        target.publish(3)
        target.abort { cancelled.append($0) }
        XCTAssertEqual(cancelled, [3])
        XCTAssertTrue(target.withdraw(), "the core must discard a sequence an abort reached")
        XCTAssertFalse(target.withdraw(), "the report belongs to one publication")
    }

    /// The measured failure: the prompt decode is over and the request is sampling when the next
    /// keystroke cancels it. Sampling polls that cancellation between tokens, and the sequence is
    /// kept for the next request, so the abort must not reach it.
    func testAnAbortAfterTheWithdrawReachesNothing() {
        let target = LlamaAbortTarget()
        var cancelled: [Int32] = []
        target.publish(3)
        XCTAssertFalse(target.withdraw())
        target.abort { cancelled.append($0) }
        XCTAssertEqual(cancelled, [], "the engine flag of a kept sequence stays down")
        XCTAssertFalse(target.withdraw())
    }

    /// A reused sequence whose decode failed is replaced by a fresh one before the withdraw; an
    /// abort that reached the replaced sequence does not condemn the fresh one.
    func testAPublicationStartsAFreshRecord() {
        let target = LlamaAbortTarget()
        target.publish(3)
        target.abort { _ in }
        target.publish(4)
        XCTAssertFalse(target.withdraw())
    }

    /// Thousands of publications against three threads aborting as fast as they can: whatever the
    /// interleaving, a publication's withdraw reports an abort exactly when one reached it.
    func testEveryAbortThatLandsIsReportedByTheWithdrawEndingItsPublication() {
        let race = Self.race(publications: 5_000, aborters: 3)
        var reported = 0
        for id in 0 ..< race.publications {
            XCTAssertEqual(race.reported(id), race.cancelCount(Int32(id)) > 0, "publication \(id)")
            if race.reported(id) { reported += 1 }
        }
        XCTAssertGreaterThan(reported, 0, "no abort overlapped a publication, so nothing was tested")
    }

    nonisolated private static func race(publications: Int, aborters: Int) -> RaceRecord {
        let target = LlamaAbortTarget()
        let record = RaceRecord(publications: publications)
        DispatchQueue.concurrentPerform(iterations: aborters + 1) { worker in
            if worker == 0 {
                for id in 0 ..< publications {
                    target.publish(Int32(id))
                    // Stands in for the prompt decode, and lets the aborting threads in.
                    if id.isMultiple(of: 2) { sched_yield() }
                    record.setReported(id, target.withdraw())
                }
                record.finish()
            } else {
                while !record.isFinished {
                    target.abort { record.recordCancel($0) }
                }
            }
        }
        return record
    }

    /// Shared between the publishing thread and the aborting ones; its lock is the only guard.
    nonisolated private final class RaceRecord: @unchecked Sendable {
        let publications: Int
        private let lock = NSLock()
        private var reportedByID: [Bool]
        private var cancelsByID: [Int32: Int] = [:]
        private var finished = false

        init(publications: Int) {
            self.publications = publications
            reportedByID = Array(repeating: false, count: publications)
        }

        func setReported(_ id: Int, _ value: Bool) {
            lock.lock()
            reportedByID[id] = value
            lock.unlock()
        }

        func reported(_ id: Int) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return reportedByID[id]
        }

        func recordCancel(_ id: Int32) {
            lock.lock()
            cancelsByID[id, default: 0] += 1
            lock.unlock()
        }

        func cancelCount(_ id: Int32) -> Int {
            lock.lock()
            defer { lock.unlock() }
            return cancelsByID[id] ?? 0
        }

        func finish() {
            lock.lock()
            finished = true
            lock.unlock()
        }

        var isFinished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return finished
        }
    }
}
