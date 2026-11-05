import Testing
import SearchCore
import SearchIndex
import DeviceSearch
@testable import SearchEvaluation
import SearchTestSupport
import SearchSemantic

/// Query-to-type similarity from the lexicon embedding: the "world knowledge" the simulated model uses.
func lexiconTypeSimilarity() -> @Sendable (String, String) -> Double {
    let lexicon = LexiconEmbedding(knowledge: TestIndex.knowledge)
    var cards: [String: [Float]] = [:]
    for card in TestIndex.knowledge.types {
        cards[card.id] = VectorStore.normalized(lexicon.vector(for: EmbeddingPipeline.conceptText(card)))
    }
    let frozen = cards
    return { query, typeID in
        guard let type = frozen[typeID], let vector = VectorStore.normalized(lexicon.vector(for: query)) else { return 0 }
        return Double(VectorMath.dot(vector, type[...]))
    }
}

/// The lab home with meaning signals and, optionally, the simulated re-ranker.
func evaluationHome(refiner: (any ResultRefining)?, telemetry: any SearchTelemetry = NoopTelemetry()) async -> HomeSearch {
    let provider = MeaningRetrievalProvider(embedder: LexiconEmbedding(knowledge: TestIndex.knowledge),
                                            knowledge: TestIndex.knowledge)
    let home = await HomeSearch.make(homeID: "eval", devices: SyntheticHome.make(count: 500),
                                     components: DeviceSearchComponents(knowledge: TestIndex.knowledge, telemetry: telemetry,
                                                                        meaning: provider, refiner: refiner))
    await provider.waitUntilWarm()
    return home
}
