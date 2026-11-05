import Testing
import SearchCore
import SearchIndex
import DeviceSearch
@testable import SearchEvaluation
import SearchTestSupport

@Suite("Golden set")
struct GoldenSetTests {
    @Test func buildsTheDesignDocSizes() {
        let queries = GoldenSetBuilder(snapshot: TestIndex.home500).build()
        let counts = Dictionary(grouping: queries, by: \.category).mapValues(\.count)
        #expect(counts[.navigational] == 60)
        #expect(counts[.typo] == 120)
        #expect(counts[.set] == 60)
        #expect(counts[.compound] == 40)
        #expect(counts[.number] == 20)
        #expect(counts[.descriptive] == 60)
        #expect(counts[.multilingual] == 20)
        #expect(queries.count == 380)
    }

    @Test func typosAreRealTypos() {
        let queries = GoldenSetBuilder(snapshot: TestIndex.home500).build()
        for typo in queries where typo.category == .typo {
            guard case .device(let id) = typo.expectation else { continue }
            #expect(TestIndex.home500.document(for: id)!.device.name.lowercased() != typo.text)
        }
    }

    @Test func metrics() {
        #expect(Metrics.successAt1(ranked: ["a", "b"], expected: "a") == 1)
        #expect(Metrics.reciprocalRank(ranked: ["a", "b"], expected: "b") == 0.5)
        #expect(Metrics.ndcg(ranked: ["a", "b"], gains: ["a": 2, "b": 1]) == 1)
        #expect(Metrics.ndcg(ranked: ["b", "a"], gains: ["a": 2, "b": 1]) < 1)
        #expect(Metrics.setScores(returned: ["a", "b"], expected: ["a"]) == (0.5, 1))
        #expect(Metrics.kendallTau(["a", "b", "c"], ["a", "b", "c"]) == 1)
        #expect(Metrics.kendallTau(["a", "b", "c"], ["c", "b", "a"]) == -1)
    }
}

@Suite("Milestone 1 exit criteria")
struct MilestoneOneTests {
    @Test func lexicalSearchMeetsTheTargets() async {
        let engine = SearchEngine(snapshot: TestIndex.home500)
        let queries = GoldenSetBuilder(snapshot: TestIndex.home500).build()
        let report = await EvaluationRunner(engine: engine).run(queries)
        print(report.markdown())
        report.failures.forEach { print($0) }
        #expect(report.navigationalSuccess >= 0.92)
        #expect(report.candidateRecall >= 0.98)
        #expect(report.setPrecision == 1.0)
    }
}
