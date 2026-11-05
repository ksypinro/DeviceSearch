import Foundation
import Testing
import SearchCore
import SearchIndex
import SearchQuery
import DeviceSearch
@testable import SearchSemantic
import SearchTestSupport

@Suite("Embedding pipeline")
struct EmbeddingPipelineTests {
    @Test func warmsEveryDeviceAndEveryTypeCard() async {
        let (snapshot, provider) = await warmedHome()
        #expect(snapshot.vectors.warmedCount == 500)
        #expect(snapshot.concepts.typeIDs.count == 33)
        #expect(provider.cache.count == 500)
    }

    @Test func secondWarmUsesTheCache() async {
        let provider = MeaningRetrievalProvider(embedder: LexiconEmbedding(knowledge: TestIndex.knowledge),
                                                knowledge: TestIndex.knowledge)
        let sink = RecordingSink()
        await provider.snapshotDidChange(TestIndex.curated, sink: sink)
        await provider.waitUntilWarm()
        // A rebuild starts warm: the builder reads cached vectors through the vector source.
        let rebuilt = TestIndex.builder.build(homeID: "h", devices: SyntheticHome.curated, generation: 2,
                                              vectorSource: provider.vectorSource)
        #expect(rebuilt.vectors.warmedCount == 48)
        #expect(!rebuilt.concepts.isEmpty)
    }
}
