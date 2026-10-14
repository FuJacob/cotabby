import XCTest
@testable import Cotabby

/// One answer-drafting eval case: a question, the facts memory would hand the model, and what a good
/// draft must (or must not) say, or that it must abstain because the facts do not answer it.
struct AnswerEvalCase: Decodable {
    struct Fact: Decodable {
        let sender: String
        let fromMe: Bool?
        let title: String
        let date: String
        let text: String
    }

    let id: String
    let question: String
    let asker: String?
    let facts: [Fact]
    let mustContain: [String]?
    let mustNotContain: [String]?
    let abstain: Bool?
    let tags: [String]

    var renderedFacts: [AnswerPromptRenderer.Fact] {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return facts.map {
            AnswerPromptRenderer.Fact(sender: $0.sender, isFromMe: $0.fromMe ?? false, conversationTitle: $0.title,
                                      timestamp: formatter.date(from: $0.date) ?? Date(), text: $0.text)
        }
    }

    static func load() throws -> [AnswerEvalCase] {
        guard let url = Bundle(for: AnswerDraftEvalTests.self).url(forResource: "llama-answer-cases", withExtension: "json") else {
            throw XCTSkip("llama-answer-cases.json missing from the test bundle")
        }
        return try JSONDecoder().decode([AnswerEvalCase].self, from: Data(contentsOf: url))
    }

    /// The pre-draft gate the app applies after retrieval (the similarity gate is not modelled:
    /// eval facts are given, not retrieved). False means the app would not ask the model at all.
    var passesPreDraftGate: Bool {
        AnswerGroundingPolicy.factsMentionWhatTheQuestionNames(question: question, facts: AnswerPromptRenderer.factLines(renderedFacts))
    }

    /// Scores a draft the way the app decides what to show: nil (no card) passes an abstain case;
    /// a draft passes an answer case only if it is grounded and says what it must, not what it must not.
    func passes(_ draft: String?) -> Bool {
        let draft = passesPreDraftGate ? draft : nil
        let shownFacts = AnswerPromptRenderer.factLines(renderedFacts)
        let shown = draft.flatMap { text in
            AnswerGroundingPolicy.unsupportedSpecifics(in: text, facts: shownFacts, question: question).isEmpty
                && AnswerGroundingPolicy.usesFacts(text, facts: shownFacts, question: question)
                && !AnswerGroundingPolicy.containsSecrets(text) ? text : nil
        }
        if abstain == true { return shown == nil }
        guard let shown else { return false }
        let has = { (needle: String) in LlamaEvalScorer.containsAll(shown: shown, required: [needle]) }
        return (mustContain ?? []).allSatisfy(has) && !(mustNotContain ?? []).contains(where: has)
    }
}

/// The answer eval: real models draft each case's answer and the drafts are scored as the app would
/// show them. Local-only, like the other model evals (compile flag `RUN_LLAMA_EVAL`):
///
///   xcodebuild test -project Cotabby.xcodeproj -scheme Cotabby -destination 'platform=macOS' \
///     -only-testing:CotabbyTests/AnswerDraftEvalTests \
///     SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) RUN_LLAMA_EVAL' CODE_SIGNING_ALLOWED=NO \
///     -configuration Release ENABLE_TESTABILITY=YES -derivedDataPath build/DerivedData
///
/// The local model comes from `LlamaEvalRuntime` (the selected model, or `COTABBY_EVAL_MODEL_PATH`).
///
/// `test_answerCasesAreConsistent` always runs: it keeps the dataset honest (every required fact is
/// in the case's facts, so a failure is never a demand to hallucinate).
@MainActor
final class AnswerDraftEvalTests: XCTestCase {
    func test_answerCasesAreConsistent() throws {
        let cases = try AnswerEvalCase.load()
        XCTAssertGreaterThanOrEqual(cases.count, 15)
        XCTAssertEqual(Set(cases.map(\.id)).count, cases.count)
        for evalCase in cases {
            let facts = AnswerPromptRenderer.factLines(evalCase.renderedFacts).joined(separator: " ")
            for required in evalCase.mustContain ?? [] {
                XCTAssertTrue(LlamaEvalScorer.containsAll(shown: facts, required: [required]),
                              "\(evalCase.id) requires '\(required)' but its facts do not contain it")
            }
            XCTAssertTrue(evalCase.abstain == true || !(evalCase.mustContain ?? []).isEmpty, "\(evalCase.id) expects nothing")
        }
    }

    func test_reportAnswerSuiteWithTheLocalModel() async throws {
        #if RUN_LLAMA_EVAL
        let manager = try LlamaEvalRuntime.makeManager()
        do {
            try await manager.prepare()
        } catch {
            throw XCTSkip("No llama runtime available (\(error)).")
        }
        try await report(engine: "llama") { evalCase in
            try await AnswerDraftEngine.draftLocally(
                runtimeManager: manager, question: evalCase.question, asker: evalCase.asker, facts: evalCase.renderedFacts
            )
        }
        #else
        throw XCTSkip("Answer eval is disabled. Pass SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) RUN_LLAMA_EVAL'.")
        #endif
    }

    func test_reportAnswerSuiteWithAppleIntelligence() async throws {
        #if RUN_LLAMA_EVAL
        let availability = FoundationModelAvailabilityService()
        availability.refresh()
        guard availability.isAvailable else { throw XCTSkip("Apple Intelligence is not available on this Mac.") }
        // No local model: drafts come from Apple Intelligence only.
        let engine = AnswerDraftEngine(runtimeManager: LlamaRuntimeManager(), hasLocalModel: { false }, availability: availability)
        try await report(engine: "apple") { evalCase in
            try await engine.draft(question: evalCase.question, asker: evalCase.asker, facts: evalCase.renderedFacts)?.text
        }
        #else
        throw XCTSkip("Answer eval is disabled. Pass SWIFT_ACTIVE_COMPILATION_CONDITIONS='$(inherited) RUN_LLAMA_EVAL'.")
        #endif
    }

    private func report(engine: String, draft: (AnswerEvalCase) async throws -> String?) async throws {
        let cases = try AnswerEvalCase.load()
        var passed = 0
        var answerPassed = 0
        var abstainPassed = 0
        let answerCases = cases.filter { $0.abstain != true }.count
        for evalCase in cases {
            let started = Date()
            let text = try await draft(evalCase)
            let ok = evalCase.passes(text)
            if ok {
                passed += 1
                if evalCase.abstain == true { abstainPassed += 1 } else { answerPassed += 1 }
            }
            print("\(ok ? "PASS" : "FAIL") [\(engine)] \(evalCase.id) \(Int(Date().timeIntervalSince(started) * 1000))ms got=\(text ?? "<none>")")
        }
        print(String(format: "Answer suite [%@]: %d/%d (answers %d/%d, abstentions %d/%d)",
                     engine, passed, cases.count, answerPassed, answerCases, abstainPassed, cases.count - answerCases))
        XCTAssertFalse(cases.isEmpty)
    }
}
