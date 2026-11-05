import SearchCore
import SearchIndex

/// One retriever of stage S3. Retrievers are pure: they read the snapshot and the parsed query only.
public protocol CandidateRetriever: Sendable {
    var id: RetrieverID { get }
    /// Hits best first. Ties are broken by document ordinal so results are deterministic.
    func retrieve(_ query: ParsedQuery, in snapshot: IndexSnapshot, config: SearchConfig) -> [RetrievalHit]
}

extension CandidateRetriever {
    /// Runs the retriever and wraps the hits in a `RankedList`.
    public func rankedList(_ query: ParsedQuery, in snapshot: IndexSnapshot, config: SearchConfig) -> RankedList {
        RankedList(retriever: id, hits: retrieve(query, in: snapshot, config: config))
    }
}

/// The lexical retrievers in design-doc order. Semantic, concept and personal retrievers are added by plug-ins.
public enum LexicalRetrievers {
    public static let all: [any CandidateRetriever] = [
        ExactRetriever(), PrefixRetriever(), KeywordRetriever(), TrigramRetriever(), PhoneticRetriever(), FacetRetriever(),
    ]
}

extension Array where Element == RetrievalHit {
    /// Sorts by score (descending), then an optional secondary key (descending), then ordinal (ascending).
    func ranked(limit: Int, secondary: ((Int) -> Double)? = nil) -> [RetrievalHit] {
        sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            if let secondary {
                let sa = secondary(a.document), sb = secondary(b.document)
                if sa != sb { return sa > sb }
            }
            return a.document < b.document
        }.prefix(limit).map { $0 }
    }
}
