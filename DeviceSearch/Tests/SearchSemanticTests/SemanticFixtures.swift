import Foundation
import Testing
import SearchCore
import SearchIndex
import SearchQuery
import DeviceSearch
@testable import SearchSemantic
import SearchTestSupport

/// Collects vectors published by the embedding pipeline.
actor RecordingSink: VectorUpdateSink {
    var updates: [(VectorStore, ConceptVectors, UInt64)] = []
    func applyVectors(_ vectors: VectorStore, concepts: ConceptVectors, generation: UInt64) async {
        updates.append((vectors, concepts, generation))
    }
    var last: (VectorStore, ConceptVectors, UInt64)? { updates.last }
}

/// The lab home with every vector warmed by the lexicon embedding.
func warmedHome() async -> (IndexSnapshot, MeaningRetrievalProvider) {
    let provider = MeaningRetrievalProvider(embedder: LexiconEmbedding(knowledge: TestIndex.knowledge),
                                            knowledge: TestIndex.knowledge)
    let sink = RecordingSink()
    let snapshot = TestIndex.home500
    await provider.snapshotDidChange(snapshot, sink: sink)
    await provider.waitUntilWarm()
    let (vectors, concepts, _) = await sink.last!
    return (snapshot.withVectors(vectors, concepts: concepts), provider)
}
