import Testing
import SearchCore
import SearchIndex
import DeviceSearch
@testable import SearchEvaluation
import SearchTestSupport
import SearchSemantic
import SearchRerank

#if canImport(FoundationModels) && canImport(NaturalLanguage)
import FoundationModels
import NaturalLanguage

/// The production model and embeddings against the golden set (design doc §8 L12/L13, §17 E02, decision D06).
/// Runs only on a Mac with Apple Intelligence enabled: `swift test --filter OnDeviceHarness`.
/// Re-run it after every prompt change and every major OS update, and keep the printed tables with the release.
@Suite("On-device harness", .serialized, .enabled(if: SystemLanguageModel.default.isAvailable))
struct OnDeviceHarness {
    @Test func productionModelMeetsTheMilestoneThreeTargets() async {
        let queries = GoldenSetBuilder(snapshot: TestIndex.home500).build()
        let hybrid = await EvaluationRunner(engine: evaluationHome(refiner: nil).engine).run(queries)
        let telemetry = InMemoryTelemetry()
        let reranker = LLMReranker(client: FoundationModelsClient())
        await reranker.prewarm()
        let refined = await EvaluationRunner(engine: evaluationHome(refiner: reranker, telemetry: telemetry).engine).run(queries)
        print("Production model:\n" + refined.markdown())
        let latencies = telemetry.events.compactMap { event -> Duration? in
            if case .rerank(let metrics) = event, metrics.outcome == .refined { return metrics.latency }
            return nil
        }
        print("re-rank p50", Metrics.percentile(latencies, 50), "p95", Metrics.percentile(latencies, 95),
              "interventions", telemetry.interventionRate)
        #expect(refined.category(.descriptive)!.ndcg5! > hybrid.category(.descriptive)!.ndcg5!)
        #expect(telemetry.interventionRate < 0.05)
        #expect(Metrics.percentile(latencies, 95) <= .seconds(2))
    }

    /// Calibrates the semantic thresholds for the real embedding model (0.35 and 0.45 are starting points).
    @Test func contextualEmbeddingsImproveDescriptiveQueries() async throws {
        let embedder = try #require(NLContextualEmbedder(language: .english))
        let provider = MeaningRetrievalProvider(embedder: embedder, knowledge: TestIndex.knowledge)
        let home = await HomeSearch.make(homeID: "calibration", devices: SyntheticHome.make(count: 500),
                                         components: DeviceSearchComponents(knowledge: TestIndex.knowledge, meaning: provider))
        await provider.waitUntilWarm()
        let queries = GoldenSetBuilder(snapshot: TestIndex.home500).build()
        let lexical = await EvaluationRunner(engine: SearchEngine(snapshot: TestIndex.home500)).run(queries)
        let report = await EvaluationRunner(engine: home.engine).run(queries)
        print("NLContextualEmbedding:\n" + report.markdown())
        #expect(report.category(.descriptive)!.ndcg5! > lexical.category(.descriptive)!.ndcg5!)
        #expect(report.navigationalSuccess >= 0.92)
    }
}
#endif
