import SearchCore
import SearchIndex

/// Stage S4: weighted Reciprocal Rank Fusion plus three boosts (design doc §7).
///
///     fused(d) = Σ_r w_r(intent) / (k + rank_r(d))      k = 20
///              + 0.12 · coverage(d) + 0.10 · entityMatch(d) + 0.04 · prior(d)   (0.03 for descriptive queries)
///
/// Rank-based fusion needs no calibration between BM25, cosine and edit costs, and one confidently wrong
/// retriever cannot dominate. Hard filters apply as one bitset; exact-name matches sort first.
public struct RankFuser: Sendable {
    public let config: SearchConfig

    public init(config: SearchConfig = .default) {
        self.config = config
    }

    public func fuse(_ lists: [RankedList], query: ParsedQuery, snapshot: IndexSnapshot) -> FusionResult {
        let weights = config.weights(for: query.intent)
        var candidates: [Int: FusedCandidate] = [:]

        for list in lists {
            let weight = weights[list.retriever] ?? 0
            for (index, hit) in list.hits.enumerated() {
                let contribution = weight / (config.rrfK + Double(index + 1))
                var candidate = candidates[hit.document] ?? FusedCandidate(document: hit.document)
                candidate.contributions[list.retriever] = contribution
                candidate.ranks[list.retriever] = index + 1
                candidate.rrf += contribution
                candidates[hit.document] = candidate
            }
        }

        let filter = query.hasHardFilters ? Self.hardFilter(query, snapshot: snapshot) : nil
        if let filter, query.intent.isSet {
            // Set queries keep every member of the filtered set, even ones no retriever ranked.
            for ordinal in filter.members where candidates[ordinal] == nil {
                candidates[ordinal] = FusedCandidate(document: ordinal)
            }
        }

        let priorBoost = query.intent == .descriptive ? config.descriptivePriorBoost : config.priorBoost
        var kept: [FusedCandidate] = []
        var removed = 0
        for var candidate in candidates.values {
            let document = snapshot.documents[candidate.document]
            candidate.passesHardFilters = filter?.contains(candidate.document) ?? true
            candidate.coverage = Self.coverage(query, document)
            candidate.entityMatch = Self.entityMatch(query, document)
            candidate.prior = document.prior
            candidate.score = candidate.rrf + config.coverageBoost * candidate.coverage
                + config.entityMatchBoost * candidate.entityMatch + priorBoost * candidate.prior
            candidate.isExact = candidate.has(.exact)
            if candidate.passesHardFilters { kept.append(candidate) } else { removed += 1 }
        }
        kept.sort { a, b in
            if a.isExact != b.isExact { return a.isExact }
            if a.score != b.score { return a.score > b.score }
            return a.document < b.document
        }
        return FusionResult(candidates: kept, removedByFilters: removed)
    }

    /// Share of query words found in any field; the last word may match as a prefix while typing.
    /// Words that describe the need never match, but still count.
    public static func coverage(_ query: ParsedQuery, _ document: SearchDocument) -> Double {
        let terms = query.nameTerms
        guard !terms.isEmpty else { return 0 }
        var matched = 0
        for (index, term) in terms.enumerated() where !term.describesNeed {
            if document.allTokens.contains(term.term) {
                matched += 1
            } else if index == terms.count - 1, term.isPrefix,
                      document.allTokens.contains(where: { $0.hasPrefix(term.term) }) {
                matched += 1
            }
        }
        return Double(matched) / Double(terms.count)
    }

    /// Average over entity kinds of the best match within the kind (rooms can match partially at 0.75).
    public static func entityMatch(_ query: ParsedQuery, _ document: SearchDocument) -> Double {
        let kinds = Dictionary(grouping: query.entities, by: \.kind)
        guard !kinds.isEmpty else { return 0 }
        var total = 0.0
        for (_, entities) in kinds {
            total += entities.map { match($0, document) }.max() ?? 0
        }
        return total / Double(kinds.count)
    }

    public static func match(_ entity: QueryEntity, _ document: SearchDocument) -> Double {
        switch entity.kind {
        case .type: return document.typeID == entity.id ? 1 : 0
        case .brand: return document.brandID == entity.id ? 1 : 0
        case .room: return document.roomMatch(id: entity.id, tokens: entity.roomTokens)
        case .status: return 0
        }
    }

    /// The query's hard filters as one bitset.
    public static func hardFilter(_ query: ParsedQuery, snapshot: IndexSnapshot) -> Bitset {
        let hard = query.hard
        return snapshot.facets.members(types: hard.types, brands: hard.brands, rooms: hard.rooms,
                                       network: hard.network, power: hard.power, excluded: hard.excluded)
    }
}
