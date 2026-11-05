import Testing
import SearchCore
import SearchKnowledge
@testable import SearchIndex
import SearchTestSupport

@Suite("Vector store")
struct VectorStoreTests {
    @Test func centersAndNormalizes() {
        let store = VectorStore.build(capacity: 3, dimension: 2, modelVersion: "m",
                                      raw: [0: [1, 1], 1: [3, 1]], center: true)
        #expect(store.mean == [2, 1])
        #expect(store.vector(at: 0).map(Array.init) == [-1, 0])
        #expect(store.vector(at: 1).map(Array.init) == [1, 0])
        #expect(store.vector(at: 2) == nil)                    // still warming
        #expect(store.prepareQuery([4, 1]) == [1, 0])
        #expect(store.prepareQuery([2, 1]) == nil)             // zero after centering
    }
}
