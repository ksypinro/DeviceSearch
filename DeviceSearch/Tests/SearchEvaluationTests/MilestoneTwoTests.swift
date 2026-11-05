import Testing
import SearchCore
import SearchIndex
import DeviceSearch
@testable import SearchEvaluation
import SearchTestSupport
import SearchSemantic

@Suite("Milestone 2 exit criteria")
struct MilestoneTwoTests {
    @Test func meaningImprovesDescriptiveQueries() async {
        let queries = GoldenSetBuilder(snapshot: TestIndex.home500).build()
        let lexical = await EvaluationRunner(engine: SearchEngine(snapshot: TestIndex.home500)).run(queries)

        let provider = MeaningRetrievalProvider(embedder: LexiconEmbedding(knowledge: TestIndex.knowledge),
                                                knowledge: TestIndex.knowledge)
        let home = await HomeSearch.make(homeID: "eval", devices: SyntheticHome.make(count: 500),
                                         components: DeviceSearchComponents(knowledge: TestIndex.knowledge, meaning: provider))
        await provider.waitUntilWarm()
        let hybrid = await EvaluationRunner(engine: home.engine).run(queries)
        print("Lexical baseline:\n" + lexical.markdown())
        print("With meaning:\n" + hybrid.markdown())
        hybrid.failures.forEach { print("FAIL", $0) }

        let before = lexical.category(.descriptive)!.ndcg5!
        let after = hybrid.category(.descriptive)!.ndcg5!
        #expect(after > before)                                  // record the baseline; meaning must help
        #expect(hybrid.zeroResultRate <= 0.01)
        #expect(hybrid.navigationalSuccess >= 0.92)               // no milestone-1 regression
        #expect(hybrid.setPrecision == 1.0)
    }
}
