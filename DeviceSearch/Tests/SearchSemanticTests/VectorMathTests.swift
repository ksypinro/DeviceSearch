import Foundation
import Testing
import SearchCore
import SearchIndex
import SearchQuery
import DeviceSearch
@testable import SearchSemantic
import SearchTestSupport

@Suite("Vector math")
struct VectorMathTests {
    @Test func topMatchesSkipsWarmingRowsAndAppliesTheThreshold() {
        let store = VectorStore.build(capacity: 3, dimension: 2, modelVersion: "m",
                                      raw: [0: [1, 0], 1: [0.6, 0.8]], center: false)
        let hits = VectorMath.topMatches([1, 0], in: store, minScore: 0.5, limit: 10)
        #expect(hits.map(\.document) == [0, 1])
        #expect(VectorMath.topMatches([0, 1], in: store, minScore: 0.9, limit: 10).isEmpty)
    }
}
