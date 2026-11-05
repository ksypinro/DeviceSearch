import Foundation
import SearchCore
import SearchIndex
import SearchKnowledge
import DeviceSearch

/// The milestone-2 plug-in: semantic and concept retrieval behind the engine's `MeaningRetrieval` extension point.
///
/// Wiring: `HomeSearch.make(…, components: DeviceSearchComponents(…, meaning: provider))`. The engine calls
/// `snapshotDidChange` after every swap (warming) and `meaningLists` in the hybrid phase.
public final class MeaningRetrievalProvider: MeaningRetrieval {
    public let embedder: any TextEmbedding
    public let cache: EmbeddingCache
    public let embeddings: EmbeddingPipeline
    private let labeler: LexiconEmbedding

    /// - Parameters:
    ///   - cacheURL: where to persist vectors for this home and model (Application Support); nil keeps them in memory.
    public init(embedder: any TextEmbedding, knowledge: KnowledgeBase, cacheURL: URL? = nil,
                telemetry: any SearchTelemetry = NoopTelemetry(), batchSize: Int = 32) {
        self.embedder = embedder
        // Device texts and type cards come from the knowledge base, so its version is part of the cache's.
        let version = "\(embedder.modelVersion)|\(knowledge.version)"
        let loaded = cacheURL.flatMap {
            EmbeddingCache.load(from: $0, expectedModelVersion: version, centersVectors: embedder.centersVectors)
        }
        self.cache = loaded ?? EmbeddingCache(dimension: embedder.dimension, modelVersion: version,
                                              centersVectors: embedder.centersVectors)
        self.embeddings = EmbeddingPipeline(embedder: embedder, cache: cache, knowledge: knowledge, cacheURL: cacheURL,
                                            telemetry: telemetry, batchSize: batchSize)
        self.labeler = LexiconEmbedding(knowledge: knowledge)
    }

    public var vectorSource: (any VectorSource)? { cache }

    public func snapshotDidChange(_ snapshot: IndexSnapshot, sink: any VectorUpdateSink) async {
        await embeddings.warm(snapshot, sink: sink)
    }

    public func meaningLists(for query: ParsedQuery, in snapshot: IndexSnapshot, config: SearchConfig) async -> MeaningOutput? {
        // Set queries are answered by their filters; meaning would only add noise and energy.
        guard !query.isEmpty, !query.intent.isSet else { return nil }
        let text = query.correctedText.isEmpty ? query.raw : query.correctedText
        guard embedder.supports(text), let raw = try? await embedder.embed(text),
              let prepared = snapshot.vectors.prepareQuery(raw) else { return nil }
        var lists: [RankedList] = []
        if !snapshot.vectors.isEmpty {
            lists.append(RankedList(retriever: .semantic,
                                    hits: SemanticRetriever().retrieve(prepared, in: snapshot, config: config)))
        }
        if !snapshot.concepts.isEmpty {
            let router = ConceptRouter()
            let routes = router.route(prepared, in: snapshot, config: config)
            lists.append(RankedList(retriever: .concept,
                                    hits: router.retrieve(routes, query: query, in: snapshot, config: config)))
        }
        guard lists.contains(where: { !$0.hits.isEmpty }) else { return nil }
        return MeaningOutput(lists: lists, label: labeler.label(for: text))
    }

    /// Waits until the current warming pass finishes (tests and evaluation).
    public func waitUntilWarm() async { await embeddings.waitUntilWarm() }
}
