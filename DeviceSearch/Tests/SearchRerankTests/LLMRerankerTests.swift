import Foundation
import Testing
import SearchCore
import SearchIndex
import SearchRanking
@testable import DeviceSearch
@testable import SearchRerank
import SearchTestSupport

@Suite("LLM re-ranker")
struct LLMRerankerTests {
    @Test func refinesWithDeterministicReasonsAndMovement() async throws {
        let reranker = LLMReranker(client: SimulatedRerankClient())
        let request = refinementRequest("something to cool the bedroom")
        let outcome = try await reranker.refine(request)
        #expect(!outcome.results.isEmpty)
        #expect(outcome.results.allSatisfy { result in request.candidates.contains { $0.document == result.document } })
        #expect(outcome.results.allSatisfy { !$0.reasons.isEmpty })
        #expect(outcome.kendallTau != nil)
        let moved = outcome.results.enumerated().map { index, result in
            (request.candidates.firstIndex { $0.document == result.document }! - index) == result.rankChange
        }
        #expect(moved.allSatisfy { $0 })
    }

    @Test func validatorRecoversFromInjectedFaults() async throws {
        let request = refinementRequest("Bedroom AC")                     // has an exact match
        let reranker = LLMReranker(client: FaultInjectingClient(wrapping: SimulatedRerankClient()))
        let outcome = try await reranker.refine(request)
        #expect(outcome.results.first?.device.name == "Bedroom AC")      // the exact match stays on top
        #expect(Set(outcome.results.map(\.id)).count == outcome.results.count)
        #expect(outcome.interventions == ["V1", "V2", "V5"])               // invented, repeated, dropped full match
    }

    @Test func overflowingTheWindowFailsBeforeCallingTheModel() async {
        let client = ScriptedClient(window: 100)
        await #expect(throws: RefinementFailure(.contextWindow)) {
            try await LLMReranker(client: client).refine(refinementRequest("something to cool the bedroom"))
        }
        #expect(client.callCount == 0)
    }

    @Test func modelErrorsAreClassified() async {
        let client = ScriptedClient(error: FakeGenerationError.guardrailViolation("x"))
        await #expect(throws: RefinementFailure(.guardrail)) {
            try await LLMReranker(client: client).refine(refinementRequest("something to cool the bedroom"))
        }
    }

    @Test func streamingLocksTheBestRowsFirst() async throws {
        let reranker = LLMReranker(client: SimulatedRerankClient())
        let request = refinementRequest("something to cool the bedroom")
        let partials = PartialLog()
        let outcome = try await reranker.refine(request) { rows in await partials.append(rows) }
        let first = try #require(await partials.items.first)
        #expect(first.count == request.candidates.count)                 // nothing hidden yet
        let lockedIDs = first.filter { $0.section == .best }.map(\.id)
        #expect(Array(outcome.results.prefix(lockedIDs.count).map(\.id)) == lockedIDs)
    }

    @Test func engineRunsTheRerankerOnSubmit() async {
        let engine = SearchEngine(snapshot: TestIndex.home500, refiner: LLMReranker(client: SimulatedRerankClient()))
        let phases = await engine.searchAll("something to cool the bedroom", mode: .submitted)
        #expect(phases.map(\.phase) == [.instant, .refined])
        #expect(phases[1].diagnostics.refineDuration != nil)
        let typing = await engine.searchAll("something to cool the bedroom", mode: .typing)
        #expect(typing.map(\.phase) == [.instant])                       // never while typing (D13)
    }
}

actor PartialLog {
    var items: [[SearchResult]] = []
    func append(_ rows: [SearchResult]) { items.append(rows) }
}
