import Testing
import SearchCore
import SearchIndex
import SearchQuery
import SearchRetrieval
@testable import SearchRanking
import SearchTestSupport

@Suite("Filter relaxation")
struct FilterRelaxationTests {
    @Test func dropsTheWeakestFilterUntilSomethingMatches() {
        let (query, lists, result) = fused("samsung lights")
        #expect(result.candidates.isEmpty)    // no Samsung lights exist
        let relaxed = FilterRelaxation(fuser: RankFuser()).relaxIfNeeded(query, lists: lists, fusion: result,
                                                                          snapshot: TestIndex.home500)
        #expect(relaxed.fusion.relaxed == [.brand])
        #expect(!relaxed.fusion.candidates.isEmpty)
        #expect(relaxed.query.hard.brands.isEmpty)
    }

    @Test func leavesNonEmptyResultsAlone() {
        let (query, lists, result) = fused("lights")
        let relaxed = FilterRelaxation(fuser: RankFuser()).relaxIfNeeded(query, lists: lists, fusion: result,
                                                                          snapshot: TestIndex.home500)
        #expect(relaxed.fusion.relaxed.isEmpty)
        #expect(relaxed.fusion.candidates.count == result.candidates.count)
    }
}
