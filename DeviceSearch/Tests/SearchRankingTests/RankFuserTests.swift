import Testing
import SearchCore
import SearchIndex
import SearchQuery
import SearchRetrieval
@testable import SearchRanking
import SearchTestSupport

@Suite("Rank fusion")
struct RankFuserTests {
    @Test(arguments: [
        ("bedroom ac", "Bedroom AC"),
        ("bedrom ac", "Bedroom AC"),
        ("samsng tv", "Samsung TV"),
        ("livingroom tv", "Living Room TV"),
        ("tv 2", "TV 2"),
        ("tv 12", "TV 12"),
        ("bob lamp", "Bob's Lamp"),
        ("hallwya light", "Hallway Light"),
        ("nursery cam", "Nursery Cam"),
    ])
    func navigationalQueriesFindTheDevice(text: String, expected: String) {
        #expect(topNames(fused(text).fusion, 1) == [expected])
    }

    @Test func exactMatchesArePinnedFirst() {
        let result = fused("Hue Go").fusion
        #expect(result.candidates.first?.isExact == true)
    }

    @Test func rrfAndBoostsAddUp() {
        let candidate = fused("bedroom ac").fusion.candidates[0]
        let expected = candidate.rrf + 0.12 * candidate.coverage + 0.10 * candidate.entityMatch + 0.04 * candidate.prior
        #expect(abs(candidate.score - expected) < 1e-12)
        #expect(candidate.coverage == 1)
        // Exact (weight 1.0 for a compound query) at rank 1 contributes 1 / (20 + 1).
        #expect(abs(candidate.contributions[.exact]! - 1.0 / 21) < 1e-12)
    }

    @Test func setQueriesKeepEveryFilteredMember() {
        let (_, _, result) = fused("lights except kitchen")
        let snapshot = TestIndex.home500
        let expected = snapshot.documents.filter { $0.typeID == "light" && $0.roomID != "kitchen" }.count
        #expect(result.candidates.count == expected)
        #expect(result.candidates.allSatisfy { $0.passesHardFilters })
    }

    @Test func hardFiltersRemoveNonMatches() {
        let (_, _, result) = fused("aircon in guest room")
        #expect(!result.candidates.isEmpty)
        #expect(result.candidates.allSatisfy { TestIndex.home500.documents[$0.document].roomID == "guest-room" })
        #expect(result.removedByFilters > 0)
    }

    @Test func coverageCountsAPrefixOnlyWhileTyping() {
        let typing = QueryParser().parse("bedroom a", mode: .typing, in: TestIndex.home500)
        let document = TestIndex.home500.document(for: "d001")!   // Bedroom AC
        #expect(RankFuser.coverage(typing, document) == 1)
    }
}
