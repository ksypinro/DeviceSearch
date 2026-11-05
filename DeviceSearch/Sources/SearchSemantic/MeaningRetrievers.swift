import SearchCore
import SearchIndex

/// Semantic retriever (design doc §6, R08): cosine between the query vector and each device's enriched
/// description, keeping scores ≥ 0.35, at most 40. Devices still warming (no vector yet) are skipped.
public struct SemanticRetriever: Sendable {
    public init() {}

    /// - Parameter query: a vector already centered and normalized with `VectorStore.prepareQuery`.
    public func retrieve(_ query: [Float], in snapshot: IndexSnapshot, config: SearchConfig) -> [RetrievalHit] {
        VectorMath.topMatches(query, in: snapshot.vectors, minScore: config.semanticMinCosine, limit: config.semanticLimit)
    }
}

/// Concept routing (design doc §6, R09): match the query to ~35 device-type cards instead of 500 devices,
/// keep types with similarity ≥ 0.45 and ≥ 85% of the best (at most 4), expand them to their devices and boost
/// the requested room.
public struct ConceptRouter: Sendable {
    public init() {}

    /// Matching type ids with their similarity, best first.
    public func route(_ query: [Float], in snapshot: IndexSnapshot, config: SearchConfig) -> [(typeID: String, similarity: Double)] {
        let concepts = snapshot.concepts
        var routes: [(typeID: String, similarity: Double)] = []
        for (index, typeID) in concepts.typeIDs.enumerated() {
            let similarity = Double(VectorMath.dot(query, concepts.vectors[index][...]))
            if similarity >= config.conceptMinSimilarity { routes.append((typeID, similarity)) }
        }
        routes.sort { $0.similarity != $1.similarity ? $0.similarity > $1.similarity : $0.typeID < $1.typeID }
        guard let best = routes.first?.similarity else { return [] }
        return Array(routes.prefix { $0.similarity >= best * config.conceptRelativeSimilarity }.prefix(config.conceptTopTypes))
    }

    /// Devices of the routed types. score = type similarity + 0.15 × room match with the query's rooms.
    public func retrieve(_ routes: [(typeID: String, similarity: Double)], query: ParsedQuery,
                         in snapshot: IndexSnapshot, config: SearchConfig) -> [RetrievalHit] {
        let rooms = query.entities.filter { $0.kind == .room }
        var best: [Int: Double] = [:]
        for route in routes {
            guard let members = snapshot.facets.types[route.typeID] else { continue }
            for ordinal in members.members {
                let document = snapshot.documents[ordinal]
                let roomBoost = rooms.isEmpty ? 0
                    : (rooms.map { document.roomMatch(id: $0.id, tokens: $0.roomTokens) }.max() ?? 0) * config.conceptRoomBoost
                best[ordinal] = max(best[ordinal] ?? 0, route.similarity + roomBoost)
            }
        }
        return best.map { RetrievalHit(document: $0.key, score: $0.value) }
            .sorted { $0.score != $1.score ? $0.score > $1.score : $0.document < $1.document }
            .prefix(config.conceptLimit).map { $0 }
    }
}
