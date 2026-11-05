import SearchCore
import SearchIndex

/// Facets (design doc §6): bitset algebra over every parsed entity, status and exclusion —
/// OR within a kind, AND across kinds, AND-NOT for exclusions — ranked by usage prior.
/// Unlike hard filters, this uses entities even when the query is not a set query (as a boost).
public struct FacetRetriever: CandidateRetriever {
    public let id = RetrieverID.facets

    public init() {}

    public func retrieve(_ query: ParsedQuery, in snapshot: IndexSnapshot, config: SearchConfig) -> [RetrievalHit] {
        guard !query.entities.isEmpty || query.network != nil || query.power != nil || !query.excluded.isEmpty else {
            return []
        }
        let members = snapshot.facets.members(
            types: query.entities.filter { $0.kind == .type },
            brands: query.entities.filter { $0.kind == .brand },
            rooms: query.entities.filter { $0.kind == .room },
            network: query.network, power: query.power, excluded: query.excluded)
        return members.members
            .map { RetrievalHit(document: $0, score: snapshot.documents[$0].prior) }
            .ranked(limit: Int.max)
    }
}
