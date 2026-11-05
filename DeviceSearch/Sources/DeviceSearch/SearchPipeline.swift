import SearchCore
import SearchIndex
import SearchQuery
import SearchRanking
import SearchRetrieval

/// The pure, synchronous stages of a search: parse (S1–S2), lexical retrieval (S3), fusion with filter
/// relaxation (S4) and presentation (S8). The engine adds timing, meaning, gating and refinement around it.
public struct SearchPipeline: Sendable {
    public let config: SearchConfig
    public let parser: QueryParser
    public let fuser: RankFuser
    public let gate: RerankGate
    public let presenter: ResultPresenter
    public let retrievers: [any CandidateRetriever]

    public init(config: SearchConfig = .default, retrievers: [any CandidateRetriever] = LexicalRetrievers.all) {
        self.config = config
        self.parser = QueryParser(config: config)
        self.fuser = RankFuser(config: config)
        self.gate = RerankGate(config: config)
        self.presenter = ResultPresenter(config: config)
        self.retrievers = retrievers
    }

    public func parse(_ text: String, mode: SearchMode, options: SearchOptions, in snapshot: IndexSnapshot) -> ParsedQuery {
        parser.parse(text, mode: mode, options: options, in: snapshot)
    }

    public func lexicalLists(_ query: ParsedQuery, in snapshot: IndexSnapshot) -> [RankedList] {
        retrievers.map { $0.rankedList(query, in: snapshot, config: config) }
    }

    /// Fuses the lists and relaxes hard filters when nothing passes them (zero-result ladder step 1).
    public func fuse(_ lists: [RankedList], query: ParsedQuery, in snapshot: IndexSnapshot)
        -> (query: ParsedQuery, fusion: FusionResult) {
        let fusion = fuser.fuse(lists, query: query, snapshot: snapshot)
        return FilterRelaxation(fuser: fuser).relaxIfNeeded(query, lists: lists, fusion: fusion, snapshot: snapshot)
    }

    /// Union of documents found by any list.
    public static func pool(_ lists: [RankedList]) -> Set<Int> {
        Set(lists.flatMap { $0.hits.map(\.document) })
    }
}
