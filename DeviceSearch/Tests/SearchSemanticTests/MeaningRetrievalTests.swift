import Foundation
import Testing
import SearchCore
import SearchIndex
import SearchQuery
import DeviceSearch
@testable import SearchSemantic
import SearchTestSupport

@Suite("Meaning retrieval")
struct MeaningRetrievalTests {
    @Test func semanticAndConceptListsServeDescriptiveQueries() async {
        let (snapshot, provider) = await warmedHome()
        let query = QueryParser().parse("something to cool the bedroom", mode: .submitted, in: snapshot)
        let output = await provider.meaningLists(for: query, in: snapshot, config: .default)
        #expect(output?.label == "cooling")
        let semantic = output!.lists.first { $0.retriever == .semantic }!
        let concept = output!.lists.first { $0.retriever == .concept }!
        let topTypes = Set(semantic.hits.prefix(10).map { snapshot.documents[$0.document].typeID })
        #expect(topTypes.isSubset(of: ["ac", "fan", "thermostat", "purifier", "humidifier", "fridge"]))
        #expect(snapshot.documents[concept.hits[0].document].roomID == "bedroom")   // room boost
    }

    @Test func setQueriesSkipMeaning() async {
        let (snapshot, provider) = await warmedHome()
        let query = QueryParser().parse("all lights", mode: .submitted, in: snapshot)
        #expect(await provider.meaningLists(for: query, in: snapshot, config: .default) == nil)
    }

    @Test func conceptRoutingKeepsAtMostFourTypes() async {
        let (snapshot, _) = await warmedHome()
        let embedding = LexiconEmbedding(knowledge: TestIndex.knowledge)
        let query = snapshot.vectors.prepareQuery(embedding.vector(for: "too hot"))!
        let routes = ConceptRouter().route(query, in: snapshot, config: .default)
        #expect(routes.count <= 4)
        #expect(routes.first?.typeID == "ac")
        #expect(routes.allSatisfy { $0.similarity >= 0.45 })
    }

    @Test func engineAddsAHybridPhaseOnceWarm() async {
        let provider = MeaningRetrievalProvider(embedder: LexiconEmbedding(knowledge: TestIndex.knowledge),
                                                knowledge: TestIndex.knowledge)
        let home = await HomeSearch.make(homeID: "h", devices: SyntheticHome.make(count: 500),
                                         components: DeviceSearchComponents(knowledge: TestIndex.knowledge, meaning: provider))
        await provider.waitUntilWarm()
        #expect(await home.engine.currentSnapshot.vectors.warmedCount == 500)
        let phases = await home.engine.searchAll("movie night", mode: .submitted)
        #expect(phases.map(\.phase) == [.instant, .hybrid])
        let top = phases[1].results.prefix(3).map { home.engine.config.candidateCount > 0 ? $0.typeLabel : "" }
        #expect(top.allSatisfy { ["TV", "Projector", "Media Player"].contains($0) })
        #expect(phases[1].results.first?.reasons.contains { $0.text.hasPrefix("Meaning:") } == true)
    }
}
