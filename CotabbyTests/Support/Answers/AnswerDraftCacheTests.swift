import Foundation
import XCTest
@testable import Cotabby

/// Pins that a cached draft never outlives what it was drawn from: a change to memory's settings
/// (a source's "Use for answers" turned off), its data (something forgotten), or the engine itself
/// empties the cache, and a draft prepared while memory changed is not kept.
final class AnswerDraftCacheTests: XCTestCase {
    private let engine = UUID()
    private let offer = AnswerOffer(draft: "It passed.", answering: "Deniz: How did it go?", sources: [])

    private func stamp(generation: UInt64 = 0, outlookAnswers: Bool = true, engine: UUID? = nil) -> AnswerDraftCache.Stamp {
        var configuration = MemoryConfiguration()
        configuration.sources["outlook"] = MemorySourceSettings(enabled: true, answerSource: outlookAnswers)
        return AnswerDraftCache.Stamp(engine: engine ?? self.engine, dataGeneration: generation, configuration: configuration)
    }

    func test_aDraftIsReusedOnlyWhileMemoryIsUnchanged() {
        var cache = AnswerDraftCache()
        XCTAssertNil(cache.lookup("m1", stamp: stamp()), "not prepared yet")
        cache.store(offer, for: "m1", preparedUnder: stamp())
        cache.store(nil, for: "m2", preparedUnder: stamp())
        XCTAssertEqual(cache.lookup("m1", stamp: stamp()), .some(offer))
        XCTAssertEqual(cache.lookup("m2", stamp: stamp()), .some(nil), "nothing to offer is remembered too")

        XCTAssertNil(cache.lookup("m1", stamp: stamp(outlookAnswers: false)), "a source turned off for answers")
        cache.store(offer, for: "m1", preparedUnder: stamp(outlookAnswers: false))
        XCTAssertNil(cache.lookup("m1", stamp: stamp(generation: 1, outlookAnswers: false)), "something was forgotten")
        cache.store(offer, for: "m1", preparedUnder: stamp(generation: 1, outlookAnswers: false))
        XCTAssertNil(cache.lookup("m1", stamp: stamp(generation: 1, outlookAnswers: false, engine: UUID())),
                     "memory was switched off and on")
        XCTAssertNil(cache.lookup("m1", stamp: nil), "memory is off")
    }

    func test_aDraftPreparedWhileMemoryChangedIsNotKept() {
        var cache = AnswerDraftCache()
        _ = cache.lookup("m1", stamp: stamp())
        // Drafting started under generation 0; meanwhile a source was forgotten.
        _ = cache.lookup("other", stamp: stamp(generation: 1))
        cache.store(offer, for: "m1", preparedUnder: stamp())
        XCTAssertNil(cache.lookup("m1", stamp: stamp(generation: 1)))
    }
}
