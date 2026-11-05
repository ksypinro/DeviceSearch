import Foundation
import Testing
import SearchCore
import SearchIndex
import SearchQuery
import DeviceSearch
@testable import SearchSemantic
import SearchTestSupport

@Suite("Lexicon embedding")
struct LexiconEmbeddingTests {
    let embedding = LexiconEmbedding(knowledge: TestIndex.knowledge)

    @Test func meaningWordsAndTypesShareASpace() {
        let query = VectorStore.normalized(embedding.vector(for: "something to cool the bedroom"))!
        let ac = VectorStore.normalized(embedding.vector(for: "Bedroom AC. Air Conditioner. Samsung. In Bedroom."))!
        let lamp = VectorStore.normalized(embedding.vector(for: "Bedroom Lamp. Light. IKEA. In Bedroom."))!
        #expect(VectorMath.dot(query, ac[...]) > 0.8)
        #expect(VectorMath.dot(query, lamp[...]) < 0.35)
    }

    @Test func labelsNameTheStrongestConcepts() {
        #expect(embedding.label(for: "something to cool the bedroom") == "cooling")
        #expect(embedding.label(for: "movie night") == "screens + entertainment")
        #expect(embedding.label(for: "bob") == nil)
        #expect(embedding.dimension == 22)
    }
}
