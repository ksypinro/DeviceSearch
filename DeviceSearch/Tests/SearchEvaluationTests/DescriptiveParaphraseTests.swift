import Testing
import SearchCore
import SearchIndex
import DeviceSearch
@testable import SearchEvaluation
import SearchTestSupport
import SearchSemantic

/// Rephrasings of the descriptive golden queries that are not in the golden set, so knowledge-base and ranking
/// changes are checked against wording they were not written for (lexicon meaning, no model).
@Suite("Descriptive paraphrases", .serialized)
struct DescriptiveParaphraseTests {
    @Test func theTopResultHasTheRightType() async {
        let home = await evaluationHome(refiner: nil)
        let cases: [(String, Set<String>)] = [
            ("who's at the front door", ["doorbell"]),
            ("is someone at the door", ["doorbell"]),
            ("make the bedroom brighter", ["light"]),
            ("play some music in the dining room", ["speaker"]),
            ("is there a fire", ["smoke"]),
            ("anything on fire in the kitchen", ["smoke"]),
            ("how cold is the garage", ["tempsensor", "thermostat"]),
            ("block the sun in the living room", ["blinds"]),
            ("the air feels dry", ["humidifier"]),
            ("the house is too humid", ["humidifier"]),
            ("watch the news in the bedroom", ["tv"]),
            ("it's stuffy in the office", ["fan", "purifier"]),
            ("keep an eye on the baby", ["camera"]),
        ]
        var misses: [String] = []
        for (text, types) in cases {
            let snapshot = await home.engine.currentSnapshot
            let top = await home.engine.searchAll(text, mode: .submitted).last?.results.first
            let type = top.flatMap { snapshot.document(for: $0.id)?.typeID } ?? "nothing"
            if !types.contains(type) { misses.append("“\(text)” → \(top?.device.name ?? "nothing") [\(type)]") }
        }
        misses.forEach { print("MISS", $0) }
        #expect(misses.isEmpty)
    }

    @Test func descriptiveGoldenQueriesStayAboveTheFloor() async {
        let queries = GoldenSetBuilder(snapshot: TestIndex.home500).build()
        let report = await EvaluationRunner(engine: evaluationHome(refiner: nil).engine).run(queries)
        #expect(report.category(.descriptive)!.ndcg5! >= 0.90)
        #expect(report.navigationalSuccess >= 0.92)
        #expect(report.setPrecision == 1.0)
    }
}
