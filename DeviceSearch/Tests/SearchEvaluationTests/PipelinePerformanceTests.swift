import Foundation
import Testing
import SearchCore
import SearchIndex
import DeviceSearch
@testable import SearchEvaluation
import SearchTestSupport
import SearchRanking
import SearchSemantic
import SearchRerank

@Suite("Pipeline performance", .serialized)
struct PipelinePerformanceTests {
    @Test func validationTakesUnderAMillisecond() {
        let request = LLMRerankerProbe.request("something to cool the bedroom")
        let answer = RerankAnswer(best: [3, 1, 2], related: [5, 4])
        let validator = ResultValidator()
        let timings = measure(50) { _ = validator.validate(answer, candidates: request.candidates, intent: .descriptive) }
        print("validation ms", milliseconds(timings.min()!))
        #expect(timings.min()! <= Budget.ms(1))
    }

    @Test func hybridPhaseWithMeaningStaysUnder150ms() async {
        let home = await evaluationHome(refiner: nil)
        let phases = await home.engine.searchAll("something to cool the bedroom", mode: .submitted)
        let hybrid = phases.first { $0.phase == .hybrid }
        let meaning = hybrid?.diagnostics.meaningDuration ?? .zero
        print("meaning ms", milliseconds(meaning))
        #expect(meaning <= Budget.ms(150))
    }
}

enum LLMRerankerProbe {
    static func request(_ text: String) -> RefinementRequest {
        let pipeline = SearchPipeline(config: .default)
        let snapshot = TestIndex.home500
        let parsed = pipeline.parse(text, mode: .submitted, options: .standard, in: snapshot)
        let (query, fusion) = pipeline.fuse(pipeline.lexicalLists(parsed, in: snapshot), query: parsed, in: snapshot)
        return RefinementRequest(query: query, candidates: fusion.top(12), snapshot: snapshot,
                                 context: PresentationContext(), config: .default)
    }
}
