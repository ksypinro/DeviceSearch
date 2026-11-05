import SearchCore
import SearchIndex

/// Exact name (design doc §6): the normalized full name, or a learned nickname, equals the query.
/// Score 1; fusion pins these results first. Skipped when a correction is less than 60% confident.
public struct ExactRetriever: CandidateRetriever {
    public let id = RetrieverID.exact

    public init() {}

    public func retrieve(_ query: ParsedQuery, in snapshot: IndexSnapshot, config: SearchConfig) -> [RetrievalHit] {
        guard !query.corrections.contains(where: { $0.confidence < config.minConfidenceForExact }) else { return [] }
        var seen = Set<Int>()
        var hits: [RetrievalHit] = []
        for key in [query.sequenceAll, query.sequenceContent] where !key.isEmpty {
            for ordinal in snapshot.names.documents(named: key) where seen.insert(ordinal).inserted {
                hits.append(RetrievalHit(document: ordinal, score: 1))
            }
        }
        return hits
    }
}

/// Prefix (design doc §6): every query word is a name word, and the last may be a prefix, so results
/// appear while typing. Numbers never match as prefixes ("tv 1" must not find "TV 12").
/// Score = query words / name words. Ties: higher prior first.
public struct PrefixRetriever: CandidateRetriever {
    public let id = RetrieverID.prefix

    public init() {}

    public func retrieve(_ query: ParsedQuery, in snapshot: IndexSnapshot, config: SearchConfig) -> [RetrievalHit] {
        let terms = query.nameTerms.filter { !$0.describesNeed }
        guard !terms.isEmpty else { return [] }
        var hits: [RetrievalHit] = []
        for document in snapshot.documents {
            let names = document.nameTokens
            guard !names.isEmpty else { continue }
            var matches = true
            for (index, term) in terms.enumerated() {
                if names.contains(term.term) { continue }
                let isLast = index == terms.count - 1
                if isLast, !term.isNumber, names.contains(where: { $0.hasPrefix(term.term) }) { continue }
                matches = false
                break
            }
            if matches {
                hits.append(RetrievalHit(document: document.ordinal, score: Double(terms.count) / Double(names.count)))
            }
        }
        return hits.ranked(limit: config.prefixLimit) { snapshot.documents[$0].prior }
    }
}
