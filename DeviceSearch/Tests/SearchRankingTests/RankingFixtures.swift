import Testing
import SearchCore
import SearchIndex
import SearchQuery
import SearchRetrieval
@testable import SearchRanking
import SearchTestSupport

/// Parses, runs the lexical retrievers and fuses.
func fused(_ text: String, mode: SearchMode = .submitted, snapshot: IndexSnapshot = TestIndex.home500)
    -> (query: ParsedQuery, lists: [RankedList], fusion: FusionResult) {
    let query = QueryParser().parse(text, mode: mode, in: snapshot)
    let lists = LexicalRetrievers.all.map { $0.rankedList(query, in: snapshot, config: .default) }
    return (query, lists, RankFuser().fuse(lists, query: query, snapshot: snapshot))
}

func topNames(_ fusion: FusionResult, _ count: Int = 5, snapshot: IndexSnapshot = TestIndex.home500) -> [String] {
    fusion.top(count).map { snapshot.documents[$0.document].device.name }
}
